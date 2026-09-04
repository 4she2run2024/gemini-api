import Foundation
import Network

// 用途：适配 OpenAI Responses 请求和非流式响应。
// 使用方法：HTTPServer 将请求规范化后交给 GatewayPipeline 执行。

extension HTTPServer {
    // 功能：解析并执行 OpenAI Responses 请求，返回非流式 Response object。
    // 参数：conn 为客户端连接；body 为 JSON 请求体。
    // 返回值：无。
    func handle_responses(_ conn: NWConnection, body: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: body))
            as? [String: Any] else {
            sendJSON(conn, ["error": ["message": "invalid JSON"]], status: 400)
            return
        }

        do {
            let pipeline = GatewayPipeline(
                generator: generator,
                default_model: cfg.defaultModel)
            let gateway_request = try parse_responses_request(
                request,
                default_model: cfg.defaultModel)
            let context = try pipeline.prepare(gateway_request)
            let result = try pipeline.generate(context)
            sendJSON(
                conn,
                make_responses_response(
                    result,
                    response_id: "resp_" + randomHex(24)))
        } catch let error as GatewayProtocolError {
            sendJSON(
                conn,
                ["error": [
                    "message": error.description,
                    "type": error.code,
                    "code": error.code,
                ]],
                status: error.http_status)
        } catch {
            sendJSON(conn, ["error": ["message": "\(error)"]], status: 400)
        }
    }
}

// 功能：把 OpenAI Responses 请求规范化为协议无关请求。
// 参数：request 为 JSON 对象；default_model 为缺省模型。
// 返回值：可交给 GatewayPipeline 的请求。
func parse_responses_request(
    _ request: [String: Any],
    default_model: String
) throws -> GatewayRequest {
    try reject_responses_stateful_features(request)
    let tools = try parse_responses_tools(request["tools"])
    var messages: [GatewayMessage] = []
    if let instructions = request["instructions"] {
        guard let text = instructions as? String else {
            throw GatewayProtocolError.invalid_request("instructions must be a string")
        }
        messages.append(GatewayMessage(role: .system, content: [.text(text)]))
    }
    messages.append(contentsOf: try parse_responses_input(request["input"]))
    return GatewayRequest(
        model: request["model"] as? String ?? default_model,
        messages: messages,
        tools: tools,
        tool_choice: try parse_responses_tool_choice(request["tool_choice"]),
        stream: try responses_boolean(request, key: "stream", default_value: false))
}

// 功能：把统一生成结果编码成 completed OpenAI Response object。
// 参数：result 为统一结果；response_id 为响应 ID。
// 返回值：可序列化的 Response object。
func make_responses_response(
    _ result: GatewayResult,
    response_id: String
) -> [String: Any] {
    var output: [[String: Any]] = []
    if !result.text.isEmpty {
        output.append([
            "id": "msg_" + randomHex(24),
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [[
                "type": "output_text",
                "text": result.text,
                "annotations": [],
            ]],
        ])
    }
    output.append(contentsOf: result.tool_calls.map(responses_function_call_item))

    return [
        "id": response_id,
        "object": "response",
        "created_at": nowUnix(),
        "status": "completed",
        "background": false,
        "error": NSNull(),
        "incomplete_details": NSNull(),
        "instructions": NSNull(),
        "model": result.model,
        "output": output,
        "parallel_tool_calls": true,
        "previous_response_id": NSNull(),
        "store": false,
        "tool_choice": "auto",
        "tools": [],
        "usage": [
            "input_tokens": result.usage.input_tokens,
            "output_tokens": result.usage.output_tokens,
            "total_tokens": result.usage.total_tokens,
        ],
    ]
}

// 功能：拒绝当前实现无法提供的后台和服务端持久状态能力。
// 参数：request 为 Responses 请求。
// 返回值：无；启用不支持能力时抛出 unsupported。
private func reject_responses_stateful_features(
    _ request: [String: Any]
) throws {
    if try responses_boolean(request, key: "background", default_value: false) {
        throw GatewayProtocolError.unsupported("background responses are not supported")
    }
    if try responses_boolean(request, key: "store", default_value: false) {
        throw GatewayProtocolError.unsupported("stored responses are not supported")
    }
    for key in ["previous_response_id", "conversation"] {
        if responses_has_value(request[key]) {
            throw GatewayProtocolError.unsupported("\(key) is not supported")
        }
    }
}

