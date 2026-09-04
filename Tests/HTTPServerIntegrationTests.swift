// 用途：验证现有 OpenAI 与 Anthropic HTTP endpoint 的共享管线回归行为。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import Foundation

private final class FakeGenerator: TextGenerating {
    private(set) var last_prompt = ""
    private(set) var cancellation_observed = false
    private(set) var stream_started = DispatchSemaphore(value: 0)
    private(set) var stream_finished = DispatchSemaphore(value: 0)
    private var wait_for_cancellation = false

    func generate(_ request: GenerationRequest) throws -> String {
        last_prompt = request.prompt
        return """
        ```tool_call
        {"name":"Read","arguments":{"file_path":"README.md"}}
        ```
        """
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
        onDelta("fake stream")
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
}

private struct HTTPResult {
    let status: Int
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
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
        try test_anthropic_stream_propagates_cancellation(fake)
        try testTokenCount()
        try testInvalidToolChoices()
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
        let url = URL(string: "http://127.0.0.1:\(testPort)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gemini-3.6-flash",
            "stream": true,
            "messages": [["role": "user", "content": "wait"]],
        ])
        let task = URLSession.shared.dataTask(with: request)
        task.resume()
        precondition(
            fake.stream_started.wait(timeout: .now() + 2) == .success,
            "Anthropic stream did not start")
        task.cancel()
        precondition(
            fake.stream_finished.wait(timeout: .now() + 2) == .success,
            "Anthropic stream did not finish after cancellation")
        precondition(fake.cancellation_observed)
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

    private static func post(path: String, payload: [String: Any]) throws -> HTTPResult {
        let url = URL(string: "http://127.0.0.1:\(testPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
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
}
