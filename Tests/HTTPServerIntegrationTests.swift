// 用途：验证 OpenAI、Responses、Anthropic 与 Gemini HTTP endpoint 的共享管线。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import Foundation

private final class FakeGenerator: TextGenerating {
    private var output = """
    ```tool_call
    {"name":"Read","arguments":{"file_path":"README.md"}}
    ```
    """
    private var stream_deltas = ["fake stream"]
    private var generation_failure_message: String?
    private var stream_failure_message = "stream failed"
    private(set) var last_prompt = ""
    private(set) var cancellation_observed = false
    private(set) var stream_started = DispatchSemaphore(value: 0)
    private(set) var stream_finished = DispatchSemaphore(value: 0)
    private(set) var delayed_stream_release = DispatchSemaphore(value: 0)
    private var wait_for_cancellation = false
    private var wait_after_first_delta = false
    private var fail_stream = false
    private var fail_stream_after_deltas = false

    func generate(_ request: GenerationRequest) throws -> String {
        last_prompt = request.prompt
        if let message = generation_failure_message {
            throw NSError(
                domain: "HTTPServerIntegrationTests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        return output
    }

    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        last_prompt = request.prompt
        if wait_for_cancellation {
            stream_started.signal()
            defer { stream_finished.signal() }
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if isCancelled() {
                    cancellation_observed = true
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return
        }
        if wait_after_first_delta {
            stream_started.signal()
            defer { stream_finished.signal() }
            guard let first_delta = stream_deltas.first else { return }
            onDelta(first_delta)
            guard delayed_stream_release.wait(timeout: .now() + 2) == .success else {
                return
            }
            for delta in stream_deltas.dropFirst() where !isCancelled() {
                onDelta(delta)
            }
            return
        }
        if fail_stream && !fail_stream_after_deltas {
            throw NSError(
                domain: "HTTPServerIntegrationTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: stream_failure_message])
        }
        for delta in stream_deltas where !isCancelled() {
            onDelta(delta)
        }
        if fail_stream {
            throw NSError(
                domain: "HTTPServerIntegrationTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: stream_failure_message])
        }
    }

    // 功能：把流式生成器切换为轮询取消回调的可控模式。
    // 参数：无。
    // 返回值：无。
    func prepare_cancellation_test() {
        cancellation_observed = false
        stream_started = DispatchSemaphore(value: 0)
        stream_finished = DispatchSemaphore(value: 0)
        wait_for_cancellation = true
    }

    // 功能：恢复常规流式生成模式。
    // 参数：无。
    // 返回值：无。
    func finish_cancellation_test() {
        wait_for_cancellation = false
    }

    // 功能：让流式生成器发出首个 delta 后等待测试释放。
    // 参数：values 为测试期间依次发送的增量。
    // 返回值：无。
    func prepare_delayed_stream_test(_ values: [String]) {
        stream_deltas = values
        stream_started = DispatchSemaphore(value: 0)
        stream_finished = DispatchSemaphore(value: 0)
        delayed_stream_release = DispatchSemaphore(value: 0)
        wait_after_first_delta = true
    }

    // 功能：允许延迟流继续发送剩余 delta 并结束。
    // 参数：无。
    // 返回值：无。
    func release_delayed_stream() {
        delayed_stream_release.signal()
    }

    // 功能：恢复常规流式生成模式和默认增量。
    // 参数：无。
    // 返回值：无。
    func finish_delayed_stream_test() {
        wait_after_first_delta = false
        stream_deltas = ["fake stream"]
    }

    // 功能：控制下一个文本流在启动后失败。
    // 参数：should_fail 为是否抛错；after_deltas 指示先发送配置的 delta。
    // 返回值：无。
    func set_stream_failure(
        _ should_fail: Bool,
        after_deltas: Bool = false,
        message: String = "stream failed"
    ) {
        fail_stream = should_fail
        fail_stream_after_deltas = should_fail && after_deltas
        stream_failure_message = message
    }

    // 功能：设置非流式生成文本。
    // 参数：value 为下一次生成使用的文本。
    // 返回值：无。
    func set_output(_ value: String) {
        output = value
    }

    // 功能：控制完整生成是否抛出含指定消息的错误。
    // 参数：message 为错误消息；nil 表示正常生成。
    // 返回值：无。
    func set_generation_failure(_ message: String?) {
        generation_failure_message = message
    }

    // 功能：设置流式生成器依次发出的独立 delta。
    // 参数：values 为增量数组。
    // 返回值：无。
    func set_stream_deltas(_ values: [String]) {
        stream_deltas = values
    }
}

private struct HTTPResult {
    let status: Int
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
}

private final class StreamingHTTPProbe: NSObject, URLSessionDataDelegate {
    private let expected_fragment: String
    private let lock = NSLock()
    private var response_data = Data()
    private var did_signal_fragment = false
    private(set) var response_status = 0
    private(set) var completion_error: Error?
    let fragment_received = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)

    // 功能：创建等待指定响应片段的增量 HTTP 探针。
    // 参数：expected_fragment 为收到后触发 semaphore 的 UTF-8 文本。
    // 返回值：初始化后的探针。
    init(expected_fragment: String) {
        self.expected_fragment = expected_fragment
    }

    // 功能：保存 HTTP status，并允许 URLSession 继续接收响应体。
    // 参数：session、data_task 和 response 来自 URLSession；
    // completion_handler 决定是否继续。
    // 返回值：无。
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        response_status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    // 功能：逐块保存响应，并在首次看到目标片段时通知测试。
    // 参数：session、data_task 和 data 来自 URLSession。
    // 返回值：无。
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        response_data.append(data)
        let text = String(decoding: response_data, as: UTF8.self)
        let should_signal = !did_signal_fragment && text.contains(expected_fragment)
        if should_signal { did_signal_fragment = true }
        lock.unlock()
        if should_signal { fragment_received.signal() }
    }

    // 功能：记录流完成状态并通知测试。
    // 参数：session、task 和 error 来自 URLSession。
    // 返回值：无。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        completion_error = error
        completed.signal()
    }

    // 功能：读取当前已接收的 UTF-8 响应体快照。
    // 参数：无。
    // 返回值：当前响应文本。
    func text_snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: response_data, as: UTF8.self)
    }
}

@main
struct HTTPServerIntegrationTests {
    private static let testPort = Int.random(in: 20_000...50_000)
    private static let readinessAttempts = 40
    private static let readinessDelay = 0.05
    private static let requestTimeoutSeconds = 5.0

