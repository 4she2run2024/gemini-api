import Foundation

// 用途：验证 OpenAI Responses 请求、响应对象和 SSE 事件契约。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

private final class FakeResponsesGenerator: TextGenerating {
    // 功能：返回固定文本以验证 Responses HTTP route 和 handler。
    // 参数：request 为待生成请求。
    // 返回值：固定响应文本。
    func generate(_ request: GenerationRequest) throws -> String {
        "Responses route"
    }

    // 功能：返回固定流式文本；本任务的非流式测试不会调用。
    // 参数：request 为生成请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if !isCancelled() { onDelta("Responses route") }
    }
}

@main
struct ResponsesProtocolTests {
    // 功能：运行输入、工具续轮、拒绝规则和输出对象测试。
    // 参数：无。
    // 返回值：无；断言失败或未捕获错误时终止进程。
    static func main() throws {
        try test_message_input_and_function_tool()
        try test_string_and_assistant_text_input()
        try test_function_call_round_trip()
        test_stateful_features_are_unsupported()
        test_media_and_builtin_tools_are_unsupported()
        test_text_response_object()
        test_function_call_response_object()
        try test_text_stream_event_contract()
        try test_text_stream_delta_is_incremental()
        try test_tool_stream_event_contract()
        try test_tool_stream_text_events_have_logprobs()
        try test_stream_error_event_contract()
        try test_http_route()
        print("ResponsesProtocolTests passed")
    }

