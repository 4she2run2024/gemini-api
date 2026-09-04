import Foundation

// 用途：验证协议无关 prompt、工具策略与统一生成管线。
// 使用方法：由 bash Tests/run-tests.sh [--auto] 编译并执行。

private enum FakeGatewayError: Error {
    case failed
}

private final class FakeGatewayGenerator: TextGenerating {
    var output = """
    ```tool_call
    {"name":"Read","arguments":{"file_path":"README.md"}}
    ```
    """
    var error: Error?

    // 功能：返回预设生成结果，或抛出预设错误。
    // 参数：request 为待生成请求。
    // 返回值：预设文本。
    func generate(_ request: GenerationRequest) throws -> String {
        if let error = error { throw error }
        return output
    }

    // 功能：通过回调返回预设流式结果，或抛出预设错误。
    // 参数：request 为生成请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if let error = error { throw error }
        if !isCancelled() { onDelta(output) }
    }
}

@main
struct GatewayPipelineTests {
    // 功能：运行 prompt、策略、校验、生成和流式输出测试。
    // 参数：无。
    // 返回值：无；断言失败或未捕获错误时终止进程。
    static func main() throws {
        test_gateway_prompt_preserves_conversation()
        test_gateway_tool_policies()
        try test_prepare_builds_generation_request()
        test_prepare_rejects_invalid_requests()
        try test_generate_returns_tool_calls()
        try test_generate_maps_errors()
        try test_stream_text_forwards_deltas()
        print("GatewayPipelineTests passed")
    }

    // 功能：验证共享 prompt 保留角色、工具调用和工具结果。
    // 参数：无。
    // 返回值：无。
    private static func test_gateway_prompt_preserves_conversation() {
        let prompt = gateway_prompt(conversation_request())
        precondition(prompt.hasPrefix("# Local Tool Protocol"))
        precondition(prompt.contains("[System instruction]"))
        precondition(prompt.contains("[Developer instruction]"))
        precondition(prompt.contains("[User]"))
        precondition(prompt.contains("[Assistant]"))
        precondition(prompt.contains("\"name\":\"Read\""))
        precondition(prompt.contains("[Tool result for Read]"))
        precondition(prompt.contains("Gemini2API"))
    }

    // 功能：验证 none、required 和 named 映射到正确工具策略。
    // 参数：无。
    // 返回值：无。
    private static func test_gateway_tool_policies() {
        let none_policy = gateway_tool_policy(request(tool_choice: .none))
        precondition(!none_policy.active)
        precondition(!none_policy.requiresCall)

        let required_policy = gateway_tool_policy(request(tool_choice: .required))
        precondition(required_policy.active)
        precondition(required_policy.requiresCall)
        precondition(required_policy.requiredName == nil)

        let named_policy = gateway_tool_policy(request(tool_choice: .named("Read")))
        precondition(named_policy.active)
        precondition(named_policy.requiresCall)
        precondition(named_policy.requiredName == "Read")
    }

    // 功能：验证 prepare 解析模型并创建生成请求。
    // 参数：无。
    // 返回值：无。
    private static func test_prepare_builds_generation_request() throws {
        let pipeline = GatewayPipeline(
            generator: FakeGatewayGenerator(),
            default_model: "gemini-3.6-flash")
        let context = try pipeline.prepare(conversation_request())
        precondition(context.model.name == "gemini-3.8-flash")
        precondition(context.generation.mode == context.model.mode)
        precondition(context.generation.think == context.model.think)
        precondition(context.generation.prompt.contains("Gemini2API"))
    }

    // 功能：验证 prepare 拒绝空 prompt 和无效工具约束。
    // 参数：无。
    // 返回值：无。
    private static func test_prepare_rejects_invalid_requests() {
        let pipeline = GatewayPipeline(
            generator: FakeGatewayGenerator(),
            default_model: "gemini-3.6-flash")
        assert_gateway_error(
            expected_code: "invalid_request",
            action: { _ = try pipeline.prepare(empty_request()) })
        assert_gateway_error(
            expected_code: "invalid_request",
            action: { _ = try pipeline.prepare(required_without_tools_request()) })
        assert_gateway_error(
            expected_code: "invalid_request",
            action: { _ = try pipeline.prepare(request(tool_choice: .named("Glob"))) })
    }