    static func main() throws {
        let config = Store()
        config.host = "127.0.0.1"
        config.port = testPort
        let fake = FakeGenerator()
        let server = HTTPServer(generator: fake, config: config)
        try server.start()
        defer { server.stop() }
        try waitUntilReady(server)
        try test_endpoint_matrix(fake)
        try test_protocol_capability_matrix(fake)
        testGemini38Routing()
        try testNonStreamingToolUse()
        try testStreamingToolUse()
        try test_openai_developer_stream(fake)
        try test_anthropic_tool_result_round_trip(fake)
        try test_openai_tool_history_preserves_name()
        test_media_content_is_unsupported()
        test_malformed_tools_are_invalid_requests()
        try test_named_tool_choices_are_normalized()
        try test_openai_malformed_tool_history_returns_400()
        try test_anthropic_text_stream_is_incremental(fake)
        try test_anthropic_stream_propagates_cancellation(fake)
        try test_responses_text_stream()
        try test_responses_tool_stream()
        try test_responses_stream_error(fake)
        try test_responses_stream_propagates_cancellation(fake)
        try test_gemini_text_stream(fake)
        try test_gemini_tool_stream(fake)
        try test_gemini_auto_tool_stream_without_call(fake)
        try test_gemini_stream_error(fake)
        try test_gemini_partial_stream_error(fake)
        try test_gemini_stream_propagates_cancellation(fake)
        try test_protocol_aware_not_found()
        try testTokenCount()
        try testInvalidToolChoices()
        try test_protocol_http_errors_are_redacted(fake)
        try test_protocol_stream_errors_are_redacted(fake)
        try test_tool_protocol_errors_are_redacted(fake)
        try test_protocol_aware_authentication(config, fake: fake)
        print("HTTPServerIntegrationTests passed")
    }

    private static func testGemini38Routing() {
        let model = resolveModel("gemini-3.8-flash", defaultModel: "gemini-3.6-flash")
        precondition(model.name == "gemini-3.8-flash")
        precondition(model.mode == 1)
        precondition(model.think == 4)
        precondition(model.extra == nil)
    }

    private static func waitUntilReady(_ server: HTTPServer) throws {
        for _ in 0..<readinessAttempts {
            if server.running { return }
            Thread.sleep(forTimeInterval: readinessDelay)
        }
        throw NSError(domain: "HTTPServerIntegrationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "server did not become ready"])
    }

    // 功能：逐条验证七个公开 endpoint 的 HTTP status 和协议关键字段。
    // 参数：fake 为可控生成器，用于固定非流式文本结果。
    // 返回值：无。
    private static func test_endpoint_matrix(_ fake: FakeGenerator) throws {
        fake.set_output("matrix response")
        defer { fake.set_output(default_tool_output()) }
        let text_message = [["role": "user", "content": "Hello"]]
        let endpoint_cases: [(
            method: String,
            path: String,
            payload: [String: Any]?,
            expected: String
        )] = [
            ("GET", "/v1/models", nil, "\"object\":\"list\""),
            (
                "POST",
                "/v1/chat/completions",
                ["messages": text_message],
                "chat.completion"
            ),
            (
                "POST",
                "/v1/responses",
                ["input": "Hello"],
                "\"object\":\"response\""
            ),
            (
                "POST",
                "/v1/messages",
                ["messages": text_message],
                "\"type\":\"message\""
            ),
            (
                "POST",
                "/v1/messages/count_tokens",
                ["messages": text_message],
                "input_tokens"
            ),
            (
                "POST",
                "/v1beta/models/gemini-3.8-flash:generateContent",
                gemini_text_request(),
                "candidates"
            ),
            (
                "POST",
                "/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse",
                gemini_text_request(),
                "data:"
            ),
        ]

        for endpoint_case in endpoint_cases {
            let result = try request(
                method: endpoint_case.method,
                path: endpoint_case.path,
                payload: endpoint_case.payload)
            precondition(
                result.status == 200,
                "\(endpoint_case.method) \(endpoint_case.path) returned \(result.status)")
            precondition(
                result.text.contains(endpoint_case.expected),
                "\(endpoint_case.path) omitted \(endpoint_case.expected)")
        }
    }

    // 功能：验证四类生成 API 都覆盖文本、工具、工具结果续轮和
    // unsupported 输入。
    // 参数：fake 为可控生成器，用于在各分支间切换确定输出。
    // 返回值：无。
    private static func test_protocol_capability_matrix(
        _ fake: FakeGenerator
    ) throws {
        try test_openai_chat_capabilities(fake)
        try test_responses_capabilities(fake)
        try test_anthropic_capabilities(fake)
        try test_gemini_capabilities(fake)
    }

    // 功能：验证 Chat Completions 的四类核心输入。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_openai_chat_capabilities(
        _ fake: FakeGenerator
    ) throws {
        fake.set_output("chat text")
        let text = try post(
            path: "/v1/chat/completions",
            payload: ["messages": [["role": "user", "content": "Hello"]]])
        let text_body = try jsonObject(text.data)
        let text_choices = text_body["choices"] as? [[String: Any]]
        let text_message = text_choices?.first?["message"] as? [String: Any]
        precondition(text.status == 200)
        precondition(text_message?["content"] as? String == "chat text")

        fake.set_output(default_tool_output())
        let tool = try post(
            path: "/v1/chat/completions",
            payload: openai_tool_request())
        let tool_body = try jsonObject(tool.data)
        let tool_choices = tool_body["choices"] as? [[String: Any]]
        let tool_message = tool_choices?.first?["message"] as? [String: Any]
        let tool_calls = tool_message?["tool_calls"] as? [[String: Any]]
        let tool_function = tool_calls?.first?["function"] as? [String: Any]
        precondition(tool.status == 200)
        precondition(tool_function?["name"] as? String == "Read")

        fake.set_output("chat continued")
        let continuation = try post(
            path: "/v1/chat/completions",
            payload: openai_tool_result_request())
        precondition(continuation.status == 200)
        precondition(fake.last_prompt.contains("Tool result for Read"))
        precondition(fake.last_prompt.contains("chat tool result"))

        let unsupported = try post(
            path: "/v1/chat/completions",
            payload: ["messages": [[
                "role": "user",
                "content": [[
                    "type": "image_url",
                    "image_url": ["url": "data:image/png;base64,AA=="],
                ]],
            ]]])
        precondition(unsupported.status == 400)
        let unsupported_error = try jsonObject(unsupported.data)["error"]
            as? [String: Any]
        precondition(unsupported_error?["code"] as? String == "unsupported_feature")
        fake.set_output(default_tool_output())
    }