    // 功能：验证 instructions 位于 user 消息前，且直接 function 工具被保留。
    // 参数：无。
    // 返回值：无。
    private static func test_message_input_and_function_tool() throws {
        let request: [String: Any] = [
            "model": "gemini-3.8-flash",
            "instructions": "Inspect first.",
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Read README.md"]],
            ]],
            "tools": [[
                "type": "function",
                "name": "Read",
                "description": "Read a file",
                "parameters": ["type": "object"],
            ]],
            "store": false,
        ]

        let parsed = try parse_responses_request(
            request,
            default_model: "gemini-3.6-flash")
        precondition(parsed.model == "gemini-3.8-flash")
        precondition(parsed.messages.count == 2)
        precondition(parsed.messages[0].role == .system)
        precondition(text_value(parsed.messages[0].content[0]) == "Inspect first.")
        precondition(parsed.messages[1].role == .user)
        precondition(text_value(parsed.messages[1].content[0]) == "Read README.md")
        precondition(parsed.tools.count == 1)
        precondition(parsed.tools[0].name == "Read")
    }

    // 功能：验证 string input、input_text 与 assistant output_text 均被规范化。
    // 参数：无。
    // 返回值：无。
    private static func test_string_and_assistant_text_input() throws {
        let string_request = try parse_responses_request(
            ["input": "Summarize the project"],
            default_model: "gemini-3.6-flash")
        precondition(string_request.messages.count == 1)
        precondition(string_request.messages[0].role == .user)
        precondition(
            text_value(string_request.messages[0].content[0]) == "Summarize the project")

        let item_request: [String: Any] = [
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Question"]],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Answer"]],
                ],
            ],
        ]
        let parsed = try parse_responses_request(
            item_request,
            default_model: "gemini-3.6-flash")
        precondition(parsed.messages.map(\.role) == [.user, .assistant])
        precondition(text_value(parsed.messages[1].content[0]) == "Answer")
    }

    // 功能：验证 function_call 与 function_call_output 续轮保留调用元数据。
    // 参数：无。
    // 返回值：无。
    private static func test_function_call_round_trip() throws {
        let request: [String: Any] = [
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
                    "output": "Gemini2API",
                ],
            ],
        ]
        let parsed = try parse_responses_request(
            request,
            default_model: "gemini-3.6-flash")
        precondition(parsed.messages.count == 2)
        precondition(parsed.messages[0].role == .assistant)
        if case .tool_call(let call) = parsed.messages[0].content[0] {
            precondition(call.id == "call_read")
            precondition(call.name == "Read")
            precondition(call.arguments["file_path"] as? String == "README.md")
        } else {
            preconditionFailure("function_call was not normalized")
        }
        if case .tool_result(let result) = parsed.messages[1].content[0] {
            precondition(result.call_id == "call_read")
            precondition(result.name == "Read")
            precondition(result.output as? String == "Gemini2API")
        } else {
            preconditionFailure("function_call_output was not normalized")
        }
    }

    // 功能：验证需要服务端状态的 Responses 能力均明确返回 unsupported。
    // 参数：无。
    // 返回值：无。
    private static func test_stateful_features_are_unsupported() {
        let requests: [[String: Any]] = [
            ["input": "test", "store": true],
            ["input": "test", "background": true],
            ["input": "test", "previous_response_id": "resp_previous"],
            ["input": "test", "conversation": "conv_previous"],
        ]
        for request in requests {
            assert_unsupported {
                _ = try parse_responses_request(
                    request,
                    default_model: "gemini-3.6-flash")
            }
        }
    }

    // 功能：验证媒体内容和 OpenAI 内置工具不会被静默接受。
    // 参数：无。
    // 返回值：无。
    private static func test_media_and_builtin_tools_are_unsupported() {
        let media_request: [String: Any] = [
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_image", "image_url": "data:image/png"]],
            ]],
        ]
        assert_unsupported {
            _ = try parse_responses_request(
                media_request,
                default_model: "gemini-3.6-flash")
        }

        let media_tool_output: [String: Any] = [
            "input": [[
                "type": "function_call_output",
                "call_id": "call_image",
                "output": [["type": "input_image", "image_url": "data:image/png"]],
            ]],
        ]
        assert_unsupported {
            _ = try parse_responses_request(
                media_tool_output,
                default_model: "gemini-3.6-flash")
        }

        let builtin_request: [String: Any] = [
            "input": "Search",
            "tools": [["type": "web_search_preview"]],
        ]
        assert_unsupported {
            _ = try parse_responses_request(
                builtin_request,
                default_model: "gemini-3.6-flash")
        }
    }

    // 功能：验证文本结果生成 completed Response 和 output_text item。
    // 参数：无。
    // 返回值：无。
    private static func test_text_response_object() {
        let response = make_responses_response(
            result(text: "Project summary"),
            response_id: "resp_text")
        precondition(response["id"] as? String == "resp_text")
        precondition(response["object"] as? String == "response")
        precondition(response["status"] as? String == "completed")
        let output = response["output"] as? [[String: Any]]
        precondition(output?.count == 1)
        precondition(output?.first?["type"] as? String == "message")
        let content = output?.first?["content"] as? [[String: Any]]
        precondition(content?.first?["type"] as? String == "output_text")
        precondition(content?.first?["text"] as? String == "Project summary")
        assert_usage(response)
    }

    // 功能：验证每个统一工具调用生成独立的 function_call item。
    // 参数：无。
    // 返回值：无。
    private static func test_function_call_response_object() {
        let response = make_responses_response(
            result(
                text: "",
                calls: [GatewayToolCall(
                    id: nil,
                    name: "Read",
                    arguments: ["file_path": "README.md"])]),
            response_id: "resp_tool")
        let output = response["output"] as? [[String: Any]]
        precondition(output?.count == 1)
        precondition(output?.first?["type"] as? String == "function_call")
        precondition(output?.first?["name"] as? String == "Read")
        let arguments = output?.first?["arguments"] as? String
        precondition(arguments?.contains("README.md") == true)
        assert_usage(response)
    }

    // 功能：验证文本 SSE 的类型顺序、连续序号和稳定 ID。
    // 参数：无。
    // 返回值：无。
    private static func test_text_stream_event_contract() throws {
        var encoder = ResponsesStreamEncoder(
            response_id: "resp_stream_text",
            model: "gemini-3.8-flash")
        var chunks = encoder.start_events()
        chunks.append(encoder.text_delta("Project summary"))
        chunks.append(contentsOf: encoder.finish_text(result(text: "Project summary")))
        let events = try sse_events(chunks)
        let expected_types = [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_text.delta",
            "response.output_text.done",
            "response.content_part.done",
            "response.output_item.done",
            "response.completed",
        ]
        precondition(events.compactMap { $0["type"] as? String } == expected_types)
        precondition(
            events.compactMap { $0["sequence_number"] as? Int }
                == Array(0..<expected_types.count))
        precondition((events[4]["logprobs"] as? [Any])?.isEmpty == true)
        precondition((events[5]["logprobs"] as? [Any])?.isEmpty == true)

        let response_ids = events.compactMap { event -> String? in
            let response = event["response"] as? [String: Any]
            return response?["id"] as? String
        }
        precondition(response_ids == Array(repeating: "resp_stream_text", count: 3))
        let added_item = events[2]["item"] as? [String: Any]
        let item_id = added_item?["id"] as? String
        precondition(item_id != nil)
        precondition(events[3]["item_id"] as? String == item_id)
        precondition(events[4]["item_id"] as? String == item_id)
        precondition(events[5]["item_id"] as? String == item_id)
        precondition(events[6]["item_id"] as? String == item_id)
        let done_item = events[7]["item"] as? [String: Any]
        precondition(done_item?["id"] as? String == item_id)
        let final_response = events[8]["response"] as? [String: Any]
        let final_output = final_response?["output"] as? [[String: Any]]
        precondition(final_output?.first?["id"] as? String == item_id)
        let final_content = final_output?.first?["content"] as? [[String: Any]]
        precondition(final_content?.first?["text"] as? String == "Project summary")
    }

    // 功能：验证每个 output_text delta 只携带本次新增文本。
    // 参数：无。
    // 返回值：无。
    private static func test_text_stream_delta_is_incremental() throws {
        var encoder = ResponsesStreamEncoder(
            response_id: "resp_incremental",
            model: "gemini-3.8-flash")
        var chunks = encoder.start_events()
        chunks.append(encoder.text_delta("Pro"))
        chunks.append(encoder.text_delta("ject"))
        chunks.append(contentsOf: encoder.finish_text(result(text: "Project")))
        let events = try sse_events(chunks)
        let deltas = events.filter {
            $0["type"] as? String == "response.output_text.delta"
        }
        precondition(deltas.compactMap { $0["delta"] as? String } == ["Pro", "ject"])
        let text_events = events.filter {
            let type = $0["type"] as? String
            return type == "response.output_text.delta"
                || type == "response.output_text.done"
        }
        precondition(text_events.count == 3)
        precondition(text_events.allSatisfy {
            ($0["logprobs"] as? [Any])?.isEmpty == true
        })
    }

    // 功能：验证工具 SSE 输出完整参数事件，并复用 item ID。
    // 参数：无。
    // 返回值：无。
    private static func test_tool_stream_event_contract() throws {
        var encoder = ResponsesStreamEncoder(
            response_id: "resp_stream_tool",
            model: "gemini-3.8-flash")
        let tool_result = result(
            text: "",
            calls: [GatewayToolCall(
                id: "call_read",
                name: "Read",
                arguments: ["file_path": "README.md"])])
        let events = try sse_events(encoder.start_events() + encoder.finish_tools(tool_result))
        let expected_types = [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.function_call_arguments.delta",
            "response.function_call_arguments.done",
            "response.output_item.done",
            "response.completed",
        ]
        precondition(events.compactMap { $0["type"] as? String } == expected_types)
        precondition(
            events.compactMap { $0["sequence_number"] as? Int }
                == Array(0..<expected_types.count))
        let added_item = events[2]["item"] as? [String: Any]
        let item_id = added_item?["id"] as? String
        precondition(item_id != nil)
        precondition(events[3]["item_id"] as? String == item_id)
        precondition(events[4]["item_id"] as? String == item_id)
        let done_item = events[5]["item"] as? [String: Any]
        precondition(done_item?["id"] as? String == item_id)
        let final_response = events[6]["response"] as? [String: Any]
        let final_output = final_response?["output"] as? [[String: Any]]
        precondition(final_output?.first?["id"] as? String == item_id)
        precondition(events[3]["delta"] as? String == "{\"file_path\":\"README.md\"}")
        precondition(events[4]["arguments"] as? String == "{\"file_path\":\"README.md\"}")
    }

    // 功能：验证完整生成的工具流中，文本 delta 和 done 均带空 logprobs。
    // 参数：无。
    // 返回值：无。
    private static func test_tool_stream_text_events_have_logprobs() throws {
        var encoder = ResponsesStreamEncoder(
            response_id: "resp_tool_text",
            model: "gemini-3.8-flash")
        let tool_result = result(
            text: "Inspecting",
            calls: [GatewayToolCall(
                id: "call_read",
                name: "Read",
                arguments: ["file_path": "README.md"])])
        let events = try sse_events(encoder.start_events() + encoder.finish_tools(tool_result))
        let text_events = events.filter {
            let type = $0["type"] as? String
            return type == "response.output_text.delta"
                || type == "response.output_text.done"
        }
        precondition(text_events.count == 2)
        precondition(text_events.allSatisfy {
            ($0["logprobs"] as? [Any])?.isEmpty == true
        })
    }

    // 功能：验证 header 后错误编码为协议内 error event。
    // 参数：无。
    // 返回值：无。
    private static func test_stream_error_event_contract() throws {
        var encoder = ResponsesStreamEncoder(
            response_id: "resp_stream_error",
            model: "gemini-3.8-flash")
        let events = try sse_events(
            encoder.start_events() + [encoder.error_event(.upstream("connection lost"))])
        precondition(events.map { $0["type"] as? String } == [
            "response.created",
            "response.in_progress",
            "error",
        ])
        precondition(events[2]["code"] as? String == "upstream_error")
        precondition(events[2]["message"] as? String == "connection lost")
        precondition(events[2]["param"] is NSNull)
        precondition(events[2]["sequence_number"] as? Int == 2)
    }

    // 功能：验证 POST /v1/responses 命中新 handler 并返回 completed object。
    // 参数：无。
    // 返回值：无。
    private static func test_http_route() throws {
        let config = Store()
        config.host = "127.0.0.1"
        config.port = Int.random(in: 20_000...50_000)
        let server = HTTPServer(generator: FakeResponsesGenerator(), config: config)
        try server.start()
        defer { server.stop() }
        for _ in 0..<40 where !server.running {
            Thread.sleep(forTimeInterval: 0.05)
        }
        precondition(server.running, "Responses test server did not become ready")

        let url = URL(string: "http://127.0.0.1:\(config.port)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": "test"])
        let semaphore = DispatchSemaphore(value: 0)
        var response_status = 0
        var response_data = Data()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            response_status = (response as? HTTPURLResponse)?.statusCode ?? 0
            response_data = data ?? Data()
            semaphore.signal()
        }.resume()
        precondition(semaphore.wait(timeout: .now() + 5) == .success)
        precondition(response_status == 200)
        let object = try JSONSerialization.jsonObject(with: response_data) as? [String: Any]
        precondition(object?["object"] as? String == "response")
        precondition(object?["status"] as? String == "completed")
    }

    // 功能：提取统一文本内容。
    // 参数：content 为单个统一内容。
    // 返回值：文本内容；非文本返回 nil。
    private static func text_value(_ content: GatewayContent) -> String? {
        if case .text(let text) = content { return text }
        return nil
    }

    // 功能：断言操作抛出 unsupported_feature。
    // 参数：action 为待执行操作。
    // 返回值：无。
    private static func assert_unsupported(action: () throws -> Void) {
        do {
            try action()
            preconditionFailure("expected unsupported feature")
        } catch let error as GatewayProtocolError {
            precondition(error.code == "unsupported_feature")
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }

    // 功能：创建文本或工具结果 fixture。
    // 参数：text 为文本；calls 为工具调用。
    // 返回值：固定 usage 的统一结果。
    private static func result(
        text: String,
        calls: [GatewayToolCall] = []
    ) -> GatewayResult {
        GatewayResult(
            model: "gemini-3.8-flash",
            text: text,
            tool_calls: calls,
            finish_reason: calls.isEmpty ? .stop : .tool_calls,
            usage: GatewayUsage(input_tokens: 8, output_tokens: 5))
    }

    // 功能：验证 Responses usage 字段使用统一 token 计数。
    // 参数：response 为响应对象。
    // 返回值：无。
    private static func assert_usage(_ response: [String: Any]) {
        let usage = response["usage"] as? [String: Any]
        precondition(usage?["input_tokens"] as? Int == 8)
        precondition(usage?["output_tokens"] as? Int == 5)
        precondition(usage?["total_tokens"] as? Int == 13)
    }

    // 功能：解析一组可能合并写出的 Responses SSE data 事件。
    // 参数：chunks 为 encoder 返回的 SSE 字符串。
    // 返回值：按网络顺序解析的 JSON 对象。
    private static func sse_events(
        _ chunks: [String]
    ) throws -> [[String: Any]] {
        try chunks.flatMap { chunk in
            try chunk.components(separatedBy: "\n\n").compactMap { record in
                guard record.hasPrefix("data: ") else { return nil }
                let data = Data(record.dropFirst(6).utf8)
                guard let object = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    preconditionFailure("SSE data is not a JSON object")
                }
                return object
            }
        }
    }
}
