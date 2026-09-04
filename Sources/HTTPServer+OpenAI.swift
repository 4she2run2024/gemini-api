import Foundation
import Network

// 用途：适配 OpenAI Chat Completions 请求，并保留既有响应编码。
// 使用方法：HTTPServer 将请求规范化后交给 GatewayPipeline 执行。

private struct OpenAIChatContext {
    let execution: GatewayExecutionContext
    let completion_id: String
}

private struct OpenAIResult {
    let message: [String: Any]
    let completionTokens: Int
}

extension HTTPServer {
    func handleOpenAIChat(_ conn: NWConnection, body: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendJSON(conn, ["error": ["message": "invalid JSON"]], status: 400)
            return
        }
        do {
            let pipeline = GatewayPipeline(generator: generator, default_model: cfg.defaultModel)
            let gateway_request = try parse_openai_chat_request(
                request,
                default_model: cfg.defaultModel)
            let context = OpenAIChatContext(
                execution: try pipeline.prepare(gateway_request),
                completion_id: "chatcmpl-" + randomHex(12))
            if gateway_request.stream && !context.execution.tool_policy.active {
                streamOpenAIText(conn, pipeline: pipeline, context: context)
                return
            }
            generateOpenAIResult(conn, pipeline: pipeline, context: context)
        } catch let error as GatewayProtocolError {
            sendJSON(
                conn,
                openai_error(error),
                status: error.http_status)
        } catch {
            let gateway_error = GatewayProtocolError.upstream("")
            sendJSON(conn, openai_error(gateway_error), status: 502)
        }
    }

    private func streamOpenAIText(
        _ conn: NWConnection,
        pipeline: GatewayPipeline,
        context: OpenAIChatContext
    ) {
        let gone = ClientGone()
        conn.stateUpdateHandler = { state in
            if case .failed = state { gone.on = true }
            if case .cancelled = state { gone.on = true }
        }
        startSSE(conn)
        do {
            try pipeline.stream_text(
                context.execution,
                is_cancelled: { gone.on }
            ) { delta in
                let chunk = self.openAIChunk(
                    context,
                    delta: ["content": delta],
                    finishReason: NSNull())
                self.sseSend(conn, "data: \(jsonString(chunk))\n\n", gone: gone)
            }
        } catch let error as GatewayProtocolError {
            finish_openai_stream_error(conn, error: error)
            return
        } catch {
            finish_openai_stream_error(
                conn,
                error: .upstream(""))
            return
        }
        let end = openAIChunk(context, delta: [:], finishReason: "stop")
        sseSend(conn, "data: \(jsonString(end))\n\n")
        sseFinish(conn, "data: [DONE]\n\n")
    }

    private func generateOpenAIResult(
        _ conn: NWConnection,
        pipeline: GatewayPipeline,
        context: OpenAIChatContext
    ) {
        do {
            let gateway_result = try pipeline.generate(context.execution)
            let tool_calls = gateway_result.tool_calls.map(openAIToolCall)
            var message: [String: Any] = [
                "role": "assistant",
                "content": gateway_result.text.isEmpty ? NSNull() : gateway_result.text,
            ]
            if !tool_calls.isEmpty { message["tool_calls"] = tool_calls }
            sendOpenAIResult(
                conn,
                context: context,
                result: OpenAIResult(
                    message: message,
                    completionTokens: gateway_result.usage.output_tokens))
        } catch let error as GatewayProtocolError {
            sendJSON(
                conn,
                openai_error(error),
                status: error.http_status)
        } catch {
            let gateway_error = GatewayProtocolError.upstream("")
            sendJSON(conn, openai_error(gateway_error), status: 502)
        }
    }

    // 功能：把 OpenAI Chat SSE 错误编码为 error data，并以 DONE 关闭。
    // 参数：conn 为连接；error 为统一协议错误。
    // 返回值：无。
    private func finish_openai_stream_error(
        _ conn: NWConnection,
        error: GatewayProtocolError
    ) {
        let chunk = "data: \(jsonString(openai_error(error)))\n\n"
        sseFinish(conn, chunk + "data: [DONE]\n\n")
    }

    private func openAIToolCall(_ call: GatewayToolCall) -> [String: Any] {
        [
            "id": "call_" + randomHex(16),
            "type": "function",
            "function": ["name": call.name, "arguments": jsonString(call.arguments)],
        ]
    }

    private func sendOpenAIResult(
        _ conn: NWConnection, context: OpenAIChatContext, result: OpenAIResult
    ) {
        let finishReason = result.message["tool_calls"] == nil ? "stop" : "tool_calls"
        if context.execution.request.stream {
            startSSE(conn)
            let chunk = openAIChunk(context, delta: result.message, finishReason: finishReason)
            sseFinish(conn, "data: \(jsonString(chunk))\n\ndata: [DONE]\n\n")
            return
        }
        let inputTokens = approximateTokenCount(context.execution.generation.prompt)
        sendJSON(conn, [
            "id": context.completion_id,
            "object": "chat.completion",
            "created": nowUnix(),
            "model": context.execution.model.name,
            "choices": [["index": 0, "message": result.message, "finish_reason": finishReason]],
            "usage": [
                "prompt_tokens": inputTokens,
                "completion_tokens": result.completionTokens,
                "total_tokens": inputTokens + result.completionTokens,
            ],
        ])
    }

    private func openAIChunk(
        _ context: OpenAIChatContext, delta: [String: Any], finishReason: Any
    ) -> [String: Any] {
        [
            "id": context.completion_id,
            "object": "chat.completion.chunk",
            "created": nowUnix(),
            "model": context.execution.model.name,
            "choices": [["index": 0, "delta": delta, "finish_reason": finishReason]],
        ]
    }
}

