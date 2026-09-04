import Foundation

// 用途：构建 OpenAI 与协议无关网关请求的单条 prompt，
// 保留角色、工具调用和续轮结果。
// 使用方法：协议适配器调用 messagesToPrompt 或 gateway_prompt，
// 再把结果交给生成器。
func messagesToPrompt(_ messages: [Any], tools: [Any]?, toolChoice: Any?) -> String {
    var parts: [String] = []
    if hasActiveTools(tools, toolChoice: toolChoice ?? "auto"),
       let section = toolUseSection(tools, toolChoice: toolChoice) {
        parts.append(section)
    }

    for value in messages {
        guard let message = value as? [String: Any] else { continue }
        let role = message["role"] as? String ?? "user"
        let content = openAIContent(message["content"])
        parts.append(openAIMessagePart(message, role: role, content: content))
    }
    return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
}

func toolUseSection(_ tools: [Any]?, toolChoice: Any?) -> String? {
    let definitions = toolDefinitions(tools)
    guard !definitions.isEmpty else { return nil }
    let serialized = jsonString(definitions, pretty: true)
    return """
    # Local Tool Protocol

    The tools below are real and are executed by the client in the user's environment. \
    When a task requires files, shell commands, search, or another listed capability, \
    call the appropriate tool instead of claiming that you cannot access it or inventing a result.

    Use exactly this format:
    ```tool_call
    {"name": "tool_name", "arguments": {}}
    ```
    Output only one or more tool_call blocks when calling tools. \
    Arguments must be one JSON object. After a tool result arrives, continue from that result.

    Available tools:
    \(serialized)\(toolChoiceInstruction(toolChoice))
    """
}

func toolDefinitions(_ tools: [Any]?) -> [[String: Any]] {
    guard let tools = tools else { return [] }
    return tools.compactMap { value in
        guard let tool = value as? [String: Any] else { return nil }
        let function = openAIFunction(tool)
        guard let name = (function["name"] ?? tool["name"]) as? String,
              !name.isEmpty else { return nil }
        return [
            "name": name,
            "description": function["description"] ?? tool["description"] ?? "",
            "parameters": function["parameters"]
                ?? tool["input_schema"]
                ?? tool["parameters"]
                ?? [:],
        ]
    }
}

private func openAIFunction(_ tool: [String: Any]) -> [String: Any] {
    guard tool["type"] as? String == "function" else { return tool }
    return tool["function"] as? [String: Any] ?? tool
}

private func openAIContent(_ value: Any?) -> String {
    if let text = value as? String { return text }
    guard let blocks = value as? [Any] else { return "" }
    return blocks.compactMap { value -> String? in
        guard let block = value as? [String: Any] else { return nil }
        let type = block["type"] as? String
        if type == "text" || type == "input_text" { return block["text"] as? String ?? "" }
        if type == "image_url" || type == "image" {
            return "[Image input is not supported by Gemini Free.]"
        }
        return nil
    }.joined(separator: " ")
}

private func openAIMessagePart(_ message: [String: Any], role: String, content: String) -> String {
    switch role {
    case "system": return "[System instruction]\n\(content)"
    case "assistant": return openAIAssistantPart(message, content: content)
    case "tool":
        let name = message["name"] as? String ?? message["tool_call_id"] as? String ?? "unknown"
        return "[Tool result for \(name)]\n\(content)"
    default: return content.isEmpty ? "" : "[User]\n\(content)"
    }
}

private func openAIAssistantPart(_ message: [String: Any], content: String) -> String {
    guard let calls = message["tool_calls"] as? [Any], !calls.isEmpty else {
        return "[Assistant]\n\(content)"
    }
    let blocks = calls.compactMap { value -> String? in
        guard let call = value as? [String: Any],
              let function = call["function"] as? [String: Any],
              let name = function["name"] as? String else { return nil }
        let arguments = decodeArguments(function["arguments"]) ?? [:]
        return toolCallBlock(name: name, arguments: arguments)
    }
    return (["[Assistant]\n\(content)"] + blocks).joined(separator: "\n")
}

private func decodeArguments(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] { return object }
    guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func toolCallBlock(name: String, arguments: [String: Any]) -> String {
    let payload: [String: Any] = ["name": name, "arguments": arguments]
    return "```tool_call\n\(jsonString(payload))\n```"
}

