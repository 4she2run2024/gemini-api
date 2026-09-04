import Foundation

// 用途：适配 Anthropic Messages 请求，并生成既有 Message 与 SSE 响应。
// 使用方法：将请求规范化为 GatewayRequest，执行后再调用响应编码函数。

struct AnthropicMessageBuildInput {
    let model: String
    let prompt: String
    let output: ParsedToolOutput
    let output_tokens: Int

    // 功能：从既有原始模型输出创建 Anthropic 响应输入。
    // 参数：model 为模型；prompt 为输入；rawOutput 为原始输出；
    // output 为解析结果。
    // 返回值：初始化后的响应输入。
    init(model: String, prompt: String, rawOutput: String, output: ParsedToolOutput) {
        self.model = model
        self.prompt = prompt
        self.output = output
        output_tokens = approximateTokenCount(rawOutput)
    }

    // 功能：从共享管线结果创建 Anthropic 响应输入。
    // 参数：model 为模型；prompt 为输入；result 为统一结果。
    // 返回值：初始化后的响应输入。
    init(model: String, prompt: String, result: GatewayResult) {
        self.model = model
        self.prompt = prompt
        output = ParsedToolOutput(
            text: result.text,
            calls: result.tool_calls.map { call in
                ParsedToolCall(name: call.name, arguments: call.arguments)
            })
        output_tokens = result.usage.output_tokens
    }
}

private let approximateBytesPerToken = 4

func anthropicMessagesToPrompt(_ request: [String: Any]) throws -> String {
    gateway_prompt(try parse_anthropic_request(request, default_model: "gemini"))
}

// 功能：把 Anthropic Messages 请求规范化为协议无关请求。
// 参数：request 为 JSON 对象；default_model 为缺省模型。
// 返回值：可交给 GatewayPipeline 的请求。
func parse_anthropic_request(
    _ request: [String: Any],
    default_model: String
) throws -> GatewayRequest {
    guard let raw_messages = request["messages"] as? [Any], !raw_messages.isEmpty else {
        throw GatewayProtocolError.invalid_request("messages must be a non-empty array")
    }
    var messages: [GatewayMessage] = []
    if let system = request["system"] {
        let content = try parse_anthropic_text_content(system, field: "system")
        if !content.isEmpty {
            messages.append(GatewayMessage(role: .system, content: content))
        }
    }
    messages.append(contentsOf: try parse_anthropic_messages(raw_messages))
    let tools = try parse_anthropic_tools(request["tools"])
    let tool_choice = try parse_anthropic_tool_choice(request["tool_choice"])
    try validate_anthropic_tool_choice(tool_choice, tools: tools)
    return GatewayRequest(
        model: request["model"] as? String ?? default_model,
        messages: messages,
        tools: tools,
        tool_choice: tool_choice,
        stream: request["stream"] as? Bool ?? false)
}

// 功能：把 Anthropic 消息按原顺序转换为统一消息。
// 参数：values 为消息数组。
// 返回值：规范化消息数组。
private func parse_anthropic_messages(_ values: [Any]) throws -> [GatewayMessage] {
    var messages: [GatewayMessage] = []
    var tool_names_by_id: [String: String] = [:]
    for value in values {
        guard let message = value as? [String: Any],
              let role_text = message["role"] as? String,
              role_text == "user" || role_text == "assistant" else {
            throw GatewayProtocolError.invalid_request(
                "message role must be user or assistant")
        }
        let role: GatewayRole = role_text == "assistant" ? .assistant : .user
        let content = try parse_anthropic_message_content(
            message["content"],
            role: role,
            tool_names_by_id: &tool_names_by_id)
        messages.append(GatewayMessage(role: role, content: content))
    }
    return messages
}

