import Foundation
import Network
import CoreFoundation

// 用途：适配 Gemini GenerateContent 路径、请求、响应、SSE 和错误 envelope。
// 使用方法：HTTPServer 严格解析动态模型路径，再交给共享管线执行。

struct GeminiRoute {
    let model: String
    let stream: Bool
}

// 功能：严格解析 Gemini 动态模型 request target，忽略 query 的路由影响。
// 参数：path 为包含可选 query 的 HTTP request target。
// 返回值：模型名和是否为流式 action；不匹配时抛出 invalid_request。
func parse_gemini_route(_ path: String) throws -> GeminiRoute {
    let encoded_path = path.split(
        separator: "?",
        maxSplits: 1,
        omittingEmptySubsequences: false
    ).first.map(String.init) ?? path
    let path_only = try decode_gemini_path(encoded_path)
    let prefix = "/v1beta/models/"
    guard path_only.hasPrefix(prefix) else {
        throw GatewayProtocolError.invalid_request("invalid Gemini path")
    }

    let remainder = String(path_only.dropFirst(prefix.count))
    let actions: [(suffix: String, stream: Bool)] = [
        (":generateContent", false),
        (":streamGenerateContent", true),
    ]
    for action in actions where remainder.hasSuffix(action.suffix) {
        let model = String(remainder.dropLast(action.suffix.count))
        guard valid_gemini_model_segment(model) else {
            throw GatewayProtocolError.invalid_request("Gemini model must not be empty")
        }
        return GeminiRoute(model: model, stream: action.stream)
    }
    throw GatewayProtocolError.invalid_request("invalid Gemini action")
}

// 功能：严格百分号解码路径恰好一次，并拒绝畸形或双编码输入。
// 参数：encoded_path 为已与 query 分离的 raw path。
// 返回值：一次解码后的路径。
private func decode_gemini_path(_ encoded_path: String) throws -> String {
    guard let decoded_path = encoded_path.removingPercentEncoding,
          !decoded_path.contains("%") else {
        throw GatewayProtocolError.invalid_request(
            "invalid Gemini path percent encoding")
    }
    return decoded_path
}

// 功能：把 Gemini GenerateContent 请求规范化为协议无关请求。
// 参数：request 为 JSON 对象；model 来自路径；stream 来自路径 action。
// 返回值：可交给 GatewayPipeline 的请求。
func parse_gemini_request(
    _ request: [String: Any],
    model: String,
    stream: Bool
) throws -> GatewayRequest {
    guard valid_gemini_model_segment(model) else {
        throw GatewayProtocolError.invalid_request("Gemini model must not be empty")
    }
    try validate_gemini_fields(
        request,
        supported: [
            "contents",
            "generationConfig",
            "systemInstruction",
            "toolConfig",
            "tools",
        ],
        unsupported: [
            "cachedContent",
            "model",
            "safetySettings",
            "serviceTier",
            "store",
        ],
        context: "request")
    try validate_gemini_generation_config(request["generationConfig"])

    var messages: [GatewayMessage] = []
    if let system_instruction = request["systemInstruction"] {
        messages.append(try parse_gemini_system_instruction(system_instruction))
    }

    guard let contents = request["contents"] as? [Any], !contents.isEmpty else {
        throw GatewayProtocolError.invalid_request("contents must be a non-empty array")
    }
    messages.append(contentsOf: try contents.map(parse_gemini_content))
    try validate_gemini_function_responses(messages)

    let declared_tools = try parse_gemini_tools(request["tools"])
    let tool_selection = try parse_gemini_tool_choice(
        request["toolConfig"],
        declared_tools: declared_tools)
    return GatewayRequest(
        model: model,
        messages: messages,
        tools: tool_selection.tools,
        tool_choice: tool_selection.choice,
        stream: stream)
}

// 功能：把统一生成结果编码为 Gemini GenerateContentResponse。
// 参数：result 为统一结果；response_id 为当前响应 ID。
// 返回值：可序列化的 Gemini response object。
func make_gemini_response(
    _ result: GatewayResult,
    response_id: String
) -> [String: Any] {
    var parts: [[String: Any]] = []
    if !result.text.isEmpty {
        parts.append(["text": result.text])
    }
    parts.append(contentsOf: result.tool_calls.map(gemini_function_call_part))
    if parts.isEmpty {
        parts.append(["text": ""])
    }

    return [
        "candidates": [[
            "content": [
                "role": "model",
                "parts": parts,
            ],
            "finishReason": "STOP",
            "index": 0,
        ]],
        "usageMetadata": [
            "promptTokenCount": result.usage.input_tokens,
            "candidatesTokenCount": result.usage.output_tokens,
            "totalTokenCount": result.usage.total_tokens,
        ],
        "modelVersion": result.model,
        "responseId": response_id,
    ]
}

// 功能：把 Gemini response object 编码为单条 SSE data 记录。
// 参数：response 为可序列化的 GenerateContentResponse。
// 返回值：以两个换行结尾且不含 DONE 标记的 SSE 记录。
func gemini_sse_chunk(_ response: [String: Any]) -> String {
    "data: \(jsonString(response))\n\n"
}

// 功能：把统一协议错误编码为 Gemini error object。
// 参数：error 为统一协议错误。
// 返回值：包含 HTTP code、Google RPC status 和安全消息的 envelope。
func gemini_error(_ error: GatewayProtocolError) -> [String: Any] {
    gemini_error(
        status: error.http_status,
        message: gateway_client_error_message(error))
}