// 功能：读取可选布尔字段并拒绝错误类型。
// 参数：request 为请求；key 为字段名；default_value 为缺省值。
// 返回值：字段布尔值或缺省值。
private func responses_boolean(
    _ request: [String: Any],
    key: String,
    default_value: Bool
) throws -> Bool {
    guard let value = request[key] else { return default_value }
    guard let boolean = value as? Bool else {
        throw GatewayProtocolError.invalid_request("\(key) must be a boolean")
    }
    return boolean
}

// 功能：判断可选状态引用是否携带非空值。
// 参数：value 为待检查字段。
// 返回值：非空字符串、集合或其他值返回 true。
private func responses_has_value(_ value: Any?) -> Bool {
    guard let value = value, !(value is NSNull) else { return false }
    if let text = value as? String { return !text.isEmpty }
    if let array = value as? [Any] { return !array.isEmpty }
    if let object = value as? [String: Any] { return !object.isEmpty }
    return true
}

// 功能：解析 string input 或 Responses input item 数组。
// 参数：value 为 input 字段。
// 返回值：按原顺序排列的统一消息。
private func parse_responses_input(_ value: Any?) throws -> [GatewayMessage] {
    if let text = value as? String {
        return [GatewayMessage(role: .user, content: [.text(text)])]
    }
    guard let values = value as? [Any], !values.isEmpty else {
        throw GatewayProtocolError.invalid_request(
            "input must be a string or non-empty item array")
    }

    var tool_names_by_id: [String: String] = [:]
    var messages: [GatewayMessage] = []
    for value in values {
        guard let item = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request("invalid input item")
        }
        let type = item["type"] as? String
        switch type {
        case "message", nil:
            messages.append(try parse_responses_message(item))
        case "function_call":
            let call = try parse_responses_function_call(item)
            if let call_id = call.id { tool_names_by_id[call_id] = call.name }
            messages.append(GatewayMessage(role: .assistant, content: [.tool_call(call)]))
        case "function_call_output":
            let result = try parse_responses_function_output(
                item,
                tool_names_by_id: tool_names_by_id)
            messages.append(GatewayMessage(role: .tool, content: [.tool_result(result)]))
        case "input_image", "input_audio", "input_file", "image", "audio", "file":
            throw GatewayProtocolError.unsupported("media content is not supported")
        default:
            throw GatewayProtocolError.invalid_request(
                "unsupported input item type: \(type ?? "missing")")
        }
    }
    return messages
}

// 功能：解析 Responses message item 的角色和文本 content。
// 参数：item 为 message item。
// 返回值：统一消息。
private func parse_responses_message(
    _ item: [String: Any]
) throws -> GatewayMessage {
    guard let role_text = item["role"] as? String,
          let role = GatewayRole(rawValue: role_text),
          role != .tool else {
        throw GatewayProtocolError.invalid_request("invalid message role")
    }
    let content = try parse_responses_message_content(item["content"])
    return GatewayMessage(role: role, content: content)
}

// 功能：解析 message 的 string、input_text 或 output_text 内容，并拒绝媒体。
// 参数：value 为 content 字段。
// 返回值：统一文本内容数组。
private func parse_responses_message_content(
    _ value: Any?
) throws -> [GatewayContent] {
    if let text = value as? String { return [.text(text)] }
    guard let blocks = value as? [Any], !blocks.isEmpty else {
        throw GatewayProtocolError.invalid_request(
            "message content must be a string or non-empty array")
    }
    return try blocks.map { value in
        guard let block = value as? [String: Any],
              let type = block["type"] as? String else {
            throw GatewayProtocolError.invalid_request("invalid content part")
        }
        if responses_media_types.contains(type) {
            throw GatewayProtocolError.unsupported("media content is not supported")
        }
        guard type == "input_text" || type == "output_text",
              let text = block["text"] as? String else {
            throw GatewayProtocolError.invalid_request(
                "unsupported content part type: \(type)")
        }
        return .text(text)
    }
}