// 功能：转换 Anthropic 字符串或 content block 数组。
// 参数：value 为 content；role 为角色；tool_names_by_id 保存续轮工具名称。
// 返回值：统一内容数组。
private func parse_anthropic_message_content(
    _ value: Any?,
    role: GatewayRole,
    tool_names_by_id: inout [String: String]
) throws -> [GatewayContent] {
    if let text = value as? String { return [.text(text)] }
    guard let blocks = value as? [Any] else {
        throw GatewayProtocolError.invalid_request(
            "message content must be a string or content block array")
    }
    var content: [GatewayContent] = []
    for value in blocks {
        guard let block = value as? [String: Any],
              let type = block["type"] as? String else {
            throw GatewayProtocolError.invalid_request("invalid content block")
        }
        switch type {
        case "text":
            guard let text = block["text"] as? String else {
                throw GatewayProtocolError.invalid_request("text block requires text")
            }
            content.append(.text(text))
        case "tool_use":
            guard role == .assistant else {
                throw GatewayProtocolError.invalid_request(
                    "tool_use blocks must be in assistant messages")
            }
            let call = try parse_anthropic_tool_use(block)
            content.append(.tool_call(call))
            if let id = call.id { tool_names_by_id[id] = call.name }
        case "tool_result":
            guard role == .user else {
                throw GatewayProtocolError.invalid_request(
                    "tool_result blocks must be in user messages")
            }
            content.append(.tool_result(try parse_anthropic_tool_result(
                block,
                tool_names_by_id: tool_names_by_id)))
        case "thinking":
            content.append(.text(
                "[Assistant reasoning]\n\(block["thinking"] as? String ?? "")"))
        case "redacted_thinking":
            content.append(.text("[Assistant reasoning was redacted]"))
        case "image", "audio", "document":
            throw GatewayProtocolError.unsupported("media content is not supported")
        default:
            throw GatewayProtocolError.invalid_request(
                "unsupported content block type: \(type)")
        }
    }
    return content
}

// 功能：转换 Anthropic system 字符串或文本 block 数组。
// 参数：value 为 system；field 用于错误消息。
// 返回值：统一文本内容数组。
private func parse_anthropic_text_content(
    _ value: Any,
    field: String
) throws -> [GatewayContent] {
    if let text = value as? String { return [.text(text)] }
    guard let blocks = value as? [Any] else {
        throw GatewayProtocolError.invalid_request(
            "\(field) must be a string or text block array")
    }
    return try blocks.map { value in
        guard let block = value as? [String: Any],
              let type = block["type"] as? String else {
            throw GatewayProtocolError.invalid_request("invalid \(field) block")
        }
        if ["image", "audio", "document"].contains(type) {
            throw GatewayProtocolError.unsupported("media content is not supported")
        }
        guard type == "text", let text = block["text"] as? String else {
            throw GatewayProtocolError.invalid_request(
                "\(field) blocks must be text blocks")
        }
        return .text(text)
    }
}

// 功能：解析 Anthropic assistant 工具调用。
// 参数：block 为 tool_use block。
// 返回值：统一工具调用。
private func parse_anthropic_tool_use(
    _ block: [String: Any]
) throws -> GatewayToolCall {
    guard let id = block["id"] as? String, !id.isEmpty,
          let name = block["name"] as? String, !name.isEmpty,
          let input = block["input"] as? [String: Any] else {
        throw GatewayProtocolError.invalid_request(
            "tool_use requires id, name, and input object")
    }
    return GatewayToolCall(id: id, name: name, arguments: input)
}

// 功能：解析 Anthropic user 工具结果并恢复实际工具名称。
// 参数：block 为 tool_result；tool_names_by_id 为先前调用名称表。
// 返回值：统一工具结果。
private func parse_anthropic_tool_result(
    _ block: [String: Any],
    tool_names_by_id: [String: String]
) throws -> GatewayToolResult {
    guard let id = block["tool_use_id"] as? String, !id.isEmpty else {
        throw GatewayProtocolError.invalid_request("tool_result requires tool_use_id")
    }
    let output = try parse_anthropic_tool_result_content(block["content"])
    return GatewayToolResult(
        call_id: id,
        name: tool_names_by_id[id],
        output: output,
        is_error: block["is_error"] as? Bool)
}

// 功能：转换 Anthropic 工具结果文本，并拒绝媒体 block。
// 参数：value 为 tool_result content。
// 返回值：按换行连接的结果文本。
private func parse_anthropic_tool_result_content(_ value: Any?) throws -> String {
    if value == nil { return "" }
    if let text = value as? String { return text }
    guard let blocks = value as? [Any] else {
        throw GatewayProtocolError.invalid_request(
            "tool_result content must be a string or text block array")
    }
    return try blocks.map { value in
        guard let block = value as? [String: Any],
              let type = block["type"] as? String else {
            throw GatewayProtocolError.invalid_request("invalid tool_result block")
        }
        if ["image", "audio", "document"].contains(type) {
            throw GatewayProtocolError.unsupported("media content is not supported")
        }
        guard type == "text", let text = block["text"] as? String else {
            throw GatewayProtocolError.invalid_request(
                "tool_result currently supports text blocks only")
        }
        return text
    }.joined(separator: "\n")
}