// 功能：把 HTTP 状态和安全消息编码为 Gemini error object。
// 参数：status 为 HTTP 状态；message 为不含凭据和原始 payload 的消息。
// 返回值：Gemini 错误 envelope。
func gemini_error(status: Int, message: String) -> [String: Any] {
    [
        "error": [
            "code": status,
            "message": message,
            "status": gemini_error_status(status),
        ],
    ]
}

extension HTTPServer {
    // 功能：解析并执行 Gemini GenerateContent 请求，返回 JSON 或 SSE。
    // 参数：conn 为客户端连接；body 为 JSON 请求体；
    // route 为已解析动态路径。
    // 返回值：无。
    func handle_gemini(
        _ conn: NWConnection,
        body: Data,
        route: GeminiRoute
    ) {
        guard let request = (try? JSONSerialization.jsonObject(with: body))
                as? [String: Any] else {
            sendJSON(
                conn,
                gemini_error(status: 400, message: "invalid JSON"),
                status: 400)
            return
        }

        do {
            let pipeline = GatewayPipeline(
                generator: generator,
                default_model: cfg.defaultModel)
            let gateway_request = try parse_gemini_request(
                request,
                model: route.model,
                stream: route.stream)
            let context = try pipeline.prepare(gateway_request)
            let response_id = "response_" + randomHex(24)
            if route.stream && !context.tool_policy.active {
                stream_gemini_text(
                    conn,
                    pipeline: pipeline,
                    context: context,
                    response_id: response_id)
                return
            }
            let result = try pipeline.generate(context)
            if route.stream {
                let response = result.tool_calls.isEmpty
                    ? make_gemini_response(result, response_id: response_id)
                    : make_gemini_tool_stream_response(
                        result,
                        response_id: response_id)
                startSSE(conn)
                sseFinish(conn, gemini_sse_chunk(response))
                return
            }
            sendJSON(
                conn,
                make_gemini_response(result, response_id: response_id))
        } catch let error as GatewayProtocolError {
            sendJSON(
                conn,
                gemini_error(error),
                status: error.http_status)
        } catch {
            sendJSON(
                conn,
                gemini_error(status: 502, message: "upstream error"),
                status: 502)
        }
    }

    // 功能：逐 delta 输出 Gemini 文本流，并在最后一个 chunk 附加 usage。
    // 参数：conn 为连接；pipeline 为共享管线；context 为执行上下文；
    // response_id 为响应 ID。
    // 返回值：无。
    private func stream_gemini_text(
        _ conn: NWConnection,
        pipeline: GatewayPipeline,
        context: GatewayExecutionContext,
        response_id: String
    ) {
        let gone = ClientGone()
        conn.stateUpdateHandler = { state in
            if case .failed = state { gone.mark() }
            if case .cancelled = state { gone.mark() }
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            _, _, is_complete, error in
            if is_complete || error != nil { gone.mark() }
        }

        var pending_delta: String?
        var full_text = ""
        startSSE(conn)
        do {
            try pipeline.stream_text(
                context,
                is_cancelled: { gone.is_set() }
            ) { delta in
                guard !gone.is_set() else { return }
                if let previous_delta = pending_delta {
                    let response = gemini_stream_text_response(
                        text: previous_delta,
                        model: context.model.name,
                        response_id: response_id)
                    self.sseSend(
                        conn,
                        gemini_sse_chunk(response),
                        gone: gone)
                }
                pending_delta = delta
                full_text += delta
            }
            guard !gone.is_set() else { return }
            let usage = GatewayUsage(
                input_tokens: approximateTokenCount(context.generation.prompt),
                output_tokens: approximateTokenCount(full_text))
            let response = gemini_stream_text_response(
                text: pending_delta ?? "",
                model: context.model.name,
                response_id: response_id,
                finish_reason: "STOP",
                usage: usage)
            sseFinish(conn, gemini_sse_chunk(response))
        } catch let error as GatewayProtocolError {
            guard !gone.is_set() else { return }
            finish_gemini_stream_error(
                conn,
                pending_delta: pending_delta,
                context: context,
                response_id: response_id,
                error: gemini_error(error),
                gone: gone)
        } catch {
            guard !gone.is_set() else { return }
            finish_gemini_stream_error(
                conn,
                pending_delta: pending_delta,
                context: context,
                response_id: response_id,
                error: gemini_error(status: 502, message: "upstream error"),
                gone: gone)
        }
    }

    // 功能：在 Gemini 流错误前写出尚未发送的 delta，再写错误并关闭。
    // 参数：conn 为连接；pending_delta 为缓存增量；context 和 response_id
    // 标识响应；error 为错误 envelope；gone 跟踪客户端断开。
    // 返回值：无。
    private func finish_gemini_stream_error(
        _ conn: NWConnection,
        pending_delta: String?,
        context: GatewayExecutionContext,
        response_id: String,
        error: [String: Any],
        gone: ClientGone
    ) {
        if let pending_delta = pending_delta {
            let response = gemini_stream_text_response(
                text: pending_delta,
                model: context.model.name,
                response_id: response_id)
            sseSend(conn, gemini_sse_chunk(response), gone: gone)
        }
        guard !gone.is_set() else { return }
        sseFinish(conn, gemini_sse_chunk(error))
    }
}

// 功能：构造仅含完整 functionCall parts 的 Gemini 工具流 response。
// 参数：result 为至少含一个工具调用的统一结果；response_id 为响应 ID。
// 返回值：丢弃模型前置文本的 GenerateContentResponse。
private func make_gemini_tool_stream_response(
    _ result: GatewayResult,
    response_id: String
) -> [String: Any] {
    let tool_result = GatewayResult(
        model: result.model,
        text: "",
        tool_calls: result.tool_calls,
        finish_reason: .tool_calls,
        usage: result.usage)
    return make_gemini_response(tool_result, response_id: response_id)
}