// 功能：解析 Responses function_call item。
// 参数：item 为 function_call item。
// 返回值：统一工具调用。
private func parse_responses_function_call(
    _ item: [String: Any]
) throws -> GatewayToolCall {
    guard let call_id = item["call_id"] as? String,
          !call_id.isEmpty,
          let name = item["name"] as? String,
          !name.isEmpty,
          let arguments = decode_responses_arguments(item["arguments"]) else {
        throw GatewayProtocolError.invalid_request("invalid function_call item")
    }
    return GatewayToolCall(id: call_id, name: name, arguments: arguments)
}

// 功能：解析 function_call_output 并恢复同一轮 function_call 的名称。
// 参数：item 为输出 item；tool_names_by_id 为调用 ID 到名称的映射。
// 返回值：统一工具结果。
private func parse_responses_function_output(
    _ item: [String: Any],
    tool_names_by_id: [String: String]
) throws -> GatewayToolResult {
    guard let call_id = item["call_id"] as? String,
          !call_id.isEmpty,
          let output = item["output"],
          !(output is NSNull) else {
        throw GatewayProtocolError.invalid_request("invalid function_call_output item")
    }
    if let blocks = output as? [Any], blocks.contains(where: responses_is_media_block) {
        throw GatewayProtocolError.unsupported("media content is not supported")
    }
    return GatewayToolResult(
        call_id: call_id,
        name: tool_names_by_id[call_id],
        output: output)
}

// 功能：判断 function_call_output content part 是否为媒体。
// 参数：value 为单个结果 content part。
// 返回值：媒体类型返回 true。
private func responses_is_media_block(_ value: Any) -> Bool {
    guard let block = value as? [String: Any],
          let type = block["type"] as? String else { return false }
    return responses_media_types.contains(type)
}

// 功能：解析 function_call arguments 对象或 JSON 字符串。
// 参数：value 为 arguments 字段。
// 返回值：合法对象；否则为 nil。
private func decode_responses_arguments(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] { return object }
    guard let text = value as? String,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

// 功能：解析 Responses 顶层 function 工具，并拒绝托管内置工具。
// 参数：value 为 tools 字段。
// 返回值：统一工具数组。
private func parse_responses_tools(_ value: Any?) throws -> [GatewayTool] {
    if value == nil || value is NSNull { return [] }
    guard let values = value as? [Any] else {
        throw GatewayProtocolError.invalid_request("tools must be an array")
    }
    return try values.map { value in
        guard let tool = value as? [String: Any],
              let type = tool["type"] as? String else {
            throw GatewayProtocolError.invalid_request("invalid tool")
        }
        guard type == "function" else {
            throw GatewayProtocolError.unsupported("built-in tools are not supported")
        }
        guard let name = tool["name"] as? String, !name.isEmpty else {
            throw GatewayProtocolError.invalid_request(
                "function tool requires a non-empty name")
        }
        let parameters: [String: Any]
        if let raw_parameters = tool["parameters"] {
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
            description: tool["description"] as? String ?? "",
            parameters: parameters)
    }
}

// 功能：把 Responses tool_choice 转换为统一策略。
// 参数：value 为 tool_choice 字段。
// 返回值：统一工具选择。
private func parse_responses_tool_choice(
    _ value: Any?
) throws -> GatewayToolChoice {
    if value == nil || value is NSNull { return .auto }
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
          let name = choice["name"] as? String,
          !name.isEmpty else {
        throw GatewayProtocolError.invalid_request("invalid tool_choice")
    }
    return .named(name)
}

// 功能：把统一工具调用转换为 Responses function_call item。
// 参数：call 为统一工具调用。
// 返回值：可序列化的 function_call item。
private func responses_function_call_item(
    _ call: GatewayToolCall
) -> [String: Any] {
    [
        "id": "fc_" + randomHex(24),
        "type": "function_call",
        "status": "completed",
        "call_id": call.id ?? "call_" + randomHex(24),
        "name": call.name,
        "arguments": jsonString(call.arguments),
    ]
}

private let responses_media_types: Set<String> = [
    "input_image",
    "input_audio",
    "input_file",
    "image",
    "image_url",
    "audio",
    "file",
]