// 功能：把 Anthropic 工具声明转换为统一工具。
// 参数：value 为 tools 字段。
// 返回值：规范化工具数组。
private func parse_anthropic_tools(_ value: Any?) throws -> [GatewayTool] {
    if value == nil { return [] }
    guard let values = value as? [Any] else {
        throw GatewayProtocolError.invalid_request("tools must be an array")
    }
    return try values.map { value in
        guard let tool = value as? [String: Any],
              let name = tool["name"] as? String,
              !name.isEmpty,
              let input_schema = tool["input_schema"] as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "each tool must contain a non-empty name and an input_schema object")
        }
        return GatewayTool(
            name: name,
            description: tool["description"] as? String ?? "",
            parameters: input_schema)
    }
}

// 功能：把 Anthropic tool_choice 转换为统一策略。
// 参数：value 为 tool_choice 字段。
// 返回值：统一工具选择。
private func parse_anthropic_tool_choice(_ value: Any?) throws -> GatewayToolChoice {
    if value == nil { return .auto }
    guard let choice = value as? [String: Any],
          let type = choice["type"] as? String else {
        throw GatewayProtocolError.invalid_request("invalid tool_choice")
    }
    switch type {
    case "auto": return .auto
    case "none": return .none
    case "any": return .required
    case "tool":
        guard let name = choice["name"] as? String, !name.isEmpty else {
            throw GatewayProtocolError.invalid_request(
                "named tool_choice requires a non-empty name")
        }
        return .named(name)
    default:
        throw GatewayProtocolError.invalid_request("invalid tool_choice")
    }
}

// 功能：保留 Anthropic prompt 构建阶段的工具选择校验。
// 参数：choice 为工具策略；tools 为声明工具。
// 返回值：无；策略不可能满足时抛出 invalid_request。
private func validate_anthropic_tool_choice(
    _ choice: GatewayToolChoice,
    tools: [GatewayTool]
) throws {
    let names = Set(tools.map(\.name))
    switch choice {
    case .required where names.isEmpty:
        throw GatewayProtocolError.invalid_request(
            "tool_choice requires at least one declared tool")
    case .named(let name) where !names.contains(name):
        throw GatewayProtocolError.invalid_request(
            "tool_choice names an undeclared tool: \(name)")
    default:
        return
    }
}

func makeAnthropicMessage(_ input: AnthropicMessageBuildInput) -> [String: Any] {
    let blocks = anthropicResponseBlocks(input.output)
    let stopReason = input.output.calls.isEmpty ? "end_turn" : "tool_use"
    return [
        "id": "msg_" + randomHex(24),
        "type": "message",
        "role": "assistant",
        "model": input.model,
        "content": blocks,
        "stop_reason": stopReason,
        "stop_sequence": NSNull(),
        "usage": [
            "input_tokens": approximateTokenCount(input.prompt),
            "output_tokens": input.output_tokens,
        ],
    ]
}

private func anthropicResponseBlocks(_ output: ParsedToolOutput) -> [[String: Any]] {
    var blocks: [[String: Any]] = []
    if !output.text.isEmpty { blocks.append(["type": "text", "text": output.text]) }
    blocks.append(contentsOf: output.calls.map { call in
        [
            "type": "tool_use",
            "id": "toolu_" + randomHex(24),
            "name": call.name,
            "input": call.arguments,
        ]
    })
    if blocks.isEmpty { blocks.append(["type": "text", "text": ""]) }
    return blocks
}

func approximateTokenCount(_ text: String) -> Int {
    max(1, text.utf8.count / approximateBytesPerToken)
}

func anthropicSSE(_ message: [String: Any]) -> String {
    var events: [String] = [anthropicMessageStartEvent(message)]
    let blocks = message["content"] as? [[String: Any]] ?? []
    for (index, block) in blocks.enumerated() {
        events.append(contentsOf: anthropicBlockEvents(index: index, block: block))
    }
    let usage = message["usage"] as? [String: Any] ?? [:]
    let delta: [String: Any] = [
        "type": "message_delta",
        "delta": ["stop_reason": message["stop_reason"] ?? "end_turn", "stop_sequence": NSNull()],
        "usage": ["output_tokens": usage["output_tokens"] ?? 0],
    ]
    events.append(anthropicEvent("message_delta", payload: delta))
    events.append(anthropicEvent("message_stop", payload: ["type": "message_stop"]))
    return events.joined()
}