// 功能：构造只包含当前 delta 的 Gemini 文本 stream response。
// 参数：text 为当前 delta；model 和 response_id 标识响应；finish_reason 与 usage
// 仅用于最后一个 chunk。
// 返回值：可序列化的 GenerateContentResponse。
private func gemini_stream_text_response(
    text: String,
    model: String,
    response_id: String,
    finish_reason: String? = nil,
    usage: GatewayUsage? = nil
) -> [String: Any] {
    var candidate: [String: Any] = [
        "content": [
            "role": "model",
            "parts": [["text": text]],
        ],
        "index": 0,
    ]
    if let finish_reason = finish_reason {
        candidate["finishReason"] = finish_reason
    }
    var response: [String: Any] = [
        "candidates": [candidate],
        "modelVersion": model,
        "responseId": response_id,
    ]
    if let usage = usage {
        response["usageMetadata"] = [
            "promptTokenCount": usage.input_tokens,
            "candidatesTokenCount": usage.output_tokens,
            "totalTokenCount": usage.total_tokens,
        ]
    }
    return response
}

// 功能：把 HTTP status 映射为 Gemini/Google RPC status。
// 参数：status 为 HTTP 状态码。
// 返回值：对应的大写状态名称。
private func gemini_error_status(_ status: Int) -> String {
    switch status {
    case 400: return "INVALID_ARGUMENT"
    case 401: return "UNAUTHENTICATED"
    case 404: return "NOT_FOUND"
    case 502: return "UNAVAILABLE"
    default: return "UNKNOWN"
    }
}

// 功能：判断模型名是单个非空路径 segment，并拒绝编码或空白歧义。
// 参数：model 为路径中提取的模型名。
// 返回值：合法时为 true。
private func valid_gemini_model_segment(_ model: String) -> Bool {
    guard !model.isEmpty else { return false }
    let allowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._@="))
    return model.unicodeScalars.allSatisfy(allowed.contains)
}

// 功能：解析仅允许文本 part 的 systemInstruction。
// 参数：value 为 systemInstruction 字段。
// 返回值：system 角色统一消息。
private func parse_gemini_system_instruction(_ value: Any) throws -> GatewayMessage {
    guard let instruction = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid systemInstruction")
    }
    try validate_gemini_fields(
        instruction,
        supported: ["parts", "role"],
        context: "systemInstruction")
    if let raw_role = instruction["role"] {
        guard let role = raw_role as? String,
              role == "user" || role == "model" else {
            throw GatewayProtocolError.invalid_request(
                "systemInstruction role must be user or model")
        }
    }
    guard let parts = instruction["parts"] as? [Any],
          !parts.isEmpty else {
        throw GatewayProtocolError.invalid_request("invalid systemInstruction")
    }
    let content = try parts.map { value -> GatewayContent in
        guard let part = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "systemInstruction supports text parts only")
        }
        try validate_gemini_part_fields(part)
        guard
              part.count == 1,
              let text = part["text"] as? String else {
            throw GatewayProtocolError.invalid_request(
                "systemInstruction supports text parts only")
        }
        return .text(text)
    }
    return GatewayMessage(role: .system, content: content)
}

// 功能：解析一条 Gemini user 或 model Content。
// 参数：value 为 contents 数组元素。
// 返回值：保留原 part 顺序的统一消息。
private func parse_gemini_content(_ value: Any) throws -> GatewayMessage {
    guard let item = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid Gemini content")
    }
    try validate_gemini_fields(
        item,
        supported: ["parts", "role"],
        context: "content")
    guard let parts = item["parts"] as? [Any],
          !parts.isEmpty else {
        throw GatewayProtocolError.invalid_request("invalid Gemini content")
    }
    let role_text: String
    if let raw_role = item["role"] {
        guard let text = raw_role as? String else {
            throw GatewayProtocolError.invalid_request(
                "Gemini role must be user or model")
        }
        role_text = text
    } else {
        role_text = "user"
    }
    let role: GatewayRole
    switch role_text {
    case "user": role = .user
    case "model": role = .assistant
    default:
        throw GatewayProtocolError.invalid_request("Gemini role must be user or model")
    }
    let content = try parts.map { try parse_gemini_part($0, role: role) }
    return GatewayMessage(role: role, content: content)
}

// 功能：解析 Gemini 文本、functionCall 或 functionResponse part。
// 参数：value 为 part；role 为所属统一角色。
// 返回值：统一内容。
private func parse_gemini_part(
    _ value: Any,
    role: GatewayRole
) throws -> GatewayContent {
    guard let part = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid Gemini part")
    }
    try validate_gemini_part_fields(part)
    guard part.count == 1 else {
        throw GatewayProtocolError.invalid_request("invalid Gemini part")
    }
    if let text = part["text"] as? String {
        return .text(text)
    }
    if let function_call = part["functionCall"] {
        guard role == .assistant else {
            throw GatewayProtocolError.invalid_request(
                "functionCall must be in model content")
        }
        return .tool_call(try parse_gemini_function_call(function_call))
    }
    if let function_response = part["functionResponse"] {
        guard role == .user else {
            throw GatewayProtocolError.invalid_request(
                "functionResponse must be in user content")
        }
        return .tool_result(try parse_gemini_function_response(function_response))
    }
    throw GatewayProtocolError.invalid_request("unsupported Gemini part")
}