    // 功能：验证 Responses 的四类核心输入。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_responses_capabilities(
        _ fake: FakeGenerator
    ) throws {
        fake.set_output("responses text")
        let text = try post(
            path: "/v1/responses",
            payload: ["input": "Hello"])
        let text_body = try jsonObject(text.data)
        let text_output = text_body["output"] as? [[String: Any]]
        let text_content = text_output?.first?["content"] as? [[String: Any]]
        precondition(text.status == 200)
        precondition(text_output?.first?["type"] as? String == "message")
        precondition(text_content?.first?["text"] as? String == "responses text")

        fake.set_output(default_tool_output())
        let tool = try post(
            path: "/v1/responses",
            payload: responses_tool_request())
        let tool_output = try jsonObject(tool.data)["output"] as? [[String: Any]]
        precondition(tool.status == 200)
        precondition(tool_output?.first?["type"] as? String == "function_call")
        precondition(tool_output?.first?["name"] as? String == "Read")

        fake.set_output("responses continued")
        let continuation = try post(
            path: "/v1/responses",
            payload: responses_tool_result_request())
        precondition(continuation.status == 200)
        precondition(fake.last_prompt.contains("Tool result for Read"))
        precondition(fake.last_prompt.contains("responses tool result"))

        let unsupported = try post(
            path: "/v1/responses",
            payload: ["input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_image",
                    "image_url": "data:image/png;base64,AA==",
                ]],
            ]]])
        precondition(unsupported.status == 400)
        let unsupported_error = try jsonObject(unsupported.data)["error"]
            as? [String: Any]
        precondition(unsupported_error?["code"] as? String == "unsupported_feature")
        fake.set_output(default_tool_output())
    }

    // 功能：验证 Anthropic Messages 的四类核心输入。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_anthropic_capabilities(
        _ fake: FakeGenerator
    ) throws {
        fake.set_output("anthropic text")
        let text = try post(
            path: "/v1/messages",
            payload: ["messages": [["role": "user", "content": "Hello"]]])
        let text_content = try jsonObject(text.data)["content"] as? [[String: Any]]
        precondition(text.status == 200)
        precondition(text_content?.first?["text"] as? String == "anthropic text")

        fake.set_output(default_tool_output())
        let tool = try post(
            path: "/v1/messages",
            payload: requestPayload(stream: false))
        let tool_content = try jsonObject(tool.data)["content"] as? [[String: Any]]
        precondition(tool.status == 200)
        precondition(tool_content?.first?["type"] as? String == "tool_use")

        fake.set_output("anthropic continued")
        let continuation = try post(
            path: "/v1/messages",
            payload: anthropic_tool_result_request())
        precondition(continuation.status == 200)
        precondition(fake.last_prompt.contains("Tool result for Read"))
        precondition(fake.last_prompt.contains("anthropic tool result"))

        let unsupported = try post(
            path: "/v1/messages",
            payload: ["messages": [[
                "role": "user",
                "content": [[
                    "type": "image",
                    "source": ["type": "base64", "data": "AA=="],
                ]],
            ]]])
        precondition(unsupported.status == 400)
        let unsupported_body = try jsonObject(unsupported.data)
        let unsupported_error = unsupported_body["error"] as? [String: Any]
        precondition(unsupported_body["type"] as? String == "error")
        precondition(unsupported_error?["type"] as? String == "invalid_request_error")
        fake.set_output(default_tool_output())
    }

    // 功能：验证 Gemini GenerateContent 的四类核心输入。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_capabilities(
        _ fake: FakeGenerator
    ) throws {
        let path = "/v1beta/models/gemini-3.8-flash:generateContent"
        fake.set_output("gemini text")
        let text = try post(path: path, payload: gemini_text_request())
        let text_candidates = try jsonObject(text.data)["candidates"]
            as? [[String: Any]]
        let text_content = text_candidates?.first?["content"] as? [String: Any]
        let text_parts = text_content?["parts"] as? [[String: Any]]
        precondition(text.status == 200)
        precondition(text_candidates?.first?["finishReason"] as? String == "STOP")
        precondition(text_parts?.first?["text"] as? String == "gemini text")

        fake.set_output(default_tool_output())
        let tool = try post(path: path, payload: gemini_tool_request())
        let tool_candidates = try jsonObject(tool.data)["candidates"]
            as? [[String: Any]]
        let tool_content = tool_candidates?.first?["content"] as? [String: Any]
        let tool_parts = tool_content?["parts"] as? [[String: Any]]
        let tool_function = tool_parts?.first?["functionCall"] as? [String: Any]
        precondition(tool.status == 200)
        precondition(tool_function?["name"] as? String == "Read")

        fake.set_output("gemini continued")
        let continuation = try post(
            path: path,
            payload: gemini_tool_result_request())
        precondition(continuation.status == 200)
        precondition(fake.last_prompt.contains("Tool result for Read"))
        precondition(fake.last_prompt.contains("gemini tool result"))

        let unsupported = try post(
            path: path,
            payload: ["contents": [[
                "role": "user",
                "parts": [["inlineData": [
                    "mimeType": "image/png",
                    "data": "AA==",
                ]]],
            ]]])
        precondition(unsupported.status == 400)
        let unsupported_error = try jsonObject(unsupported.data)["error"]
            as? [String: Any]
        precondition(unsupported_error?["code"] as? Int == 400)
        precondition(unsupported_error?["status"] as? String == "INVALID_ARGUMENT")
        fake.set_output(default_tool_output())
    }

    private static func testNonStreamingToolUse() throws {
        let result = try post(path: "/v1/messages", payload: requestPayload(stream: false))
        precondition(result.status == 200)
        let body = try jsonObject(result.data)
        precondition(body["stop_reason"] as? String == "tool_use")
        let blocks = body["content"] as? [[String: Any]]
        precondition(blocks?.first?["type"] as? String == "tool_use")
        precondition(blocks?.first?["name"] as? String == "Read")
    }

    private static func testStreamingToolUse() throws {
        let result = try post(path: "/v1/messages", payload: requestPayload(stream: true))
        precondition(result.status == 200)
        precondition(result.text.contains("event: message_start"))
        precondition(result.text.contains("\"type\":\"input_json_delta\""))
        precondition(result.text.contains("\"stop_reason\":\"tool_use\""))
        precondition(result.text.contains("event: message_stop"))
    }

    // 功能：验证 OpenAI developer 角色进入共享 prompt，
    // 且文本流保留结束标记。
    // 参数：fake 为记录最近 prompt 的测试生成器。
    // 返回值：无。
    private static func test_openai_developer_stream(_ fake: FakeGenerator) throws {
        let payload: [String: Any] = [
            "model": "gemini-3.6-flash",
            "stream": true,
            "messages": [[
                "role": "developer",
                "content": "Inspect before answering.",
            ]],
        ]
        let openai_stream = try post(path: "/v1/chat/completions", payload: payload)
        precondition(openai_stream.status == 200)
        precondition(fake.last_prompt.contains("[Developer instruction]"))
        precondition(openai_stream.text.hasSuffix("data: [DONE]\n\n"))
    }

    // 功能：验证 Anthropic 工具结果续轮保留实际工具名称和结果文本。
    // 参数：fake 为记录最近 prompt 的测试生成器。
    // 返回值：无。
    private static func test_anthropic_tool_result_round_trip(
        _ fake: FakeGenerator
    ) throws {
        let payload: [String: Any] = [
            "model": "gemini-3.6-flash",
            "messages": [
                [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "id": "toolu_existing",
                        "name": "Read",
                        "input": ["file_path": "README.md"],
                    ]],
                ],
                [
                    "role": "user",
                    "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_existing",
                    "is_error": true,
                    "content": "Gemini2API tool result",
                    ]],
                ],
            ],
            "tools": [[
                "name": "Read",
                "description": "Read a file",
                "input_schema": ["type": "object"],
            ]],
        ]
        let result = try post(path: "/v1/messages", payload: payload)
        precondition(result.status == 200)
        precondition(fake.last_prompt.contains("Tool result for Read"))
        precondition(fake.last_prompt.contains("id=toolu_existing"))
        precondition(fake.last_prompt.contains("status=error"))
        precondition(fake.last_prompt.contains("Gemini2API tool result"))
    }

    // 功能：验证 OpenAI 工具结果通过 call ID 恢复实际工具名称。
    // 参数：无。
    // 返回值：无。
    private static func test_openai_tool_history_preserves_name() throws {
        let request: [String: Any] = [
            "messages": [
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [[
                        "id": "call_read",
                        "type": "function",
                        "function": ["name": "Read", "arguments": "{}"],
                    ]],
                ],
                [
                    "role": "tool",
                    "tool_call_id": "call_read",
                    "content": "Gemini2API",
                ],
            ],
        ]
        let gateway_request = try parse_openai_chat_request(
            request,
            default_model: "gemini-3.6-flash")
        let prompt = gateway_prompt(gateway_request)
        precondition(prompt.contains("Tool result for Read"))
        precondition(prompt.contains("id=call_read"))
    }

    // 功能：验证两个现有协议把媒体 content part 分类为 unsupported。
    // 参数：无。
    // 返回值：无。
    private static func test_media_content_is_unsupported() {
        let openai_request: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [["type": "image_url", "image_url": ["url": "data:image/png"]]],
            ]],
        ]
        assert_gateway_error(expected_code: "unsupported_feature") {
            _ = try parse_openai_chat_request(
                openai_request,
                default_model: "gemini-3.6-flash")
        }

        let anthropic_request: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [["type": "image", "source": ["type": "base64"]]],
            ]],
        ]
        assert_gateway_error(expected_code: "unsupported_feature") {
            _ = try parse_anthropic_request(
                anthropic_request,
                default_model: "gemini-3.6-flash")
        }
    }

    // 功能：验证两个现有协议把畸形工具定义分类为 invalid_request。
    // 参数：无。
    // 返回值：无。
    private static func test_malformed_tools_are_invalid_requests() {
        let openai_request: [String: Any] = [
            "messages": [["role": "user", "content": "test"]],
            "tools": [["type": "function", "function": ["description": "missing name"]]],
        ]
        assert_gateway_error(expected_code: "invalid_request") {
            _ = try parse_openai_chat_request(
                openai_request,
                default_model: "gemini-3.6-flash")
        }

        let anthropic_request: [String: Any] = [
            "messages": [["role": "user", "content": "test"]],
            "tools": [["name": "Read"]],
        ]
        assert_gateway_error(expected_code: "invalid_request") {
            _ = try parse_anthropic_request(
                anthropic_request,
                default_model: "gemini-3.6-flash")
        }

        let missing_assistant_call_id: [String: Any] = [
            "messages": [[
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [[
                    "type": "function",
                    "function": ["name": "Read", "arguments": "{}"],
                ]],
            ]],
        ]
        assert_gateway_error(expected_code: "invalid_request") {
            _ = try parse_openai_chat_request(
                missing_assistant_call_id,
                default_model: "gemini-3.6-flash")
        }

        let missing_tool_call_id: [String: Any] = [
            "messages": [["role": "tool", "content": "result"]],
        ]
        assert_gateway_error(expected_code: "invalid_request") {
            _ = try parse_openai_chat_request(
                missing_tool_call_id,
                default_model: "gemini-3.6-flash")
        }
    }

    // 功能：验证两个现有协议把指定工具选择转换为统一 named 策略。
    // 参数：无。
    // 返回值：无。
    private static func test_named_tool_choices_are_normalized() throws {
        let openai_request: [String: Any] = [
            "messages": [["role": "user", "content": "test"]],
            "tools": [[
                "type": "function",
                "function": ["name": "Read", "parameters": ["type": "object"]],
            ]],
            "tool_choice": ["type": "function", "function": ["name": "Read"]],
        ]
        let openai = try parse_openai_chat_request(
            openai_request,
            default_model: "gemini-3.6-flash")
        precondition(openai.tool_choice.required_name == "Read")

        let anthropic_request: [String: Any] = [
            "messages": [["role": "user", "content": "test"]],
            "tools": [["name": "Read", "input_schema": ["type": "object"]]],
            "tool_choice": ["type": "tool", "name": "Read"],
        ]
        let anthropic = try parse_anthropic_request(
            anthropic_request,
            default_model: "gemini-3.6-flash")
        precondition(anthropic.tool_choice.required_name == "Read")
    }

    // 功能：执行操作并断言统一协议错误 code。
    // 参数：expected_code 为预期 code；action 为待执行操作。
    // 返回值：无。
    private static func assert_gateway_error(
        expected_code: String,
        action: () throws -> Void
    ) {
        do {
            try action()
            preconditionFailure("expected GatewayProtocolError \(expected_code)")
        } catch let error as GatewayProtocolError {
            precondition(error.code == expected_code)
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }

    // 功能：验证 OpenAI 两类畸形工具历史均通过 HTTP 返回 400。
    // 参数：无。
    // 返回值：无。
    private static func test_openai_malformed_tool_history_returns_400() throws {
        let missing_assistant_call_id: [String: Any] = [
            "messages": [[
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [[
                    "type": "function",
                    "function": ["name": "Read", "arguments": "{}"],
                ]],
            ]],
        ]
        let assistant_result = try post(
            path: "/v1/chat/completions",
            payload: missing_assistant_call_id)
        precondition(assistant_result.status == 400)

        let missing_tool_call_id: [String: Any] = [
            "messages": [["role": "tool", "content": "result"]],
        ]
        let tool_result = try post(
            path: "/v1/chat/completions",
            payload: missing_tool_call_id)
        precondition(tool_result.status == 400)
    }

    // 功能：验证 Anthropic 文本流把客户端断开传播给共享生成器。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_anthropic_stream_propagates_cancellation(
        _ fake: FakeGenerator
    ) throws {
        fake.prepare_cancellation_test()
        defer { fake.finish_cancellation_test() }
        let probe = StreamingHTTPProbe(expected_fragment: "event: content_block_start")
        let session = URLSession(
            configuration: .ephemeral,
            delegate: probe,
            delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = try anthropic_stream_task(session: session)
        task.resume()
        precondition(
            fake.stream_started.wait(timeout: .now() + 2) == .success,
            "Anthropic stream did not start")
        precondition(
            probe.fragment_received.wait(timeout: .now() + 2) == .success,
            "Anthropic start events did not reach the client")
        task.cancel()
        precondition(
            fake.stream_finished.wait(timeout: .now() + 2) == .success,
            "Anthropic stream did not finish after cancellation")
        precondition(fake.cancellation_observed)
        precondition(
            probe.completed.wait(timeout: .now() + 2) == .success,
            "cancelled Anthropic HTTP task did not finish")
        let response_text = probe.text_snapshot()
        precondition(!response_text.contains("event: content_block_stop"))
        precondition(!response_text.contains("event: message_delta"))
        precondition(!response_text.contains("event: message_stop"))
    }

    // 功能：验证 Anthropic 首个文本 delta 在生成器结束前到达客户端。
    // 参数：fake 为首个 delta 后等待释放的可控生成器。
    // 返回值：无。
    private static func test_anthropic_text_stream_is_incremental(
        _ fake: FakeGenerator
    ) throws {
        fake.prepare_delayed_stream_test(["first", "second"])
        defer {
            fake.release_delayed_stream()
            fake.finish_delayed_stream_test()
        }
        let probe = StreamingHTTPProbe(expected_fragment: "\"text\":\"first\"")
        let session = URLSession(
            configuration: .ephemeral,
            delegate: probe,
            delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = try anthropic_stream_task(session: session)
        task.resume()

        precondition(
            fake.stream_started.wait(timeout: .now() + 2) == .success,
            "delayed Anthropic generator did not start")
        precondition(
            probe.fragment_received.wait(timeout: .now() + 1) == .success,
            "Anthropic first delta arrived only after generation completed")
        precondition(
            fake.stream_finished.wait(timeout: .now()) == .timedOut,
            "Anthropic generator ended before the first HTTP delta arrived")
        let partial_text = probe.text_snapshot()
        precondition(partial_text.contains("event: message_start"))
        precondition(partial_text.contains("event: content_block_start"))
        precondition(!partial_text.contains("\"text\":\"second\""))
        precondition(!partial_text.contains("event: message_stop"))

        fake.release_delayed_stream()
        precondition(
            probe.completed.wait(timeout: .now() + 2) == .success,
            "Anthropic stream did not finish after release")
        precondition(probe.completion_error == nil)
        precondition(probe.response_status == 200)
        let final_text = probe.text_snapshot()
        let first_range = final_text.range(of: "\"text\":\"first\"")
        let second_range = final_text.range(of: "\"text\":\"second\"")
        precondition(first_range != nil && second_range != nil)
        precondition(first_range!.lowerBound < second_range!.lowerBound)
        let events = try sse_events(Data(final_text.utf8))
        precondition(events.compactMap { $0["type"] as? String } == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ])
        let message = events[0]["message"] as? [String: Any]
        precondition((message?["id"] as? String)?.hasPrefix("msg_") == true)
        precondition(message?["model"] as? String == "gemini-3.6-flash")
        let start_usage = message?["usage"] as? [String: Any]
        precondition((start_usage?["input_tokens"] as? Int ?? 0) > 0)
        precondition(start_usage?["output_tokens"] as? Int == 0)
        let final_usage = events[5]["usage"] as? [String: Any]
        precondition((final_usage?["output_tokens"] as? Int ?? 0) > 0)
        precondition(final_text.hasSuffix(
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
    }

    // 功能：验证 stream:true 的 Responses 文本请求返回完整 SSE 顺序。
    // 参数：无。
    // 返回值：无。
    private static func test_responses_text_stream() throws {
        let result = try post(
            path: "/v1/responses",
            payload: [
                "model": "gemini-3.6-flash",
                "stream": true,
                "input": "Summarize",
            ])
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        precondition(events.map { $0["type"] as? String } == [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_text.delta",
            "response.output_text.done",
            "response.content_part.done",
            "response.output_item.done",
            "response.completed",
        ])
        precondition(events[4]["delta"] as? String == "fake stream")
        let final_response = events.last?["response"] as? [String: Any]
        let output = final_response?["output"] as? [[String: Any]]
        let content = output?.first?["content"] as? [[String: Any]]
        precondition(content?.first?["text"] as? String == "fake stream")
    }

    // 功能：验证有活动工具的 Responses 流使用完整生成结果。
    // 参数：无。
    // 返回值：无。
    private static func test_responses_tool_stream() throws {
        let result = try post(
            path: "/v1/responses",
            payload: [
                "model": "gemini-3.6-flash",
                "stream": true,
                "input": "Read README.md",
                "tools": [[
                    "type": "function",
                    "name": "Read",
                    "description": "Read a file",
                    "parameters": ["type": "object"],
                ]],
            ])
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        let types = events.compactMap { $0["type"] as? String }
        precondition(types.contains("response.function_call_arguments.delta"))
        precondition(types.contains("response.function_call_arguments.done"))
        precondition(types.last == "response.completed")
        let final_response = events.last?["response"] as? [String: Any]
        let output = final_response?["output"] as? [[String: Any]]
        precondition(output?.first?["type"] as? String == "function_call")
        precondition(output?.first?["name"] as? String == "Read")
    }

    // 功能：验证 SSE header 后的 Responses 上游失败只产生 error event。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_responses_stream_error(_ fake: FakeGenerator) throws {
        fake.set_stream_failure(true)
        defer { fake.set_stream_failure(false) }
        let result = try post(
            path: "/v1/responses",
            payload: ["stream": true, "input": "Fail after header"])
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        precondition(events.map { $0["type"] as? String } == [
            "response.created",
            "response.in_progress",
            "error",
        ])
        precondition(events.last?["code"] as? String == "upstream_error")
        precondition(!result.text.contains("response.output_text.delta"))
        precondition(!result.text.contains("response.completed"))
    }

    // 功能：验证 Responses 文本流把客户端断开传播给共享生成器。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_responses_stream_propagates_cancellation(
        _ fake: FakeGenerator
    ) throws {
        fake.prepare_cancellation_test()
        defer { fake.finish_cancellation_test() }
        let url = URL(string: "http://127.0.0.1:\(testPort)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "stream": true,
            "input": "wait",
        ])
        let task = URLSession.shared.dataTask(with: request)
        task.resume()
        precondition(
            fake.stream_started.wait(timeout: .now() + 2) == .success,
            "Responses stream did not start")
        task.cancel()
        precondition(
            fake.stream_finished.wait(timeout: .now() + 2) == .success,
            "Responses stream did not finish after cancellation")
        precondition(fake.cancellation_observed)
    }

    // 功能：验证每个 Gemini 文本 delta 独占一个 chunk，
    // 且末块携带结束原因和完整 usage。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_text_stream(_ fake: FakeGenerator) throws {
        fake.set_stream_deltas(["Hel", "lo"])
        defer { fake.set_stream_deltas(["fake stream"]) }
        let result = try post(
            path: "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
            payload: gemini_text_request())
        precondition(result.status == 200)
        precondition(!result.text.contains("[DONE]"))
        let events = try sse_events(result.data)
        precondition(events.count == 2)
        precondition(gemini_text(events[0]) == "Hel")
        precondition(gemini_text(events[1]) == "lo")
        precondition(gemini_candidate(events[0])?["finishReason"] == nil)
        precondition(gemini_candidate(events[1])?["finishReason"] as? String == "STOP")
        let usage = events[1]["usageMetadata"] as? [String: Any]
        let input_tokens = usage?["promptTokenCount"] as? Int ?? -1
        let output_tokens = usage?["candidatesTokenCount"] as? Int ?? -1
        precondition(input_tokens > 0)
        precondition(output_tokens > 0)
        precondition(usage?["totalTokenCount"] as? Int == input_tokens + output_tokens)
    }

    // 功能：验证 Gemini 工具流只产生一个完整 functionCall chunk。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_tool_stream(_ fake: FakeGenerator) throws {
        fake.set_output("""
        prefix before tool
        ```tool_call
        {"name":"Read","arguments":{"file_path":"README.md"}}
        ```
        """)
        defer { fake.set_output(default_tool_output()) }
        let result = try post(
            path: "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
            payload: gemini_tool_request())
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        precondition(events.count == 1)
        let candidate = gemini_candidate(events[0])
        precondition(candidate?["finishReason"] as? String == "STOP")
        let content = candidate?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        precondition(parts?.count == 1)
        precondition(parts?.allSatisfy { $0["functionCall"] != nil } == true)
        let function = parts?.first?["functionCall"] as? [String: Any]
        precondition(function?["name"] as? String == "Read")
    }

    // 功能：验证 Gemini AUTO 工具流没有调用时仍返回模型文本。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_auto_tool_stream_without_call(
        _ fake: FakeGenerator
    ) throws {
        fake.set_output("AUTO text")
        defer { fake.set_output(default_tool_output()) }
        let result = try post(
            path: "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
            payload: gemini_tool_request())
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        precondition(events.count == 1)
        let content = gemini_candidate(events[0])?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        precondition(parts?.count == 1)
        precondition(parts?.first?["text"] as? String == "AUTO text")
        precondition(parts?.first?["functionCall"] == nil)
    }

    // 功能：验证 Gemini SSE header 写出后的错误使用 data error object 并结束。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_stream_error(_ fake: FakeGenerator) throws {
        fake.set_stream_failure(true)
        defer { fake.set_stream_failure(false) }
        let result = try post(
            path: "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
            payload: gemini_text_request())
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        precondition(events.count == 1)
        let error = events[0]["error"] as? [String: Any]
        precondition(error?["code"] as? Int == 502)
        precondition(error?["status"] as? String == "UNAVAILABLE")
        precondition(events[0]["candidates"] == nil)
    }

    // 功能：验证 Gemini 上游在 delta 后失败时，
    // 先写普通 delta，再写错误并关闭。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_partial_stream_error(
        _ fake: FakeGenerator
    ) throws {
        fake.set_stream_deltas(["prefix"])
        fake.set_stream_failure(true, after_deltas: true)
        defer {
            fake.set_stream_deltas(["fake stream"])
            fake.set_stream_failure(false)
        }
        let result = try post(
            path: "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
            payload: gemini_text_request())
        precondition(result.status == 200)
        let events = try sse_events(result.data)
        precondition(events.count == 2)
        precondition(gemini_text(events[0]) == "prefix")
        precondition(gemini_candidate(events[0])?["finishReason"] == nil)
        precondition(events[0]["usageMetadata"] == nil)
        let error = events[1]["error"] as? [String: Any]
        precondition(error?["code"] as? Int == 502)
        precondition(error?["status"] as? String == "UNAVAILABLE")
        precondition(!result.text.contains("[DONE]"))
    }

    // 功能：验证 Gemini 文本流把客户端断开传播给共享生成器。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_gemini_stream_propagates_cancellation(
        _ fake: FakeGenerator
    ) throws {
        fake.prepare_cancellation_test()
        defer { fake.finish_cancellation_test() }
        let suffix = "/v1beta/models/gemini-3.8-flash:streamGenerateContent"
        let url = URL(string: "http://127.0.0.1:\(testPort)\(suffix)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: gemini_text_request())
        let task = URLSession.shared.dataTask(with: request)
        task.resume()
        precondition(
            fake.stream_started.wait(timeout: .now() + 2) == .success,
            "Gemini stream did not start")
        task.cancel()
        precondition(
            fake.stream_finished.wait(timeout: .now() + 2) == .success,
            "Gemini stream did not finish after cancellation")
        precondition(fake.cancellation_observed)
    }

    // 功能：验证 method mismatch 和 Gemini 畸形 action
    // 使用 path 对应的 404 envelope。
    // 参数：无。
    // 返回值：无。
    private static func test_protocol_aware_not_found() throws {
        let openai = try request(method: "GET", path: "/v1/responses")
        precondition(openai.status == 404)
        let openai_error = try jsonObject(openai.data)["error"] as? [String: Any]
        precondition(openai_error?["code"] as? String == "not_found")

        let anthropic = try request(method: "GET", path: "/v1/messages")
        precondition(anthropic.status == 404)
        let anthropic_body = try jsonObject(anthropic.data)
        precondition(anthropic_body["type"] as? String == "error")
        let anthropic_error = anthropic_body["error"] as? [String: Any]
        precondition(anthropic_error?["type"] as? String == "not_found_error")

        let prefix = "/v1beta/models/gemini-3.8-flash"
        for target in [
            prefix + ":generateContent",
            prefix + ":unknownAction",
            prefix + ":generateContent/extra",
        ] {
            let method = target.hasSuffix(":generateContent") ? "GET" : "POST"
            let gemini = try request(method: method, path: target)
            precondition(gemini.status == 404)
            let error = try jsonObject(gemini.data)["error"] as? [String: Any]
            precondition(error?["code"] as? Int == 404)
            precondition(error?["status"] as? String == "NOT_FOUND")
        }

        let generic = try request(method: "POST", path: "/unknown")
        precondition(generic.status == 404)
        let generic_body = try jsonObject(generic.data)
        precondition(generic_body["error"] as? String == "not found")
    }

    // 功能：验证四种 API key 入口、query 解码和三类协议的 401 envelope。
    // 参数：config 为运行中服务配置；fake 为可控生成器。
    // 返回值：无。
    private static func test_protocol_aware_authentication(
        _ config: Store,
        fake: FakeGenerator
    ) throws {
        let header_key = "header-secret"
        let query_key = "query key+slash/value"
        config.apiKeys = [header_key, query_key]
        fake.set_output("authorized")
        defer {
            config.apiKeys = []
            fake.set_output("""
            ```tool_call
            {"name":"Read","arguments":{"file_path":"README.md"}}
            ```
            """)
        }
        let path = "/v1beta/models/gemini-3.8-flash:generateContent"
        let authorized_headers = [
            ["Authorization": "Bearer \(header_key)"],
            ["x-api-key": header_key],
            ["x-goog-api-key": header_key],
        ]
        for headers in authorized_headers {
            let result = try post(
                path: path,
                payload: gemini_text_request(),
                headers: headers)
            precondition(result.status == 200)
        }
        let query_result = try post(
            path: path + "?key=query%20key%2Bslash%2Fvalue",
            payload: gemini_text_request())
        precondition(query_result.status == 200)

        let conflict_result = try post(
            path: path + "?key=wrong-query",
            payload: gemini_text_request(),
            headers: [
                "Authorization": "Bearer wrong-bearer",
                "x-api-key": "wrong-x-api",
                "x-goog-api-key": header_key,
            ])
        precondition(conflict_result.status == 200)

        let openai = try post(
            path: "/v1/responses",
            payload: ["input": "Hello"],
            headers: ["Authorization": "Bearer wrong-secret"])
        precondition(openai.status == 401)
        let openai_error = try jsonObject(openai.data)["error"] as? [String: Any]
        precondition(openai_error?["message"] as? String == "invalid api key")

        let anthropic = try post(
            path: "/v1/messages",
            payload: ["messages": [["role": "user", "content": "Hello"]]],
            headers: ["x-api-key": "wrong-secret"])
        precondition(anthropic.status == 401)
        let anthropic_body = try jsonObject(anthropic.data)
        precondition(anthropic_body["type"] as? String == "error")
        let anthropic_error = anthropic_body["error"] as? [String: Any]
        precondition(anthropic_error?["type"] as? String == "authentication_error")

        let gemini = try post(
            path: path + "?key=wrong-secret",
            payload: gemini_text_request())
        precondition(gemini.status == 401)
        let gemini_error = try jsonObject(gemini.data)["error"] as? [String: Any]
        precondition(gemini_error?["code"] as? Int == 401)
        precondition(gemini_error?["status"] as? String == "UNAUTHENTICATED")
        let combined = openai.text + anthropic.text + gemini.text
        precondition(!combined.contains(header_key))
        precondition(!combined.contains(query_key))
        precondition(!combined.contains("wrong-secret"))
    }

    private static func testTokenCount() throws {
        let result = try post(
            path: "/v1/messages/count_tokens",
            payload: requestPayload(stream: false))
        precondition(result.status == 200)
        let body = try jsonObject(result.data)
        precondition((body["input_tokens"] as? Int ?? 0) > 0)
    }

    private static func testInvalidToolChoices() throws {
        let anthropic: [String: Any] = [
            "model": "gemini-3.6-flash",
            "messages": [["role": "user", "content": "test"]],
            "tool_choice": ["type": "any"],
        ]
        let anthropicResult = try post(path: "/v1/messages", payload: anthropic)
        precondition(anthropicResult.status == 400)

        let openAI: [String: Any] = [
            "model": "gemini-3.6-flash",
            "messages": [["role": "user", "content": "test"]],
            "tool_choice": "required",
        ]
        let openAIResult = try post(path: "/v1/chat/completions", payload: openAI)
        precondition(openAIResult.status == 400)
    }

    // 功能：验证三协议完整生成的上游 502 使用安全 envelope，
    // 且不回显错误 secret。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_protocol_http_errors_are_redacted(
        _ fake: FakeGenerator
    ) throws {
        let secret = "Bearer endpoint-secret"
        fake.set_generation_failure(secret)
        defer { fake.set_generation_failure(nil) }
        let cases: [(path: String, payload: [String: Any], kind: String)] = [
            (
                "/v1/chat/completions",
                ["messages": [["role": "user", "content": "Hello"]]],
                "openai"),
            (
                "/v1/responses",
                ["input": "Hello"],
                "openai"),
            (
                "/v1/messages",
                ["messages": [["role": "user", "content": "Hello"]]],
                "anthropic"),
            (
                "/v1beta/models/gemini-3.8-flash:generateContent",
                gemini_text_request(),
                "gemini"),
        ]
        for item in cases {
            let result = try post(path: item.path, payload: item.payload)
            try assert_redacted_error(
                result,
                protocol_kind: item.kind,
                secret: secret)
        }
    }

    // 功能：验证三协议 stream 请求的上游错误不回显 secret，
    // 且保留各自终止形状。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_protocol_stream_errors_are_redacted(
        _ fake: FakeGenerator
    ) throws {
        let secret = "Cookie stream-secret"
        fake.set_stream_failure(true, message: secret)
        defer { fake.set_stream_failure(false) }

        let openai = try post(
            path: "/v1/chat/completions",
            payload: [
                "stream": true,
                "messages": [["role": "user", "content": "Hello"]],
            ])
        precondition(openai.status == 200)
        precondition(!openai.text.contains(secret))
        precondition(openai.text.contains("\"error\":"))
        precondition(openai.text.hasSuffix("data: [DONE]\n\n"))
        precondition(!openai.text.contains("\"content\":\"[upstream error"))

        let responses = try post(
            path: "/v1/responses",
            payload: ["stream": true, "input": "Hello"])
        precondition(responses.status == 200)
        precondition(!responses.text.contains(secret))
        let response_events = try sse_events(responses.data)
        precondition(response_events.last?["type"] as? String == "error")
        precondition(response_events.last?["message"] as? String == "upstream error")
        precondition(!responses.text.contains("response.completed"))

        let anthropic = try post(
            path: "/v1/messages",
            payload: [
                "stream": true,
                "messages": [["role": "user", "content": "Hello"]],
            ])
        precondition(anthropic.status == 200)
        precondition(!anthropic.text.contains(secret))
        let anthropic_events = try sse_events(anthropic.data)
        precondition(anthropic_events.compactMap { $0["type"] as? String } == [
            "message_start",
            "content_block_start",
            "error",
        ])
        let anthropic_error = anthropic_events.last?["error"] as? [String: Any]
        precondition(anthropic_error?["type"] as? String == "api_error")
        precondition(anthropic_error?["message"] as? String == "upstream error")
        precondition(!anthropic.text.contains("event: content_block_stop"))
        precondition(!anthropic.text.contains("event: message_delta"))
        precondition(!anthropic.text.contains("event: message_stop"))
    }

    // 功能：验证三协议非流式和 stream 工具协议 502 都不会回显模型 secret。
    // 参数：fake 为可控生成器。
    // 返回值：无。
    private static func test_tool_protocol_errors_are_redacted(
        _ fake: FakeGenerator
    ) throws {
        let secret = "BearerEndpointSecret"
        fake.set_output("""
        ```tool_call
        {"name":"\(secret)","arguments":{}}
        ```
        """)
        defer { fake.set_output(default_tool_output()) }
        for stream in [false, true] {
            let cases = tool_error_requests(stream: stream)
            for item in cases {
                let result = try post(path: item.path, payload: item.payload)
                try assert_redacted_error(
                    result,
                    protocol_kind: item.kind,
                    secret: secret)
            }
        }
    }

    // 功能：创建三协议具有活动 Read 工具的请求。
    // 参数：stream 指示客户端是否请求流式响应。
    // 返回值：path、payload 和协议分类数组。
    private static func tool_error_requests(
        stream: Bool
    ) -> [(path: String, payload: [String: Any], kind: String)] {
        [
            (
                "/v1/chat/completions",
                [
                    "stream": stream,
                    "messages": [["role": "user", "content": "Read"]],
                    "tools": [[
                        "type": "function",
                        "function": [
                            "name": "Read",
                            "parameters": ["type": "object"],
                        ],
                    ]],
                ],
                "openai"),
            (
                "/v1/responses",
                [
                    "stream": stream,
                    "input": "Read",
                    "tools": [[
                        "type": "function",
                        "name": "Read",
                        "parameters": ["type": "object"],
                    ]],
                ],
                "openai"),
            (
                "/v1/messages",
                [
                    "stream": stream,
                    "messages": [["role": "user", "content": "Read"]],
                    "tools": [[
                        "name": "Read",
                        "description": "Read a file",
                        "input_schema": ["type": "object"],
                    ]],
                ],
                "anthropic"),
        ]
    }

    // 功能：断言 HTTP 502 错误遵循指定协议 envelope 且不包含 secret。
    // 参数：result 为响应；protocol_kind 为协议；secret 为禁止回显文本。
    // 返回值：无。
    private static func assert_redacted_error(
        _ result: HTTPResult,
        protocol_kind: String,
        secret: String
    ) throws {
        precondition(result.status == 502)
        precondition(!result.text.contains(secret))
        let body = try jsonObject(result.data)
        if protocol_kind == "anthropic" {
            precondition(body["type"] as? String == "error")
            let error = body["error"] as? [String: Any]
            precondition(error?["type"] as? String == "api_error")
            let message = error?["message"] as? String
            precondition(message == "upstream error"
                || message == "upstream tool protocol error")
        } else if protocol_kind == "gemini" {
            let error = body["error"] as? [String: Any]
            precondition(error?["code"] as? Int == 502)
            precondition(error?["status"] as? String == "UNAVAILABLE")
            precondition(error?["message"] as? String == "upstream error")
        } else {
            let error = body["error"] as? [String: Any]
            let message = error?["message"] as? String
            precondition(message == "upstream error"
                || message == "upstream tool protocol error")
        }
    }

    private static func requestPayload(stream: Bool) -> [String: Any] {
        [
            "model": "gemini-3.6-flash",
            "max_tokens": 1024,
            "stream": stream,
            "messages": [["role": "user", "content": "Read README.md"]],
            "tools": [[
                "name": "Read",
                "description": "Read a file",
                "input_schema": [
                    "type": "object",
                    "properties": ["file_path": ["type": "string"]],
                    "required": ["file_path"],
                ],
            ]],
        ]
    }

    // 功能：创建声明 Read 工具的 OpenAI Chat 请求。
    // 参数：无。
    // 返回值：OpenAI Chat JSON 对象。
    private static func openai_tool_request() -> [String: Any] {
        [
            "messages": [["role": "user", "content": "Read README.md"]],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "Read",
                    "description": "Read a file",
                    "parameters": ["type": "object"],
                ],
            ]],
        ]
    }

    // 功能：创建含工具调用和工具结果续轮的 OpenAI Chat 请求。
    // 参数：无。
    // 返回值：OpenAI Chat JSON 对象。
    private static func openai_tool_result_request() -> [String: Any] {
        [
            "messages": [
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [[
                        "id": "call_read",
                        "type": "function",
                        "function": [
                            "name": "Read",
                            "arguments": "{\"file_path\":\"README.md\"}",
                        ],
                    ]],
                ],
                [
                    "role": "tool",
                    "tool_call_id": "call_read",
                    "content": "chat tool result",
                ],
            ],
        ]
    }

    // 功能：创建声明 Read 工具的 OpenAI Responses 请求。
    // 参数：无。
    // 返回值：Responses JSON 对象。
    private static func responses_tool_request() -> [String: Any] {
        [
            "input": "Read README.md",
            "tools": [[
                "type": "function",
                "name": "Read",
                "description": "Read a file",
                "parameters": ["type": "object"],
            ]],
        ]
    }

    // 功能：创建含 function_call 与输出续轮的 Responses 请求。
    // 参数：无。
    // 返回值：Responses JSON 对象。
    private static func responses_tool_result_request() -> [String: Any] {
        [
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_read",
                    "name": "Read",
                    "arguments": "{\"file_path\":\"README.md\"}",
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_read",
                    "output": "responses tool result",
                ],
            ],
        ]
    }

    // 功能：创建含 tool_use 与 tool_result 续轮的 Anthropic 请求。
    // 参数：无。
    // 返回值：Anthropic Messages JSON 对象。
    private static func anthropic_tool_result_request() -> [String: Any] {
        [
            "messages": [
                [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "id": "toolu_read",
                        "name": "Read",
                        "input": ["file_path": "README.md"],
                    ]],
                ],
                [
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": "toolu_read",
                        "content": "anthropic tool result",
                    ]],
                ],
            ],
        ]
    }

    // 功能：创建含 functionCall 与 functionResponse 续轮的 Gemini 请求。
    // 参数：无。
    // 返回值：Gemini GenerateContent JSON 对象。
    private static func gemini_tool_result_request() -> [String: Any] {
        [
            "contents": [
                [
                    "role": "model",
                    "parts": [["functionCall": [
                        "id": "call_read",
                        "name": "Read",
                        "args": ["file_path": "README.md"],
                    ]]],
                ],
                [
                    "role": "user",
                    "parts": [["functionResponse": [
                        "id": "call_read",
                        "name": "Read",
                        "response": ["content": "gemini tool result"],
                    ]]],
                ],
            ],
        ]
    }

    // 功能：返回测试生成器默认的合法 Read 工具调用文本。
    // 参数：无。
    // 返回值：结构化工具 block。
    private static func default_tool_output() -> String {
        """
        ```tool_call
        {"name":"Read","arguments":{"file_path":"README.md"}}
        ```
        """
    }

    private static func post(
        path: String,
        payload: [String: Any],
        headers: [String: String] = [:]
    ) throws -> HTTPResult {
        try request(
            method: "POST",
            path: path,
            payload: payload,
            headers: headers)
    }

    // 功能：创建用于观测 Anthropic 实时文本流的 HTTP task。
    // 参数：session 为带增量 delegate 的 URLSession。
    // 返回值：尚未启动的 URLSessionDataTask。
    private static func anthropic_stream_task(
        session: URLSession
    ) throws -> URLSessionDataTask {
        let url = URL(string: "http://127.0.0.1:\(testPort)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gemini-3.6-flash",
            "stream": true,
            "messages": [["role": "user", "content": "stream now"]],
        ])
        return session.dataTask(with: request)
    }

    // 功能：执行任意 method 的 HTTP 请求，供路由 method mismatch 测试使用。
    // 参数：method、path 标识请求；payload 为可选 JSON；headers 为额外 header。
    // 返回值：HTTP status 和响应体。
    private static func request(
        method: String,
        path: String,
        payload: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) throws -> HTTPResult {
        let url = URL(string: "http://127.0.0.1:\(testPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let payload = payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var captured: Result<HTTPResult, Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                captured = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                captured = .success(HTTPResult(status: status, data: data ?? Data()))
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + requestTimeoutSeconds) == .success else {
            throw NSError(domain: "HTTPServerIntegrationTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "request timed out"])
        }
        return try captured.get()
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HTTPServerIntegrationTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "response is not a JSON object"])
        }
        return object
    }

    // 功能：创建最小 Gemini 文本请求。
    // 参数：无。
    // 返回值：Gemini JSON 对象。
    private static func gemini_text_request() -> [String: Any] {
        ["contents": [["parts": [["text": "Hello"]]]]]
    }

    // 功能：创建声明 Read 的 Gemini 工具请求。
    // 参数：无。
    // 返回值：Gemini JSON 对象。
    private static func gemini_tool_request() -> [String: Any] {
        [
            "contents": [["parts": [["text": "Read README.md"]]]],
            "tools": [["functionDeclarations": [[
                "name": "Read",
                "description": "Read a file",
                "parameters": ["type": "object"],
            ]]]],
        ]
    }

    // 功能：提取 Gemini 流事件的第一个 candidate。
    // 参数：event 为单个 GenerateContentResponse。
    // 返回值：首个 candidate；结构缺失时为 nil。
    private static func gemini_candidate(
        _ event: [String: Any]
    ) -> [String: Any]? {
        (event["candidates"] as? [[String: Any]])?.first
    }

    // 功能：提取 Gemini 流事件的首个 text part。
    // 参数：event 为单个 GenerateContentResponse。
    // 返回值：首个文本；结构缺失时为 nil。
    private static func gemini_text(_ event: [String: Any]) -> String? {
        let content = gemini_candidate(event)?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.first?["text"] as? String
    }

    // 功能：按 data 记录解析 Responses SSE JSON 事件。
    // 参数：data 为 HTTP 响应体。
    // 返回值：按网络顺序排列的事件对象。
    private static func sse_events(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n\n")
            .compactMap { record in
                guard let data_line = record.components(separatedBy: "\n")
                    .first(where: { $0.hasPrefix("data: ") }) else {
                    return nil
                }
                let payload_text = String(data_line.dropFirst(6))
                guard payload_text != "[DONE]" else { return nil }
                let payload = Data(payload_text.utf8)
                guard let object = try JSONSerialization.jsonObject(with: payload)
                        as? [String: Any] else {
                    preconditionFailure("SSE data is not a JSON object")
                }
                return object
            }
    }
}