// 功能：编码纯文本流在生成前必须发送的 message 与 content block 起始事件。
// 参数：message_id 为稳定消息 ID；model 为模型；input_tokens 为输入用量。
// 返回值：按协议顺序拼接的两条 SSE 事件。
func anthropic_text_stream_start(
    message_id: String,
    model: String,
    input_tokens: Int
) -> String {
    let message: [String: Any] = [
        "id": message_id,
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [],
        "stop_reason": NSNull(),
        "stop_sequence": NSNull(),
        "usage": ["input_tokens": input_tokens, "output_tokens": 0],
    ]
    let block: [String: Any] = [
        "type": "content_block_start",
        "index": 0,
        "content_block": ["type": "text", "text": ""],
    ]
    return anthropicEvent(
        "message_start",
        payload: ["type": "message_start", "message": message])
        + anthropicEvent("content_block_start", payload: block)
}

// 功能：把一个上游文本增量编码为 Anthropic content_block_delta。
// 参数：text 为本次增量。
// 返回值：单条 SSE 事件。
func anthropic_text_stream_delta(_ text: String) -> String {
    anthropicEvent("content_block_delta", payload: [
        "type": "content_block_delta",
        "index": 0,
        "delta": ["type": "text_delta", "text": text],
    ])
}

// 功能：编码成功文本流的 block、message 结束事件及最终输出用量。
// 参数：output_tokens 为完整输出的近似 token 数。
// 返回值：按协议顺序拼接的三条 SSE 事件。
func anthropic_text_stream_finish(output_tokens: Int) -> String {
    let block_stop = anthropicEvent("content_block_stop", payload: [
        "type": "content_block_stop",
        "index": 0,
    ])
    let message_delta = anthropicEvent("message_delta", payload: [
        "type": "message_delta",
        "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
        "usage": ["output_tokens": output_tokens],
    ])
    let message_stop = anthropicEvent(
        "message_stop",
        payload: ["type": "message_stop"])
    return block_stop + message_delta + message_stop
}

// 功能：在 SSE header 已写出后编码脱敏的 Anthropic api_error 事件。
// 参数：message 为已经脱敏的客户端消息。
// 返回值：单条 error SSE 事件。
func anthropic_stream_error_event(message: String) -> String {
    anthropicEvent("error", payload: [
        "type": "error",
        "error": ["type": "api_error", "message": message],
    ])
}

private func anthropicMessageStartEvent(_ message: [String: Any]) -> String {
    let startMessage: [String: Any] = [
        "id": message["id"] ?? "msg_" + randomHex(24),
        "type": "message",
        "role": "assistant",
        "model": message["model"] ?? "gemini",
        "content": [],
        "stop_reason": NSNull(),
        "stop_sequence": NSNull(),
        "usage": message["usage"] ?? ["input_tokens": 0, "output_tokens": 0],
    ]
    return anthropicEvent(
        "message_start",
        payload: ["type": "message_start", "message": startMessage])
}

private func anthropicBlockEvents(index: Int, block: [String: Any]) -> [String] {
    let type = block["type"] as? String ?? "text"
    let startBlock: [String: Any]
    let delta: [String: Any]
    if type == "tool_use" {
        startBlock = [
            "type": "tool_use", "id": block["id"] ?? "toolu_" + randomHex(24),
            "name": block["name"] ?? "", "input": [:],
        ]
        delta = ["type": "input_json_delta", "partial_json": jsonString(block["input"] ?? [:])]
    } else {
        startBlock = ["type": "text", "text": ""]
        delta = ["type": "text_delta", "text": block["text"] ?? ""]
    }
    return [
        anthropicEvent("content_block_start", payload: [
            "type": "content_block_start", "index": index, "content_block": startBlock]),
        anthropicEvent("content_block_delta", payload: [
            "type": "content_block_delta", "index": index, "delta": delta]),
        anthropicEvent("content_block_stop", payload: [
            "type": "content_block_stop", "index": index]),
    ]
}

private func anthropicEvent(_ type: String, payload: [String: Any]) -> String {
    "event: \(type)\ndata: \(jsonString(payload))\n\n"
}