// 功能：区分 Gemini Part 支持字段、已知不支持字段和未知字段。
// 参数：part 为待检查的 Part object。
// 返回值：无。
private func validate_gemini_part_fields(_ part: [String: Any]) throws {
    try validate_gemini_fields(
        part,
        supported: ["functionCall", "functionResponse", "text"],
        unsupported: [
            "audioTranscription",
            "codeExecutionResult",
            "executableCode",
            "fileData",
            "inlineData",
            "mediaProcessing",
            "mediaResolution",
            "partMetadata",
            "thought",
            "thoughtSignature",
            "toolCall",
            "toolResponse",
            "videoMetadata",
        ],
        context: "part")
}

// 功能：把 Gemini functionCall 转为统一工具调用。
// 参数：value 为 functionCall object。
// 返回值：保留可选 ID、名称和参数的工具调用。
private func parse_gemini_function_call(_ value: Any) throws -> GatewayToolCall {
    guard let function = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid functionCall")
    }
    try validate_gemini_fields(
        function,
        supported: ["args", "id", "name"],
        context: "functionCall")
    guard let name = function["name"] as? String,
          valid_gemini_call_name(name) else {
        throw GatewayProtocolError.invalid_request("invalid functionCall")
    }
    let arguments: [String: Any]
    if let raw_arguments = function["args"] {
        guard let object = raw_arguments as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "functionCall args must be an object")
        }
        arguments = object
    } else {
        arguments = [:]
    }
    let call_id = try gemini_optional_non_empty_string(function["id"], key: "id")
    return GatewayToolCall(id: call_id, name: name, arguments: arguments)
}

// 功能：把 Gemini functionResponse 转为统一工具结果。
// 参数：value 为 functionResponse object。
// 返回值：保留可选 ID、名称和响应对象的工具结果。
private func parse_gemini_function_response(_ value: Any) throws -> GatewayToolResult {
    guard let function = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid functionResponse")
    }
    try validate_gemini_fields(
        function,
        supported: ["id", "name", "response"],
        unsupported: ["parts", "willContinue", "scheduling"],
        context: "functionResponse")
    guard let name = function["name"] as? String,
          valid_gemini_call_name(name),
          let response = function["response"] as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid functionResponse")
    }
    let call_id = try gemini_optional_non_empty_string(function["id"], key: "id")
    return GatewayToolResult(
        call_id: call_id,
        name: name,
        output: response)
}

// 功能：校验每个 functionResponse 匹配前序尚未响应的 functionCall。
// 参数：messages 为包含 system 和 contents 的统一消息序列。
// 返回值：无。
private func validate_gemini_function_responses(
    _ messages: [GatewayMessage]
) throws {
    var pending_calls: [GatewayToolCall] = []
    for message in messages {
        for content in message.content {
            switch content {
            case .tool_call(let call):
                pending_calls.append(call)
            case .tool_result(let result):
                guard let name = result.name,
                      let index = pending_calls.firstIndex(where: { call in
                          call.name == name && call.id == result.call_id
                      }) else {
                    throw GatewayProtocolError.invalid_request(
                        "functionResponse does not match a prior functionCall")
                }
                pending_calls.remove(at: index)
            case .text:
                continue
            }
        }
    }
}

// 功能：解析 Gemini functionDeclarations 并拒绝托管工具。
// 参数：value 为 tools 字段。
// 返回值：按声明顺序排列的统一工具。
private func parse_gemini_tools(_ value: Any?) throws -> [GatewayTool] {
    if value == nil || value is NSNull { return [] }
    guard let entries = value as? [Any] else {
        throw GatewayProtocolError.invalid_request("tools must be an array")
    }
    var tools: [GatewayTool] = []
    for value in entries {
        guard let entry = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request("invalid Gemini tool")
        }
        try validate_gemini_fields(
            entry,
            supported: ["functionDeclarations"],
            unsupported: GEMINI_MANAGED_TOOL_FIELDS,
            context: "tool")
        guard let declarations = entry["functionDeclarations"] as? [Any],
              !declarations.isEmpty else {
            throw GatewayProtocolError.invalid_request(
                "tool must contain functionDeclarations only")
        }
        tools.append(contentsOf: try declarations.map(parse_gemini_tool_declaration))
    }
    return tools
}

// 功能：解析单个 Gemini function declaration。
// 参数：value 为 functionDeclarations 数组元素。
// 返回值：统一工具声明。
private func parse_gemini_tool_declaration(_ value: Any) throws -> GatewayTool {
    guard let function = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid function declaration")
    }
    try validate_gemini_fields(
        function,
        supported: [
            "name",
            "description",
            "parameters",
            "parametersJsonSchema",
        ],
        unsupported: ["response", "responseJsonSchema", "behavior"],
        context: "function declaration")
    guard let name = function["name"] as? String,
          valid_gemini_declaration_name(name) else {
        throw GatewayProtocolError.invalid_request("invalid function name")
    }
    guard let description = function["description"] as? String,
          !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GatewayProtocolError.invalid_request(
            "function description must be a non-empty string")
    }
    if function["parameters"] != nil,
       function["parametersJsonSchema"] != nil {
        throw GatewayProtocolError.invalid_request(
            "function parameter schemas are mutually exclusive")
    }
    let parameters: [String: Any]
    if let raw_parameters = function["parameters"] {
        guard let object = raw_parameters as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "function parameters must be an object")
        }
        try validate_google_parameter_schema(object, require_object: true)
        parameters = object
    } else if let raw_schema = function["parametersJsonSchema"] {
        guard let object = raw_schema as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "function parametersJsonSchema must be an object")
        }
        try validate_json_parameter_schema(object, require_object: true)
        parameters = object
    } else {
        parameters = [:]
    }
    return GatewayTool(
        name: name,
        description: description,
        parameters: parameters)
}