    // 功能：验证 generate 把结构化工具调用转换为 GatewayResult。
    // 参数：无。
    // 返回值：无。
    private static func test_generate_returns_tool_calls() throws {
        let generator = FakeGatewayGenerator()
        let pipeline = GatewayPipeline(
            generator: generator,
            default_model: "gemini-3.6-flash")
        let context = try pipeline.prepare(conversation_request())
        let result = try pipeline.generate(context)
        precondition(result.finish_reason == .tool_calls)
        precondition(result.tool_calls.count == 1)
        precondition(result.tool_calls[0].name == "Read")
        precondition(result.text.isEmpty)
        precondition(result.usage.input_tokens == approximateTokenCount(context.generation.prompt))
        precondition(result.usage.output_tokens == approximateTokenCount(generator.output))
    }

    // 功能：验证 generate 区分工具协议错误和上游生成错误。
    // 参数：无。
    // 返回值：无。
    private static func test_generate_maps_errors() throws {
        let generator = FakeGatewayGenerator()
        let pipeline = GatewayPipeline(
            generator: generator,
            default_model: "gemini-3.6-flash")
        let context = try pipeline.prepare(conversation_request())

        generator.output = "```tool_call\nnot-json\n```"
        assert_gateway_error(
            expected_code: "tool_protocol_error",
            action: { _ = try pipeline.generate(context) })

        generator.error = FakeGatewayError.failed
        assert_gateway_error(
            expected_code: "upstream_error",
            action: { _ = try pipeline.generate(context) })
    }

    // 功能：验证 stream_text 原样转发流式文本增量。
    // 参数：无。
    // 返回值：无。
    private static func test_stream_text_forwards_deltas() throws {
        let generator = FakeGatewayGenerator()
        generator.output = "Gemini2API stream"
        let pipeline = GatewayPipeline(
            generator: generator,
            default_model: "gemini-3.6-flash")
        let context = try pipeline.prepare(request(tool_choice: .none))
        var received = ""
        try pipeline.stream_text(
            context,
            is_cancelled: { false },
            on_delta: { received += $0 })
        precondition(received == "Gemini2API stream")
    }

    // 功能：执行操作并断言其产生指定 GatewayProtocolError code。
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

    // 功能：创建覆盖所有角色和工具续轮的请求。
    // 参数：无。
    // 返回值：网关请求。
    private static func conversation_request() -> GatewayRequest {
        GatewayRequest(
            model: "gemini-3.8-flash",
            messages: [
                GatewayMessage(role: .system, content: [.text("Follow policy")]),
                GatewayMessage(role: .developer, content: [.text("Use local tools")]),
                GatewayMessage(role: .user, content: [.text("Read the project")]),
                GatewayMessage(role: .assistant, content: [
                    .text("I will inspect it."),
                    .tool_call(GatewayToolCall(
                        id: "call_read",
                        name: "Read",
                        arguments: ["file_path": "README.md"])),
                ]),
                GatewayMessage(role: .user, content: [
                    .tool_result(GatewayToolResult(
                        call_id: "call_read",
                        name: "Read",
                        output: "Gemini2API")),
                ]),
            ],
            tools: [read_tool],
            tool_choice: .auto,
            stream: false)
    }

    // 功能：创建常规单轮请求。
    // 参数：tool_choice 为工具选择策略。
    // 返回值：网关请求。
    private static func request(tool_choice: GatewayToolChoice) -> GatewayRequest {
        GatewayRequest(
            model: "gemini-3.8-flash",
            messages: [GatewayMessage(role: .user, content: [.text("Read README.md")])],
            tools: [read_tool],
            tool_choice: tool_choice,
            stream: false)
    }

    // 功能：创建没有有效 prompt 内容的请求。
    // 参数：无。
    // 返回值：网关请求。
    private static func empty_request() -> GatewayRequest {
        GatewayRequest(
            model: "gemini-3.8-flash",
            messages: [],
            tools: [],
            tool_choice: .auto,
            stream: false)
    }

    // 功能：创建要求工具调用但未声明工具的请求。
    // 参数：无。
    // 返回值：网关请求。
    private static func required_without_tools_request() -> GatewayRequest {
        GatewayRequest(
            model: "gemini-3.8-flash",
            messages: [GatewayMessage(role: .user, content: [.text("Read README.md")])],
            tools: [],
            tool_choice: .required,
            stream: false)
    }

    private static let read_tool = GatewayTool(
        name: "Read",
        description: "Read a file",
        parameters: [
            "type": "object",
            "properties": ["file_path": ["type": "string"]],
            "required": ["file_path"],
        ])
}