// 功能：把 OpenAI Chat 请求规范化为协议无关请求。
// 参数：request 为 JSON 对象；default_model 为缺省模型。
// 返回值：可交给 GatewayPipeline 的请求。
func parse_openai_chat_request(
    _ request: [String: Any],
    default_model: String
) throws -> GatewayRequest {
    guard let raw_messages = request["messages"] as? [Any], !raw_messages.isEmpty else {
        throw GatewayProtocolError.invalid_request("messages must be a non-empty array")
    }
    let tools = try parse_openai_tools(request["tools"])
    return GatewayRequest(
        model: request["model"] as? String ?? default_model,
        messages: try parse_openai_messages(raw_messages),
        tools: tools,
        tool_choice: try parse_openai_tool_choice(request["tool_choice"]),
        stream: request["stream"] as? Bool ?? false)
}

// 功能：把 OpenAI 消息按原顺序转换为统一消息。
// 参数：values 为消息数组。
// 返回值：规范化消息数组。
private func parse_openai_messages(_ values: [Any]) throws -> [GatewayMessage] {
    var tool_names_by_id: [String: String] = [:]
    return try values.map { value in
        guard let message = value as? [String: Any],
              let role_text = message["role"] as? String,
              let role = GatewayRole(rawValue: role_text) else {
            throw GatewayProtocolError.invalid_request("invalid message role")
        }
        var content = try parse_openai_content(message["content"])
        if let raw_calls = message["tool_calls"] {
            guard role == .assistant, let calls = raw_calls as? [Any] else {
                throw GatewayProtocolError.invalid_request(
                    "tool_calls must be an array in an assistant message")
            }
            for raw_call in calls {
                let call = try parse_openai_tool_call(raw_call)
                content.append(.tool_call(call))
                if let id = call.id { tool_names_by_id[id] = call.name }
            }
        }
        if role == .tool {
            guard let call_id = message["tool_call_id"] as? String, !call_id.isEmpty else {
                throw GatewayProtocolError.invalid_request(
                    "tool message requires a non-empty tool_call_id")
            }
            let declared_name = message["name"] as? String
            let name = declared_name ?? tool_names_by_id[call_id]
            let output = openai_tool_output(content)
            content = [.tool_result(GatewayToolResult(
                call_id: call_id,
                name: name,
                output: output))]
        }
        return GatewayMessage(role: role, content: content)
    }
}

