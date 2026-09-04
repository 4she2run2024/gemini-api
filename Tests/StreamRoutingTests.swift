// 用途：验证协议 prompt、工具续轮、工具策略与 Anthropic 响应编码。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import Foundation

@main
struct StreamRoutingTests {
    static func main() throws {
        testToolActivation()
        test_developer_role_prompt()
        try testAnthropicPromptRoundTrip()
        try testStructuredToolParsing()
        testMalformedCallsAreVisible()
        try testToolChoiceEnforcement()
        try testAnthropicResponse()
        print("StreamRoutingTests passed")
    }

    // 功能：验证共享 prompt 为 developer 角色保留独立指令标签。
    // 参数：无。
    // 返回值：无。
    private static func test_developer_role_prompt() {
        let request = GatewayRequest(
            model: "gemini-3.6-flash",
            messages: [
                GatewayMessage(
                    role: .developer,
                    content: [.text("Inspect before answering.")]),
            ],
            tools: [],
            tool_choice: .none,
            stream: false)
        let prompt = gateway_prompt(request)
        precondition(prompt.contains("[Developer instruction]"))
    }

    private static func testToolActivation() {
        precondition(!hasActiveTools(nil, toolChoice: "auto"))
        precondition(!hasActiveTools([], toolChoice: "auto"))
        precondition(!hasActiveTools([openAITool], toolChoice: "none"))
        precondition(hasActiveTools([openAITool], toolChoice: "auto"))
        precondition(!hasActiveTools([anthropicTool], toolChoice: ["type": "none"]))
        precondition(hasActiveTools([anthropicTool], toolChoice: ["type": "any"]))
    }

    private static func testAnthropicPromptRoundTrip() throws {
        let request: [String: Any] = [
            "system": [["type": "text", "text": "Inspect before answering."]],
            "tools": [anthropicTool],
            "tool_choice": ["type": "auto"],
            "messages": [
                ["role": "user", "content": "Read README.md"],
                ["role": "assistant", "content": [[
                    "type": "tool_use", "id": "toolu_existing", "name": "Read",
                    "input": ["file_path": "README.md"],
                ]]],
                ["role": "user", "content": [[
                    "type": "tool_result", "tool_use_id": "toolu_existing",
                    "is_error": true,
                    "content": [["type": "text", "text": "Gemini Free"]],
                ]]],
            ],
        ]
        let prompt = try anthropicMessagesToPrompt(request)
        precondition(prompt.contains("Local Tool Protocol"))
        precondition(prompt.contains("\"file_path\""))
        precondition(prompt.contains("\"name\":\"Read\""))
        precondition(prompt.contains("Tool result for Read"))
        precondition(prompt.contains("id=toolu_existing"))
        precondition(prompt.contains("status=error"))
        precondition(prompt.contains("Gemini Free"))
    }

    private static func testStructuredToolParsing() throws {
        let raw = """
        ```tool_call
        {"name":"Read","arguments":{"file_path":"README.md"}}
        ```
        ```function_call
        {"name":"Glob","args":{"pattern":"Sources/*.swift"}}
        ```
        """
        let output = try parseStructuredToolCalls(raw, allowedToolNames: ["Read", "Glob"])
        precondition(output.text.isEmpty)
        precondition(output.calls.count == 2)
        precondition(output.calls[0].name == "Read")
        precondition(output.calls[0].arguments["file_path"] as? String == "README.md")
        precondition(output.calls[1].name == "Glob")
    }

    private static func testMalformedCallsAreVisible() {
        assertToolError("```tool_call\nnot json\n```", expected: "malformed")
        assertToolError(
            "```tool_call\n{\"name\":\"Unknown\",\"arguments\":{}}\n```",
            expected: "unknown")
        assertToolError(
            "```tool_call\n{\"name\":\"Read\",\"arguments\":\"bad\"}\n```",
            expected: "arguments")
    }

    private static func assertToolError(_ raw: String, expected: String) {
        do {
            _ = try parseStructuredToolCalls(raw, allowedToolNames: ["Read"])
            preconditionFailure("expected \(expected) tool error")
        } catch {
            precondition("\(error)".contains(expected))
        }
    }

    private static func testToolChoiceEnforcement() throws {
        let anyPolicy = toolCallPolicy([anthropicTool], toolChoice: ["type": "any"])
        assertPolicyError(anyPolicy, calls: [], expected: "required")

        let exactPolicy = toolCallPolicy(
            [anthropicTool, globTool], toolChoice: ["type": "tool", "name": "Read"])
        let globCall = ParsedToolCall(name: "Glob", arguments: ["pattern": "Sources/*.swift"])
        assertPolicyError(exactPolicy, calls: [globCall], expected: "requires Read")

        let autoPolicy = toolCallPolicy([anthropicTool], toolChoice: ["type": "auto"])
        try autoPolicy.validate([])

        let invalidRequest: [String: Any] = [
            "messages": [["role": "user", "content": "test"]],
            "tool_choice": ["type": "any"],
        ]
        do {
            _ = try anthropicMessagesToPrompt(invalidRequest)
            preconditionFailure("expected missing tool validation error")
        } catch {
            precondition("\(error)".contains("declared tool"))
        }
    }

    private static func assertPolicyError(
        _ policy: ToolCallPolicy, calls: [ParsedToolCall], expected: String
    ) {
        do {
            try policy.validate(calls)
            preconditionFailure("expected tool policy error")
        } catch {
            precondition("\(error)".contains(expected))
        }
    }

    private static func testAnthropicResponse() throws {
        let raw = """
        ```tool_call
        {"name":"Read","arguments":{"file_path":"README.md"}}
        ```
        """
        let output = try parseStructuredToolCalls(raw, allowedToolNames: ["Read"])
        let message = makeAnthropicMessage(AnthropicMessageBuildInput(
            model: "gemini-3.6-flash", prompt: "prompt", rawOutput: raw, output: output))
        precondition(message["stop_reason"] as? String == "tool_use")
        let blocks = message["content"] as? [[String: Any]]
        precondition(blocks?.first?["type"] as? String == "tool_use")
        precondition((blocks?.first?["id"] as? String)?.hasPrefix("toolu_") == true)

        let stream = anthropicSSE(message)
        precondition(stream.contains("event: message_start"))
        precondition(stream.contains("event: content_block_start"))
        precondition(stream.contains("\"type\":\"input_json_delta\""))
        precondition(stream.contains("event: message_delta"))
        precondition(stream.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
    }

    private static let anthropicTool: [String: Any] = [
        "name": "Read",
        "description": "Read a file",
        "input_schema": [
            "type": "object",
            "properties": ["file_path": ["type": "string"]],
            "required": ["file_path"],
        ],
    ]

    private static let openAITool: [String: Any] = [
        "type": "function",
        "function": ["name": "lookup"],
    ]

    private static let globTool: [String: Any] = [
        "name": "Glob",
        "description": "Find files",
        "input_schema": ["type": "object"],
    ]
}