// 功能：校验 Gemini 函数声明名称的宽字符集与长度限制。
// 参数：name 为函数声明名称。
// 返回值：合法时为 true。
private func valid_gemini_declaration_name(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 128 else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:.-")
    return name.unicodeScalars.allSatisfy(allowed.contains)
}

// 功能：校验 Gemini 函数调用和响应名称的窄字符集与长度限制。
// 参数：name 为函数调用或响应名称。
// 返回值：合法时为 true。
private func valid_gemini_call_name(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 128 else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    return name.unicodeScalars.allSatisfy(allowed.contains)
}

// 功能：按 Google Schema 校验字段类型并递归检查 properties 和 items。
// 参数：schema 为待检查对象；require_object 指示根节点必须为 OBJECT。
// 返回值：无。
private func validate_google_parameter_schema(
    _ schema: [String: Any],
    require_object: Bool
) throws {
    let known_fields: Set<String> = [
        "anyOf",
        "default",
        "description",
        "enum",
        "example",
        "format",
        "items",
        "maximum",
        "maxItems",
        "maxLength",
        "maxProperties",
        "minimum",
        "minItems",
        "minLength",
        "minProperties",
        "nullable",
        "pattern",
        "properties",
        "propertyOrdering",
        "required",
        "title",
        "type",
    ]
    try validate_gemini_fields(
        schema,
        supported: known_fields,
        context: "parameter schema")
    guard let raw_type = schema["type"] as? String else {
        throw GatewayProtocolError.invalid_request(
            "parameter schema requires type")
    }
    let type = raw_type.uppercased()
    let valid_types: Set<String> = [
        "ARRAY",
        "BOOLEAN",
        "INTEGER",
        "NULL",
        "NUMBER",
        "OBJECT",
        "STRING",
    ]
    guard valid_types.contains(type),
          !require_object || type == "OBJECT" else {
        throw GatewayProtocolError.invalid_request(
            "invalid parameter schema type")
    }
    try validate_google_schema_scalar_fields(schema)
    try validate_google_schema_array_fields(schema)

    if let raw_properties = schema["properties"] {
        guard type == "OBJECT",
              let properties = raw_properties as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "parameter schema properties must be an object")
        }
        for value in properties.values {
            guard let child = value as? [String: Any] else {
                throw GatewayProtocolError.invalid_request(
                    "parameter schema property must be an object")
            }
            try validate_google_parameter_schema(child, require_object: false)
        }
    }
    if let raw_items = schema["items"] {
        guard type == "ARRAY",
              let items = raw_items as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "parameter schema items must be an object")
        }
        try validate_google_parameter_schema(items, require_object: false)
    }
    if let raw_any_of = schema["anyOf"] {
        guard let values = raw_any_of as? [Any] else {
            throw GatewayProtocolError.invalid_request(
                "parameter schema anyOf must be an array")
        }
        for value in values {
            guard let child = value as? [String: Any] else {
                throw GatewayProtocolError.invalid_request(
                    "parameter schema anyOf item must be an object")
            }
            try validate_google_parameter_schema(child, require_object: false)
        }
    }
}

// 功能：校验 Google Schema 的字符串、布尔和数值字段。
// 参数：schema 为待检查对象。
// 返回值：无。
private func validate_google_schema_scalar_fields(
    _ schema: [String: Any]
) throws {
    for key in ["description", "format", "pattern", "title"] {
        if let value = schema[key], !(value is String) {
            throw GatewayProtocolError.invalid_request(
                "parameter schema field \(key) must be a string")
        }
    }
    if let value = schema["nullable"], gemini_json_boolean(value) == nil {
        throw GatewayProtocolError.invalid_request(
            "parameter schema nullable must be a boolean")
    }
    for key in ["minimum", "maximum"] {
        if let value = schema[key], gemini_json_number(value) == nil {
            throw GatewayProtocolError.invalid_request(
                "parameter schema field \(key) must be a number")
        }
    }
    let integer_string_fields = [
        "maxItems",
        "maxLength",
        "maxProperties",
        "minItems",
        "minLength",
        "minProperties",
    ]
    for key in integer_string_fields {
        if let value = schema[key], !valid_nonnegative_integer_string(value) {
            throw GatewayProtocolError.invalid_request(
                "parameter schema field \(key) must be an integer string")
        }
    }
}

// 功能：校验 Google Schema 的字符串数组字段。
// 参数：schema 为待检查对象。
// 返回值：无。
private func validate_google_schema_array_fields(
    _ schema: [String: Any]
) throws {
    for key in ["enum", "propertyOrdering", "required"] {
        if let value = schema[key], gemini_string_array(
            value,
            maximum_count: Int.max
        ) == nil {
            throw GatewayProtocolError.invalid_request(
                "parameter schema field \(key) must be a string array")
        }
    }
}

// 功能：判断值是非负十进制 int64 字符串。
// 参数：value 为 JSON 值。
// 返回值：合法时为 true。
private func valid_nonnegative_integer_string(_ value: Any) -> Bool {
    guard let text = value as? String,
          let number = Int64(text) else { return false }
    return number >= 0 && String(number) == text
}

private let GEMINI_JSON_SCHEMA_TYPES: Set<String> = [
    "array",
    "boolean",
    "integer",
    "null",
    "number",
    "object",
    "string",
]

