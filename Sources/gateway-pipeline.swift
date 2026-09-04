import Foundation

// 用途：统一执行协议无关请求的 prompt 准备、文本生成和工具调用解析。
// 使用方法：协议适配器构造请求，再调用 prepare 和 generate 或 stream_text。

struct GatewayExecutionContext {
    let request: GatewayRequest
    let model: ResolvedModel
    let generation: GenerationRequest
    let tool_policy: ToolCallPolicy
}

final class GatewayPipeline {
    let generator: TextGenerating
    let default_model: String

    // 功能：创建使用指定生成器和默认模型的共享管线。
    // 参数：generator 为文本生成器；default_model 为未知模型的回退名称。
    // 返回值：初始化后的管线实例。
    init(generator: TextGenerating, default_model: String) {
        self.generator = generator
        self.default_model = default_model
    }

    // 功能：校验网关请求并构造模型生成上下文。
    // 参数：request 为协议适配器生成的网关请求。
    // 返回值：包含模型、prompt 和工具策略的执行上下文。
    func prepare(_ request: GatewayRequest) throws -> GatewayExecutionContext {
        try validate_tool_choice(request)
        let prompt = gateway_prompt(request)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayProtocolError.invalid_request("prompt must not be empty")
        }

        let model = resolveModel(request.model, defaultModel: default_model)
        let generation = GenerationRequest(
            prompt: prompt,
            mode: model.mode,
            think: model.think,
            extra: model.extra)
        return GatewayExecutionContext(
            request: request,
            model: model,
            generation: generation,
            tool_policy: gateway_tool_policy(request))
    }

    // 功能：执行完整生成、解析工具调用并生成协议无关结果。
    // 参数：context 为 prepare 返回的执行上下文。
    // 返回值：文本、工具调用、结束原因和近似 token 使用量。
    func generate(_ context: GatewayExecutionContext) throws -> GatewayResult {
        do {
            let raw_output = try generator.generate(context.generation)
            let parsed = try parseStructuredToolCalls(
                raw_output,
                allowedToolNames: context.tool_policy.allowedNames)
            try context.tool_policy.validate(parsed.calls)
            let tool_calls = parsed.calls.map { call in
                GatewayToolCall(id: nil, name: call.name, arguments: call.arguments)
            }
            let usage = GatewayUsage(
                input_tokens: approximateTokenCount(context.generation.prompt),
                output_tokens: approximateTokenCount(raw_output))
            return GatewayResult(
                model: context.model.name,
                text: parsed.text,
                tool_calls: tool_calls,
                finish_reason: tool_calls.isEmpty ? .stop : .tool_calls,
                usage: usage)
        } catch let error as ToolCallParseError {
            throw GatewayProtocolError.tool_protocol(error.description)
        } catch {
            throw GatewayProtocolError.upstream(String(describing: error))
        }
    }

    // 功能：执行纯文本流式生成并转发增量。
    // 参数：context 为上下文；is_cancelled 判断取消；on_delta 接收增量。
    // 返回值：无。
    func stream_text(
        _ context: GatewayExecutionContext,
        is_cancelled: @escaping () -> Bool,
        on_delta: @escaping (String) -> Void
    ) throws {
        do {
            try generator.generateStream(
                context.generation,
                isCancelled: is_cancelled,
                onDelta: on_delta)
        } catch {
            throw GatewayProtocolError.upstream(String(describing: error))
        }
    }

    // 功能：校验工具选择与声明工具集合一致。
    // 参数：request 为待校验请求。
    // 返回值：无；无效时抛出 invalid_request。
    private func validate_tool_choice(_ request: GatewayRequest) throws {
        let tool_names = Set(request.tools.map(\.name))
        switch request.tool_choice {
        case .required where tool_names.isEmpty:
            throw GatewayProtocolError.invalid_request(
                "tool_choice required needs at least one declared tool")
        case .named(let name) where !tool_names.contains(name):
            throw GatewayProtocolError.invalid_request(
                "tool_choice names undeclared tool \(name)")
        default:
            return
        }
    }
}
