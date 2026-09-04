import Foundation
import Network

// 用途：通过共享生成管线处理 Anthropic Messages 与 token count 请求。
// 使用方法：HTTPServer 路由调用对应 handler，并保留既有 Anthropic 响应格式。

private struct AnthropicRequestContext {
    let execution: GatewayExecutionContext
}

extension HTTPServer {
    func handleAnthropicMessages(_ conn: NWConnection, body: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendAnthropicError(conn, status: 400, message: "invalid JSON")
            return
        }
        do {
            let pipeline = GatewayPipeline(generator: generator, default_model: cfg.defaultModel)
            let gateway_request = try parse_anthropic_request(
                request,
                default_model: cfg.defaultModel)
            let context = AnthropicRequestContext(
                execution: try pipeline.prepare(gateway_request))
            try generateAnthropicMessage(conn, pipeline: pipeline, context: context)
        } catch let error as GatewayProtocolError {
            sendAnthropicError(
                conn,
                status: error.http_status,
                message: anthropic_error_message(error))
        } catch {
            sendAnthropicError(conn, status: 502, message: "upstream error")
        }
    }

    func handleAnthropicTokenCount(_ conn: NWConnection, body: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendAnthropicError(conn, status: 400, message: "invalid JSON")
            return
        }
        do {
            let gateway_request = try parse_anthropic_request(
                request,
                default_model: cfg.defaultModel)
            let prompt = gateway_prompt(gateway_request)
            sendJSON(conn, ["input_tokens": approximateTokenCount(prompt)])
        } catch let error as GatewayProtocolError {
            sendAnthropicError(
                conn,
                status: error.http_status,
                message: anthropic_error_message(error))
        } catch {
            sendAnthropicError(conn, status: 400, message: "invalid request")
        }
    }

    private func generateAnthropicMessage(
        _ conn: NWConnection,
        pipeline: GatewayPipeline,
        context: AnthropicRequestContext
    ) throws {
        if context.execution.request.stream && !context.execution.tool_policy.active {
            try stream_anthropic_text(conn, pipeline: pipeline, context: context)
            return
        }
        let result = try pipeline.generate(context.execution)
        let message = makeAnthropicMessage(AnthropicMessageBuildInput(
            model: context.execution.model.name,
            prompt: context.execution.generation.prompt,
            result: result))
        if context.execution.request.stream {
            startSSE(conn)
            sseFinish(conn, anthropicSSE(message))
        } else {
            sendJSON(conn, message)
        }
    }

    // 功能：通过共享流式接口生成纯文本，
    // 并按既有 Anthropic 事件顺序编码。
    // 参数：conn 为连接；pipeline 为共享管线；context 为执行上下文。
    // 返回值：无。
    private func stream_anthropic_text(
        _ conn: NWConnection,
        pipeline: GatewayPipeline,
        context: AnthropicRequestContext
    ) throws {
        let gone = ClientGone()
        conn.stateUpdateHandler = { state in
            if case .failed = state { gone.on = true }
            if case .cancelled = state { gone.on = true }
        }
        // 请求体已经读取完成；额外接收只用于在尚未发送 SSE 时
        // 感知客户端 EOF。
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            _, _, is_complete, error in
            if is_complete || error != nil { gone.on = true }
        }
        var raw_output = ""
        try pipeline.stream_text(
            context.execution,
            is_cancelled: { gone.on },
            on_delta: { raw_output += $0 })
        guard !gone.on else { return }
        let output = ParsedToolOutput(text: raw_output, calls: [])
        let message = makeAnthropicMessage(AnthropicMessageBuildInput(
            model: context.execution.model.name,
            prompt: context.execution.generation.prompt,
            rawOutput: raw_output,
            output: output))
        startSSE(conn)
        sseFinish(conn, anthropicSSE(message))
    }

    private func sendAnthropicError(_ conn: NWConnection, status: Int, message: String) {
        let type = status >= 500 ? "api_error" : "invalid_request_error"
        let error: [String: Any] = [
            "type": "error",
            "error": ["type": type, "message": message],
        ]
        sendJSON(conn, error, status: status)
    }
}

// 功能：为统一错误恢复 Anthropic 既有错误消息前缀。
// 参数：error 为统一协议错误。
// 返回值：客户端可见错误消息。
private func anthropic_error_message(_ error: GatewayProtocolError) -> String {
    gateway_client_error_message(error)
}