private let GEMINI_JSON_SCHEMA_SUPPORTED_FIELDS: Set<String> = [
    "$defs",
    "$ref",
    "additionalProperties",
    "anyOf",
    "description",
    "enum",
    "format",
    "items",
    "maximum",
    "maxItems",
    "minimum",
    "minItems",
    "oneOf",
    "prefixItems",
    "properties",
    "required",
    "title",
    "type",
]

private let GEMINI_JSON_SCHEMA_UNSUPPORTED_FIELDS: Set<String> = [
    "$anchor",
    "$comment",
    "$dynamicAnchor",
    "$dynamicRef",
    "$id",
    "$schema",
    "allOf",
    "const",
    "contains",
    "contentEncoding",
    "contentMediaType",
    "default",
    "dependentRequired",
    "dependentSchemas",
    "deprecated",
    "else",
    "examples",
    "exclusiveMaximum",
    "exclusiveMinimum",
    "if",
    "maxContains",
    "maxLength",
    "maxProperties",
    "minContains",
    "minLength",
    "minProperties",
    "multipleOf",
    "not",
    "nullable",
    "pattern",
    "patternProperties",
    "propertyNames",
    "propertyOrdering",
    "readOnly",
    "then",
    "unevaluatedItems",
    "unevaluatedProperties",
    "uniqueItems",
    "writeOnly",
]

// 功能：校验 parametersJsonSchema 的明确关键字子集和递归结构。
// 参数：schema 为待检查对象；require_object 指示根类型必须包含 object。
// 返回值：无。
private func validate_json_parameter_schema(
    _ schema: [String: Any],
    require_object: Bool
) throws {
    try validate_gemini_fields(
        schema,
        supported: GEMINI_JSON_SCHEMA_SUPPORTED_FIELDS,
        unsupported: GEMINI_JSON_SCHEMA_UNSUPPORTED_FIELDS,
        context: "parametersJsonSchema")
    let types = try parse_gemini_json_schema_types(schema["type"])
    if require_object, types?.contains("object") != true {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema root type must contain object")
    }
    try validate_json_schema_scalar_fields(schema)
    try validate_json_schema_object_fields(schema, types: types)
    try validate_json_schema_array_fields(schema, types: types)

    for key in ["anyOf", "oneOf", "prefixItems"] {
        if let value = schema[key] {
            try validate_json_schema_list(value, key: key)
        }
    }
    if let value = schema["$defs"] {
        try validate_json_schema_map(value, key: "$defs")
    }
}

// 功能：解析 JSON Schema 的单一 type 或无重复 type 数组。
// 参数：value 为可选 type 字段。
// 返回值：未设置时为 nil，否则为合法类型集合。
private func parse_gemini_json_schema_types(_ value: Any?) throws -> Set<String>? {
    guard let value = value else { return nil }
    let values: [String]
    if let type = value as? String {
        values = [type]
    } else if let raw_values = value as? [Any], !raw_values.isEmpty {
        guard raw_values.allSatisfy({ $0 is String }) else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema type array must contain strings")
        }
        values = raw_values.compactMap { $0 as? String }
    } else {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema type must be a string or string array")
    }
    let types = Set(values)
    guard types.count == values.count,
          types.allSatisfy(GEMINI_JSON_SCHEMA_TYPES.contains) else {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema contains invalid or duplicate types")
    }
    return types
}

// 功能：校验 JSON Schema 的标量和标量数组字段。
// 参数：schema 为待检查对象。
// 返回值：无。
private func validate_json_schema_scalar_fields(
    _ schema: [String: Any]
) throws {
    for key in ["$ref", "description", "format", "title"] {
        if let value = schema[key], !(value is String) {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema field \(key) must be a string")
        }
    }
    if let reference = schema["$ref"] as? String, reference.isEmpty {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema $ref must not be empty")
    }
    for key in ["minimum", "maximum"] {
        if let value = schema[key], gemini_json_number(value) == nil {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema field \(key) must be a number")
        }
    }
    for key in ["minItems", "maxItems"] {
        if let value = schema[key],
           gemini_json_integer(value).map({ $0 >= 0 }) != true {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema field \(key) must be nonnegative")
        }
    }
    if let value = schema["enum"] {
        guard let values = value as? [Any], !values.isEmpty else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema enum must be a non-empty array")
        }
    }
}

// 功能：校验 JSON Schema 的 object 专用字段及其子 schema。
// 参数：schema 为待检查对象；types 为声明类型集合。
// 返回值：无。
private func validate_json_schema_object_fields(
    _ schema: [String: Any],
    types: Set<String>?
) throws {
    let object_keys = ["additionalProperties", "properties", "required"]
    if object_keys.contains(where: { schema[$0] != nil }),
       let types = types,
       !types.contains("object") {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema object fields require object type")
    }
    if let value = schema["properties"] {
        try validate_json_schema_map(value, key: "properties")
    }
    if let value = schema["required"] {
        guard let names = gemini_string_array(value, maximum_count: Int.max),
              Set(names).count == names.count else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema required must contain unique strings")
        }
    }
    if let value = schema["additionalProperties"] {
        if gemini_json_boolean(value) != nil { return }
        guard let child = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema additionalProperties is invalid")
        }
        try validate_json_parameter_schema(child, require_object: false)
    }
}

// 功能：校验 JSON Schema 的 array 专用字段及其子 schema。
// 参数：schema 为待检查对象；types 为声明类型集合。
// 返回值：无。
private func validate_json_schema_array_fields(
    _ schema: [String: Any],
    types: Set<String>?
) throws {
    let array_keys = ["items", "maxItems", "minItems", "prefixItems"]
    if array_keys.contains(where: { schema[$0] != nil }),
       let types = types,
       !types.contains("array") {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema array fields require array type")
    }
    if let value = schema["items"] {
        guard let child = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema items must be an object")
        }
        try validate_json_parameter_schema(child, require_object: false)
    }
}