// 功能：转换 OpenAI 字符串或文本 content part，并拒绝媒体输入。
// 参数：value 为 content 字段。
// 返回值：统一内容数组。
private func parse_openai_content(_ value: Any?) throws -> [GatewayContent] {
    if value == nil || value is NSNull { return [] }
    if let text = value as? String { return [.text(text)] }
    guard let blocks = value as? [Any] else {
        throw GatewayProtocolError.invalid_request(
            "message content must be a string or content part array")
    }
    return try blocks.map { value in
        guard let block = value as? [String: Any],
              let type = block["type"] as? String else {
            throw GatewayProtocolError.invalid_request("invalid content part")
        }
        if ["image", "image_url", "audio", "input_audio"].contains(type) {
            throw GatewayProtocolError.unsupported("media content is not supported")
        }
        guard type == "text" || type == "input_text",
              let text = block["text"] as? String else {
            throw GatewayProtocolError.invalid_request(
                "unsupported content part type: \(type)")
        }
        return .text(text)
    }
}

// 功能：解析 OpenAI assistant 工具调用。
// 参数：value 为单个 tool_calls 元素。
// 返回值：统一工具调用。
private func parse_openai_tool_call(_ value: Any) throws -> GatewayToolCall {
    guard let call = value as? [String: Any],
          let id = call["id"] as? String,
          !id.isEmpty,
          call["type"] as? String == "function",
          let function = call["function"] as? [String: Any],
          let name = function["name"] as? String,
          !name.isEmpty,
          let arguments = decode_openai_arguments(function["arguments"]) else {
        throw GatewayProtocolError.invalid_request("invalid assistant tool call")
    }
    return GatewayToolCall(
        id: id,
        name: name,
        arguments: arguments)
}

// 功能：解析 OpenAI 工具调用参数对象或其 JSON 字符串。
// 参数：value 为 arguments 字段。
// 返回值：合法对象；否则为 nil。
private func decode_openai_arguments(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] { return object }
    guard let text = value as? String,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

// 功能：提取 tool 角色消息的文本输出。
// 参数：content 为已规范化内容。
// 返回值：按空格连接的文本。
private func openai_tool_output(_ content: [GatewayContent]) -> String {
    content.compactMap { item in
        if case .text(let text) = item { return text }
        return nil
    }.joined(separator: " ")
}

// 功能：把 OpenAI function 工具声明转换为统一工具。
// 参数：value 为 tools 字段。
// 返回值：规范化工具数组。
private func parse_openai_tools(_ value: Any?) throws -> [GatewayTool] {
    if value == nil { return [] }
    guard let values = value as? [Any] else {
        throw GatewayProtocolError.invalid_request("tools must be an array")
    }
    return try values.map { value in
        guard let tool = value as? [String: Any],
              tool["type"] as? String == "function",
              let function = tool["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.isEmpty else {
            throw GatewayProtocolError.invalid_request(
                "each tool must contain a non-empty function name")
        }
        let parameters: [String: Any]
        if let raw_parameters = function["parameters"] {
            guard let object = raw_parameters as? [String: Any] else {
                throw GatewayProtocolError.invalid_request(
                    "tool parameters must be an object")
            }
            parameters = object
        } else {
            parameters = [:]
        }
        return GatewayTool(
            name: name,
            description: function["description"] as? String ?? "",
            parameters: parameters)
    }
}

// 功能：把 OpenAI tool_choice 转换为统一策略。
// 参数：value 为 tool_choice 字段。
// 返回值：统一工具选择。
private func parse_openai_tool_choice(_ value: Any?) throws -> GatewayToolChoice {
    if value == nil { return .auto }
    if let choice = value as? String {
        switch choice {
        case "auto": return .auto
        case "none": return .none
        case "required": return .required
        default:
            throw GatewayProtocolError.invalid_request("invalid tool_choice")
        }
    }
    guard let choice = value as? [String: Any],
          choice["type"] as? String == "function",
          let function = choice["function"] as? [String: Any],
          let name = function["name"] as? String,
          !name.isEmpty else {
        throw GatewayProtocolError.invalid_request("invalid tool_choice")
    }
    return .named(name)
}
