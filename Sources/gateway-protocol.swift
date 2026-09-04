import Foundation

// 用途：定义协议无关的网关请求、响应、工具与错误数据类型。
// 使用方法：由协议适配器构造这些类型，再交给统一生成管线处理。

enum GatewayRole: String {
    case system
    case developer
    case user
    case assistant
    case tool
}

struct GatewayToolCall {
    let id: String?
    let name: String
    let arguments: [String: Any]
}

struct GatewayToolResult {
    let call_id: String?
    let name: String?
    let output: Any
    let is_error: Bool?

    // 功能：创建协议无关工具结果，并可选保留错误状态。
    // 参数：call_id 为调用 ID；name 为工具名；output 为结果；
    // is_error 为错误状态。
    // 返回值：初始化后的工具结果。
    init(
        call_id: String?,
        name: String?,
        output: Any,
        is_error: Bool? = nil
    ) {
        self.call_id = call_id
        self.name = name
        self.output = output
        self.is_error = is_error
    }
}

enum GatewayContent {
    case text(String)
    case tool_call(GatewayToolCall)
    case tool_result(GatewayToolResult)
}

struct GatewayMessage {
    let role: GatewayRole
    let content: [GatewayContent]
}

struct GatewayTool {
    let name: String
    let description: String
    let parameters: [String: Any]
}

enum GatewayToolChoice {
    case auto
    case none
    case required
    case named(String)

    var required_name: String? {
        if case .named(let name) = self { return name }
        return nil
    }
}

struct GatewayRequest {
    let model: String
    let messages: [GatewayMessage]
    let tools: [GatewayTool]
    let tool_choice: GatewayToolChoice
    let stream: Bool
}

enum GatewayFinishReason: String {
    case stop
    case tool_calls
}

struct GatewayUsage {
    let input_tokens: Int
    let output_tokens: Int
    var total_tokens: Int { input_tokens + output_tokens }
}

struct GatewayResult {
    let model: String
    let text: String
    let tool_calls: [GatewayToolCall]
    let finish_reason: GatewayFinishReason
    let usage: GatewayUsage
}

enum GatewayProtocolError: Error, CustomStringConvertible {
    case invalid_request(String)
    case unsupported(String)
    case upstream(String)
    case tool_protocol(String)

    var http_status: Int {
        switch self {
        case .invalid_request, .unsupported: return 400
        case .upstream, .tool_protocol: return 502
        }
    }

    var code: String {
        switch self {
        case .invalid_request: return "invalid_request"
        case .unsupported: return "unsupported_feature"
        case .upstream: return "upstream_error"
        case .tool_protocol: return "tool_protocol_error"
        }
    }

    var description: String {
        switch self {
        case .invalid_request(let message), .unsupported(let message),
             .upstream(let message), .tool_protocol(let message):
            return message
        }
    }
}