// 功能：校验 JSON Schema map 的每个值并递归进入子 schema。
// 参数：value 为 map 值；key 为字段名。
// 返回值：无。
private func validate_json_schema_map(_ value: Any, key: String) throws {
    guard let schemas = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema \(key) must be an object")
    }
    for value in schemas.values {
        guard let child = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema \(key) value must be an object")
        }
        try validate_json_parameter_schema(child, require_object: false)
    }
}

// 功能：校验 JSON Schema 数组中的每个子 schema。
// 参数：value 为数组值；key 为字段名。
// 返回值：无。
private func validate_json_schema_list(_ value: Any, key: String) throws {
    guard let schemas = value as? [Any], !schemas.isEmpty else {
        throw GatewayProtocolError.invalid_request(
            "parametersJsonSchema \(key) must be a non-empty array")
    }
    for value in schemas {
        guard let child = value as? [String: Any] else {
            throw GatewayProtocolError.invalid_request(
                "parametersJsonSchema \(key) item must be an object")
        }
        try validate_json_parameter_schema(child, require_object: false)
    }
}

// 功能：区分 Gemini 对象支持字段、已知不支持字段和未知字段。
// 参数：object 为对象；supported 为支持字段；unsupported 为已知能力；
// context 为错误消息上下文。
// 返回值：无。
private func validate_gemini_fields(
    _ object: [String: Any],
    supported: Set<String>,
    unsupported: Set<String> = [],
    context: String
) throws {
    if let key = object.keys.first(where: unsupported.contains) {
        throw GatewayProtocolError.unsupported("\(context) field \(key) is not supported")
    }
    if let key = object.keys.first(where: { !supported.contains($0) }) {
        throw GatewayProtocolError.invalid_request("unknown \(context) field: \(key)")
    }
}

// 功能：允许可忽略的常规生成控制，并拒绝未知或无法表达的生成能力。
// 参数：value 为 generationConfig 字段。
// 返回值：无。
private func validate_gemini_generation_config(_ value: Any?) throws {
    guard let value = value else { return }
    guard let config = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request(
            "generationConfig must be an object")
    }
    try validate_gemini_fields(
        config,
        supported: [
            "candidateCount",
            "frequencyPenalty",
            "logprobs",
            "maxOutputTokens",
            "presencePenalty",
            "responseLogprobs",
            "responseMimeType",
            "seed",
            "stopSequences",
            "temperature",
            "topK",
            "topP",
        ],
        unsupported: [
            "_responseJsonSchema",
            "audioTranscriptionConfig",
            "enableAffectiveDialog",
            "enableEnhancedCivicAnswers",
            "imageConfig",
            "mediaResolution",
            "responseFormat",
            "responseJsonSchema",
            "responseModalities",
            "responseSchema",
            "speechConfig",
            "thinkingConfig",
            "translationConfig",
        ],
        context: "generationConfig")
    for (key, value) in config {
        try validate_gemini_generation_value(key: key, value: value)
    }
    if config["logprobs"] != nil {
        guard let response_logprobs = config["responseLogprobs"],
              gemini_json_boolean(response_logprobs) == true else {
            throw GatewayProtocolError.invalid_request(
                "logprobs requires responseLogprobs true")
        }
    }
}

// 功能：校验单个允许生成控制的 JSON 类型与明确范围。
// 参数：key 为字段名；value 为字段值。
// 返回值：无。
private func validate_gemini_generation_value(
    key: String,
    value: Any
) throws {
    if key == "responseMimeType" {
        guard let mime_type = value as? String else {
            throw GatewayProtocolError.invalid_request(
                "invalid generationConfig field: responseMimeType")
        }
        guard mime_type == "text/plain" else {
            throw GatewayProtocolError.unsupported(
                "responseMimeType \(mime_type) is not supported")
        }
        return
    }
    let valid: Bool
    switch key {
    case "temperature":
        valid = gemini_json_number(value).map { (0.0...2.0).contains($0) } ?? false
    case "topP":
        valid = gemini_json_number(value).map { (0.0...1.0).contains($0) } ?? false
    case "presencePenalty", "frequencyPenalty":
        valid = gemini_json_number(value) != nil
    case "topK", "candidateCount", "maxOutputTokens":
        valid = gemini_json_integer(value).map { $0 > 0 } ?? false
    case "seed":
        valid = gemini_json_integer(value) != nil
    case "logprobs":
        valid = gemini_json_integer(value).map { (0...20).contains($0) } ?? false
    case "responseLogprobs":
        valid = gemini_json_boolean(value) != nil
    case "stopSequences":
        valid = gemini_string_array(value, maximum_count: 5) != nil
    default:
        return
    }
    guard valid else {
        throw GatewayProtocolError.invalid_request(
            "invalid generationConfig field: \(key)")
    }
}

// 功能：提取有限 JSON number，并排除由 NSNumber 桥接的 boolean。
// 参数：value 为 JSON 值。
// 返回值：有限 Double；类型不符时为 nil。
private func gemini_json_number(_ value: Any) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let result = number.doubleValue
    return result.isFinite ? result : nil
}