// 功能：把协议无关网关请求转换为 Gemini Web 使用的单条 prompt。
// 参数：request 为已规范化的网关请求。
// 返回值：包含角色、工具协议和续轮结果的 prompt；
// 无有效消息时返回空串。
func gateway_prompt(_ request: GatewayRequest) -> String {
    let message_parts = request.messages.flatMap(gateway_message_parts)
    guard !message_parts.isEmpty else { return "" }

    var parts: [String] = []
    let policy = gateway_tool_policy(request)
    if policy.active,
       let section = toolUseSection(
           gateway_tool_dictionaries(request.tools),
           toolChoice: gateway_tool_choice_dictionary(request.tool_choice)) {
        parts.append(section)
    }
    parts.append(contentsOf: message_parts)
    return parts.joined(separator: "\n\n")
}

// 功能：把一条网关消息转换为带角色标签的 prompt 片段。
// 参数：message 为待转换消息。
// 返回值：按原顺序排列的文本、工具调用和工具结果片段。
private func gateway_message_parts(_ message: GatewayMessage) -> [String] {
    var parts: [String] = []
    var text_buffer: [String] = []

    func flush_text() {
        guard !text_buffer.isEmpty else { return }
        let text = text_buffer.joined(separator: " ")
        parts.append("\(gateway_role_header(message.role))\n\(text)")
        text_buffer.removeAll()
    }

    for content in message.content {
        if case .text(let text) = content {
            if !text.isEmpty { text_buffer.append(text) }
            continue
        }

        flush_text()
        switch content {
        case .tool_call(let call):
            parts.append(toolCallBlock(name: call.name, arguments: call.arguments))
        case .tool_result(let result):
            let metadata = gateway_tool_result_metadata(result)
            parts.append("[Tool result for \(metadata)]\n\(gateway_output_text(result.output))")
        case .text:
            break
        }
    }
    flush_text()
    return parts
}

// 功能：返回网关角色对应的 prompt 标签。
// 参数：role 为消息角色。
// 返回值：准确的角色标签。
private func gateway_role_header(_ role: GatewayRole) -> String {
    switch role {
    case .system: return "[System instruction]"
    case .developer: return "[Developer instruction]"
    case .user: return "[User]"
    case .assistant: return "[Assistant]"
    case .tool: return "[Tool]"
    }
}

// 功能：组合工具结果的名称、调用 ID 与可选状态。
// 参数：result 为工具结果。
// 返回值：非空元数据；名称和调用 ID 均缺失时以 unknown 起始。
private func gateway_tool_result_metadata(_ result: GatewayToolResult) -> String {
    let name = result.name?.isEmpty == false ? result.name : nil
    let call_id = result.call_id?.isEmpty == false ? result.call_id : nil
    var parts = [name ?? call_id ?? "unknown"]
    if name != nil, let call_id = call_id { parts.append("id=\(call_id)") }
    if let is_error = result.is_error {
        parts.append("status=\(is_error ? "error" : "success")")
    }
    return parts.joined(separator: "; ")
}

// 功能：把任意工具输出转换为可读 prompt 文本。
// 参数：output 为工具输出。
// 返回值：字符串原样返回，其他 JSON 值序列化。
private func gateway_output_text(_ output: Any) -> String {
    if let text = output as? String { return text }
    if JSONSerialization.isValidJSONObject(output) { return jsonString(output) }
    return String(describing: output)
}

// 功能：把网关工具选择转换为现有工具提示词可识别的结构。
// 参数：choice 为网关工具选择。
// 返回值：字符串策略或指定工具字典。
private func gateway_tool_choice_dictionary(_ choice: GatewayToolChoice) -> Any {
    switch choice {
    case .auto: return "auto"
    case .none: return "none"
    case .required: return "required"
    case .named(let name): return ["type": "tool", "name": name]
    }
}

private func toolChoiceInstruction(_ value: Any?) -> String {
    if let choice = value as? String {
        if choice == "required" { return "\n\nIMPORTANT: You MUST call at least one tool." }
        return choice == "none" ? "\n\nIMPORTANT: Do not call tools." : ""
    }
    guard let choice = value as? [String: Any] else { return "" }
    let type = choice["type"] as? String
    if type == "any" { return "\n\nIMPORTANT: You MUST call at least one tool." }
    if type == "none" { return "\n\nIMPORTANT: Do not call tools." }
    let openAIName = (choice["function"] as? [String: Any])?["name"] as? String
    let name = openAIName ?? choice["name"] as? String
    guard (type == "tool" || openAIName != nil), let name = name, !name.isEmpty else { return "" }
    return "\n\nIMPORTANT: You MUST call only the tool \"\(name)\"."
}