// 功能：提取 int32 范围内的 JSON integer，并拒绝小数与 boolean。
// 参数：value 为 JSON 值。
// 返回值：整数；类型或范围不符时为 nil。
private func gemini_json_integer(_ value: Any) -> Int? {
    guard let number = gemini_json_number(value),
          number.rounded(.towardZero) == number,
          number >= Double(Int32.min),
          number <= Double(Int32.max) else { return nil }
    return Int(number)
}

// 功能：提取严格 JSON boolean，不把数字 0/1 当作布尔值。
// 参数：value 为 JSON 值。
// 返回值：布尔值；类型不符时为 nil。
private func gemini_json_boolean(_ value: Any) -> Bool? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

// 功能：提取有限长度且元素全为字符串的 JSON 数组。
// 参数：value 为 JSON 值；maximum_count 为最大元素数。
// 返回值：字符串数组；类型或长度不符时为 nil。
private func gemini_string_array(
    _ value: Any,
    maximum_count: Int
) -> [String]? {
    guard let values = value as? [Any],
          values.count <= maximum_count,
          values.allSatisfy({ $0 is String }) else { return nil }
    return values.compactMap { $0 as? String }
}

// 功能：把 Gemini functionCallingConfig 转为统一工具选择。
// 参数：value 为 toolConfig；declared_tools 为已解析工具。
// 返回值：允许工具子集，以及 AUTO、NONE、ANY 对应的统一策略。
private func parse_gemini_tool_choice(
    _ value: Any?,
    declared_tools: [GatewayTool]
) throws -> (tools: [GatewayTool], choice: GatewayToolChoice) {
    if value == nil || value is NSNull { return (declared_tools, .auto) }
    guard let tool_config = value as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid toolConfig")
    }
    try validate_gemini_fields(
        tool_config,
        supported: ["functionCallingConfig"],
        unsupported: [
            "includeServerSideToolInvocations",
            "retrievalConfig",
        ],
        context: "toolConfig")
    guard let function_config = tool_config["functionCallingConfig"]
            as? [String: Any] else {
        throw GatewayProtocolError.invalid_request("invalid toolConfig")
    }
    try validate_gemini_fields(
        function_config,
        supported: ["allowedFunctionNames", "mode"],
        context: "functionCallingConfig")
    let mode: String
    if let raw_mode = function_config["mode"] {
        guard let text = raw_mode as? String else {
            throw GatewayProtocolError.invalid_request(
                "function calling mode must be a string")
        }
        mode = text
    } else {
        mode = "AUTO"
    }
    guard ["AUTO", "NONE", "ANY", "VALIDATED"].contains(mode) else {
        throw GatewayProtocolError.invalid_request("invalid function calling mode")
    }
    let allowed_names = try parse_gemini_allowed_names(
        function_config["allowedFunctionNames"])
    if let names = allowed_names {
        let declared_names = Set(declared_tools.map(\.name))
        guard names.allSatisfy(declared_names.contains) else {
            throw GatewayProtocolError.invalid_request(
            "allowedFunctionNames contains an undeclared function")
        }
    }
    if mode == "VALIDATED" {
        throw GatewayProtocolError.unsupported(
            "function calling mode VALIDATED is not supported")
    }
    if mode != "ANY", allowed_names != nil {
        throw GatewayProtocolError.invalid_request(
            "allowedFunctionNames requires ANY mode")
    }

    let filtered_tools: [GatewayTool]
    if mode == "ANY", let names = allowed_names {
        let allowed_set = Set(names)
        filtered_tools = declared_tools.filter { allowed_set.contains($0.name) }
    } else {
        filtered_tools = declared_tools
    }

    switch mode {
    case "AUTO": return (filtered_tools, .auto)
    case "NONE": return (filtered_tools, .none)
    case "ANY":
        if filtered_tools.count == 1, allowed_names != nil {
            return (filtered_tools, .named(filtered_tools[0].name))
        }
        return (filtered_tools, .required)
    default:
        preconditionFailure("validated function calling mode")
    }
}

// 功能：解析可选 allowedFunctionNames 字符串数组。
// 参数：value 为 allowedFunctionNames 字段。
// 返回值：未提供时为 nil，否则为非空函数名数组。
private func parse_gemini_allowed_names(_ value: Any?) throws -> [String]? {
    guard let value = value else { return nil }
    guard let names = value as? [String],
          !names.isEmpty,
          names.allSatisfy({ !$0.isEmpty }) else {
        throw GatewayProtocolError.invalid_request(
            "allowedFunctionNames must be a non-empty string array")
    }
    return names
}

// 功能：解析可选非空字符串字段。
// 参数：value 为字段值；key 为错误消息使用的字段名。
// 返回值：缺省时为 nil，合法时为字符串。
private func gemini_optional_non_empty_string(
    _ value: Any?,
    key: String
) throws -> String? {
    guard let value = value else { return nil }
    guard let text = value as? String, !text.isEmpty else {
        throw GatewayProtocolError.invalid_request("\(key) must be a non-empty string")
    }
    return text
}

// 功能：把统一工具调用编码为 Gemini functionCall part。
// 参数：call 为统一工具调用。
// 返回值：只包含 functionCall、不会误写 text 的 part。
private func gemini_function_call_part(_ call: GatewayToolCall) -> [String: Any] {
    var function: [String: Any] = [
        "name": call.name,
        "args": call.arguments,
    ]
    if let call_id = call.id {
        function["id"] = call_id
    }
    return ["functionCall": function]
}

private let GEMINI_MANAGED_TOOL_FIELDS: Set<String> = [
    "codeExecution",
    "computerUse",
    "fileSearch",
    "googleMaps",
    "googleSearch",
    "googleSearchRetrieval",
    "mcpServers",
    "urlContext",
]
