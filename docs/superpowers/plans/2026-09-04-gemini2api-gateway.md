# Gemini2API API Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改写 Gemini Web Engine 的前提下交付 Gemini2API 0.1.0，
提供七个 OpenAI、Anthropic 和 Gemini 兼容 endpoint。

**Architecture:** 外部协议适配器把请求转换为统一 `GatewayRequest`，
`GatewayPipeline` 复用现有 `TextGenerating` 和工具协议，再把
`GatewayResult` 编码为各协议 JSON 或 SSE。HTTPServer 只保留 HTTP、鉴权、
路由和写出职责。

**Tech Stack:** Swift 6、Foundation、Network、CryptoKit、AppKit、
ServiceManagement、Bash、GitHub Actions。

**Spec:**
`docs/superpowers/specs/2026-09-03-gemini2api-gateway-design.md`

## Global Constraints

- 产品显示名必须精确为 `Gemini2API`，版本必须为 `0.1.0`。
- App、DMG 和 ZIP 必须分别为 `Gemini2API.app`、`Gemini2API.dmg` 和
  `Gemini2API-macOS.zip`。
- Bundle ID 必须为 `com.gemini2api.gateway`。
- 不修改 `Sources/Engine.swift` 的 Gemini Web 协议行为。
- 不引入新的项目运行时依赖。
- 新变量和函数使用 `snake_case`，常量使用 `UPPER_CASE`。
- 新文件使用 `kebab-case`；不批量重命名继承的旧文件。
- 新 Swift 文件必须有中文用途和使用方法说明；函数必须说明参数和
  返回值。
- 每行不超过 100 字符。
- 所有路径通过系统 API、当前脚本目录或 Git 动态获取。
- 不支持的媒体、托管工具和服务端状态必须返回明确 `400`。
- 新行为遵循 RED、GREEN、REFACTOR，每个生产改动前必须看到对应测试失败。
- GitHub 目标固定为 `4she2run2024/gemini-api`，工作 branch 固定为
  `feat/api-gateway`，PR base 固定为 `main`。

---

## File Responsibility Map

- `Sources/gateway-protocol.swift`：统一角色、内容、工具、请求、结果和错误。
- `Sources/gateway-pipeline.swift`：统一 prompt、模型解析、生成和工具解析。
- `Sources/http-server-responses.swift`：Responses 请求/响应/SSE 适配。
- `Sources/http-server-gemini.swift`：Gemini 路径、请求/响应/SSE 适配。
- `Tests/gateway-protocol-tests.swift`：统一类型、prompt 和错误语义。
- `Tests/gateway-pipeline-tests.swift`：生成、工具解析和流式生成。
- `Tests/responses-protocol-tests.swift`：Responses JSON 与 SSE 契约。
- `Tests/gemini-protocol-tests.swift`：Gemini JSON、路径与 SSE 契约。
- `Tests/config-migration-tests.swift`：新旧配置优先级和非破坏迁移。
- `Tests/real-upstream-smoke.swift`：真实 Gemini Web 最小文本验收。
- `Tests/sdk-smoke-server.swift`：官方 SDK 验收使用的本地 fake server。
- `Tests/sdk-smoke.py`：OpenAI 和 Anthropic 官方 Python SDK 验收。
- `Tests/gemini-sdk-smoke.mjs`：Google 官方 Node SDK 验收。
- `Tests/run-tests.sh`：动态编译并执行全部 Swift 测试。
- `Tests/HTTPServerIntegrationTests.swift`：七个 endpoint 的 HTTP 验收。
- `Sources/Config.swift`：新配置位置和旧配置一次性迁移。
- `build.sh`、`make-dmg.sh`、`.github/workflows/build.yml`：
  Gemini2API 构建、测试和 Release 附件。
- `README.md`：0.1.0 用户契约、兼容矩阵、示例、限制和更新历史。

---

### Task 1: 统一协议类型与可重复测试入口

**Files:**

- Create: `Sources/gateway-protocol.swift`
- Create: `Tests/gateway-protocol-tests.swift`
- Create: `Tests/run-tests.sh`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: `ParsedToolCall` from `Sources/ToolCalling.swift`。
- Produces: `GatewayRole`、`GatewayContent`、`GatewayMessage`、
  `GatewayTool`、`GatewayToolChoice`、`GatewayRequest`、
  `GatewayToolCall`、`GatewayToolResult`、`GatewayFinishReason`、
  `GatewayResult`、`GatewayProtocolError`。

- [ ] **Step 1: 写统一类型的失败测试**

创建 `Tests/gateway-protocol-tests.swift`，先覆盖错误 status、命名工具选择和
usage 总数：

```swift
import Foundation

@main
struct GatewayProtocolTests {
    static func main() {
        let choice = GatewayToolChoice.named("Read")
        precondition(choice.required_name == "Read")

        let error = GatewayProtocolError.unsupported("image input")
        precondition(error.http_status == 400)
        precondition(error.code == "unsupported_feature")

        let usage = GatewayUsage(input_tokens: 8, output_tokens: 5)
        precondition(usage.total_tokens == 13)
        print("GatewayProtocolTests passed")
    }
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
swiftc Tests/gateway-protocol-tests.swift \
  -o "$(mktemp -d)/gateway-protocol-tests"
```

Expected: FAIL，错误包含 `cannot find 'GatewayToolChoice' in scope`。

- [ ] **Step 3: 实现最小统一类型**

创建 `Sources/gateway-protocol.swift`，文件头说明它只保存协议无关数据，
并实现以下准确接口：

```swift
import Foundation

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
```

- [ ] **Step 4: 创建统一测试入口并确认 GREEN**

创建 `Tests/run-tests.sh`。脚本接受无参数或 `--auto`，使用 `mktemp -d`
生成动态输出目录，依次编译每个 `@main` 测试，不在仓库留下二进制。
第一版只运行现有两组测试和 `gateway-protocol-tests.swift`。

```bash
#!/bin/bash
# 用途：编译并执行 Gemini2API Swift 测试。
# 使用方法：bash Tests/run-tests.sh [--auto]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--auto") ]]; then
  echo "用法：bash Tests/run-tests.sh [--auto]" >&2
  exit 2
fi

TEST_OUTPUT_DIR="$(mktemp -d)"

run_test() {
  local test_name="$1"
  shift
  swiftc "$@" -o "$TEST_OUTPUT_DIR/$test_name"
  "$TEST_OUTPUT_DIR/$test_name"
}

run_test stream-routing-tests \
  Sources/Prompt.swift \
  Sources/ToolCalling.swift \
  Sources/AnthropicProtocol.swift \
  Sources/Util.swift \
  Tests/StreamRoutingTests.swift

run_test http-server-tests \
  Sources/AnthropicProtocol.swift \
  Sources/Config.swift \
  Sources/Engine.swift \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/Models.swift \
  Sources/Prompt.swift \
  Sources/ToolCalling.swift \
  Sources/Util.swift \
  Tests/HTTPServerIntegrationTests.swift \
  -framework Network \
  -framework CryptoKit

run_test gateway-protocol-tests \
  Sources/gateway-protocol.swift \
  Tests/gateway-protocol-tests.swift
```

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected:

```text
StreamRoutingTests passed
HTTPServerIntegrationTests passed
GatewayProtocolTests passed
```

- [ ] **Step 5: 更新忽略规则并提交**

把新产品构建产物加入 `.gitignore`：

```gitignore
Gemini2API.app/
Gemini2API-macOS.zip
Gemini2API.dmg
```

保留旧 Gemini Free 规则，避免旧构建产物突然进入 Git。

Run:

```bash
git add Sources/gateway-protocol.swift Tests/gateway-protocol-tests.swift \
  Tests/run-tests.sh .gitignore
git diff --cached --check
git commit -m "feat: add shared gateway protocol types"
```

---

### Task 2: 统一生成管线与协议无关 prompt

**Files:**

- Create: `Sources/gateway-pipeline.swift`
- Create: `Tests/gateway-pipeline-tests.swift`
- Modify: `Sources/Prompt.swift`
- Modify: `Sources/ToolCalling.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

- Consumes: Task 1 的 `GatewayRequest`、`GatewayResult`、
  `TextGenerating`、`resolveModel`、`parseStructuredToolCalls`。
- Produces: `GatewayExecutionContext`、`GatewayPipeline.prepare`、
  `GatewayPipeline.generate`、`GatewayPipeline.stream_text`、
  `gateway_prompt(_:)`。

- [ ] **Step 1: 写 prompt 与工具续轮失败测试**

创建 `Tests/gateway-pipeline-tests.swift`。构造包含 system、developer、
assistant tool call 和 user tool result 的 `GatewayRequest`，断言：

```swift
let prompt = gateway_prompt(request)
precondition(prompt.contains("[System instruction]"))
precondition(prompt.contains("[Developer instruction]"))
precondition(prompt.contains("\"name\":\"Read\""))
precondition(prompt.contains("[Tool result for Read]"))
precondition(prompt.contains("Gemini2API"))
```

添加 `FakeGatewayGenerator`，让 `generate` 返回一个合法 `tool_call` block，
并断言 `GatewayPipeline.generate` 返回 `finish_reason == .tool_calls`。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，编译错误指出 `gateway_prompt` 或 `GatewayPipeline` 不存在。

- [ ] **Step 3: 实现 prompt 转换**

在 `Sources/Prompt.swift` 增加：

```swift
func gateway_prompt(_ request: GatewayRequest) -> String
```

转换规则必须准确为：

- system -> `[System instruction]`。
- developer -> `[Developer instruction]`。
- user -> `[User]`。
- assistant 文本 -> `[Assistant]`。
- assistant 工具调用 -> 现有 `toolCallBlock`。
- tool result -> `[Tool result for name-or-call-id]`，其中标识取实际值。
- 有活动工具时，prompt 第一段为现有 `# Local Tool Protocol`。

在 `Sources/ToolCalling.swift` 增加转换函数：

```swift
func gateway_tool_policy(_ request: GatewayRequest) -> ToolCallPolicy
func gateway_tool_dictionaries(_ tools: [GatewayTool]) -> [Any]
```

`named` 必须映射到指定工具，`required` 必须要求至少一个工具，`none`
必须禁用工具。

- [ ] **Step 4: 实现生成管线**

创建 `Sources/gateway-pipeline.swift`，实现：

```swift
struct GatewayExecutionContext {
    let request: GatewayRequest
    let model: ResolvedModel
    let generation: GenerationRequest
    let tool_policy: ToolCallPolicy
}

final class GatewayPipeline {
    let generator: TextGenerating
    let default_model: String

    init(generator: TextGenerating, default_model: String)

    func prepare(_ request: GatewayRequest) throws
        -> GatewayExecutionContext

    func generate(_ context: GatewayExecutionContext) throws
        -> GatewayResult

    func stream_text(
        _ context: GatewayExecutionContext,
        is_cancelled: @escaping () -> Bool,
        on_delta: @escaping (String) -> Void
    ) throws
}
```

`prepare` 必须拒绝空 prompt、required 但无工具、named 指向未声明工具。
`generate` 必须把 `ToolCallParseError` 转换为 `.tool_protocol`，把其他生成
错误转换为 `.upstream`。usage 使用现有 `approximateTokenCount`。

- [ ] **Step 5: 运行测试并确认 GREEN**

把新测试加入 `Tests/run-tests.sh`，然后运行：

```bash
bash Tests/run-tests.sh --auto
```

Expected: 四组测试全部打印 `passed`，退出码为 0。

- [ ] **Step 6: 提交**

```bash
git add Sources/gateway-pipeline.swift Sources/Prompt.swift \
  Sources/ToolCalling.swift Tests/gateway-pipeline-tests.swift \
  Tests/run-tests.sh
git diff --cached --check
git commit -m "feat: add shared gateway generation pipeline"
```

---

### Task 3: 让现有 OpenAI Chat 与 Anthropic 使用共享管线

**Files:**

- Modify: `Sources/HTTPServer+OpenAI.swift`
- Modify: `Sources/HTTPServer+Anthropic.swift`
- Modify: `Sources/AnthropicProtocol.swift`
- Modify: `Tests/StreamRoutingTests.swift`
- Modify: `Tests/HTTPServerIntegrationTests.swift`

**Interfaces:**

- Consumes: Task 2 的 `GatewayPipeline` 与 `GatewayRequest`。
- Produces: `parse_openai_chat_request(_:, default_model:)`、
  `parse_anthropic_request(_:, default_model:)`，并保持现有 endpoint 输出。

- [ ] **Step 1: 扩充回归测试并确认 RED**

在 `Tests/StreamRoutingTests.swift` 增加 developer 角色测试；在
`Tests/HTTPServerIntegrationTests.swift` 让 fake generator 记录最后一个 prompt，
并新增两项断言：

```swift
precondition(fake.last_prompt.contains("[Developer instruction]"))
precondition(openai_stream.text.hasSuffix("data: [DONE]\n\n"))
```

另加 Anthropic `tool_result` 续轮测试，断言 prompt 包含实际工具名称和
结果文本。

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: developer 角色断言失败，因为旧 `messagesToPrompt` 把它当 user。

- [ ] **Step 2: 实现两个请求适配器**

在对应协议文件中实现：

```swift
func parse_openai_chat_request(
    _ request: [String: Any],
    default_model: String
) throws -> GatewayRequest

func parse_anthropic_request(
    _ request: [String: Any],
    default_model: String
) throws -> GatewayRequest
```

适配器必须把媒体 content part 转成 `.unsupported`，把 malformed tool
转成 `.invalid_request`。OpenAI `tool_choice` 和 Anthropic `tool_choice`
分别映射到统一 enum。

- [ ] **Step 3: 用共享管线替换重复生成逻辑**

两个 handler 从 `HTTPServer` 的 `generator` 和 `cfg.defaultModel` 创建
`GatewayPipeline`。非流式调用 `generate`；无活动工具的文本流调用
`stream_text`；活动工具继续先完整解析后按原协议编码。

不得改变：

- Chat Completion object、chunk 和 `[DONE]`。
- Anthropic message object 与 message_start 到 message_stop 顺序。
- 现有 `400` 和 `502` 分类。

- [ ] **Step 4: 运行回归测试并确认 GREEN**

```bash
bash Tests/run-tests.sh --auto
```

Expected: 全部现有测试和新增回归测试通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/HTTPServer+OpenAI.swift Sources/HTTPServer+Anthropic.swift \
  Sources/AnthropicProtocol.swift Tests/StreamRoutingTests.swift \
  Tests/HTTPServerIntegrationTests.swift
git diff --cached --check
git commit -m "refactor: share gateway pipeline across existing APIs"
```

---

### Task 4: OpenAI Responses 非流式协议

**Files:**

- Create: `Sources/http-server-responses.swift`
- Create: `Tests/responses-protocol-tests.swift`
- Modify: `Sources/HTTPServer.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

- Consumes: Task 2 的统一请求和结果。
- Produces: `parse_responses_request(_:, default_model:)`、
  `make_responses_response(_:, response_id:)`、
  `HTTPServer.handle_responses(_:, body:)`。

- [ ] **Step 1: 写 Responses 解析和输出失败测试**

创建 `Tests/responses-protocol-tests.swift`，覆盖：

```swift
let request: [String: Any] = [
    "model": "gemini-3.8-flash",
    "instructions": "Inspect first.",
    "input": [[
        "role": "user",
        "content": [["type": "input_text", "text": "Read README.md"]],
    ]],
    "tools": [[
        "type": "function",
        "name": "Read",
        "description": "Read a file",
        "parameters": ["type": "object"],
    ]],
    "store": false,
]
```

断言 system message 位于 user message 前、工具名为 `Read`，并断言
`make_responses_response` 返回 `object == "response"`、`status == "completed"`、
文本 item 使用 `output_text`。

增加 function_call、function_call_output 续轮，以及 `store: true`、
`input_image`、内置工具的 `.unsupported` 测试。

- [ ] **Step 2: 运行测试并确认 RED**

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，编译错误指出 `parse_responses_request` 不存在。

- [ ] **Step 3: 实现 Responses 输入解析**

在 `Sources/http-server-responses.swift` 实现：

```swift
func parse_responses_request(
    _ request: [String: Any],
    default_model: String
) throws -> GatewayRequest
```

解析必须支持 string input、message item、`input_text`、`output_text`、
`function_call` 和 `function_call_output`。只接受 `type: function` 工具。
`background: true`、`store: true`、非空 `previous_response_id` 和
非空 `conversation` 返回 `.unsupported`。

- [ ] **Step 4: 实现非流式响应与 handler**

实现：

```swift
func make_responses_response(
    _ result: GatewayResult,
    response_id: String
) -> [String: Any]

extension HTTPServer {
    func handle_responses(_ conn: NWConnection, body: Data)
}
```

文本结果创建一个 message item；每个工具调用创建一个 `function_call` item。
usage 必须包含 `input_tokens`、`output_tokens` 和 `total_tokens`。

在 `HTTPServer.route` 增加：

```swift
case ("POST", "/v1/responses"):
    handle_responses(conn, body: body)
```

- [ ] **Step 5: 运行测试并确认 GREEN**

把新测试加入 `Tests/run-tests.sh` 后运行：

```bash
bash Tests/run-tests.sh --auto
```

Expected: Responses 单元测试及全部回归测试通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/http-server-responses.swift Sources/HTTPServer.swift \
  Tests/responses-protocol-tests.swift Tests/run-tests.sh
git diff --cached --check
git commit -m "feat: add OpenAI Responses endpoint"
```

---

### Task 5: OpenAI Responses SSE 与流式错误

**Files:**

- Modify: `Sources/http-server-responses.swift`
- Modify: `Tests/responses-protocol-tests.swift`
- Modify: `Tests/HTTPServerIntegrationTests.swift`

**Interfaces:**

- Consumes: Task 4 的 Responses 解析和 object builder。
- Produces: `ResponsesStreamEncoder`、Responses 文本 delta、工具参数事件和
  协议内 error event。

- [ ] **Step 1: 写 SSE 顺序失败测试**

在 `Tests/responses-protocol-tests.swift` 对文本 `GatewayResult` 断言事件类型：

```swift
let expected_types = [
    "response.created",
    "response.in_progress",
    "response.output_item.added",
    "response.content_part.added",
    "response.output_text.delta",
    "response.output_text.done",
    "response.content_part.done",
    "response.output_item.done",
    "response.completed",
]
precondition(actual_types == expected_types)
precondition(sequence_numbers == Array(0..<expected_types.count))
```

对工具结果断言存在：

```text
response.function_call_arguments.delta
response.function_call_arguments.done
```

并断言所有事件使用同一个 response ID 和 item ID。

- [ ] **Step 2: 运行测试并确认 RED**

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，编译错误指出 `ResponsesStreamEncoder` 不存在。

- [ ] **Step 3: 实现 SSE encoder**

实现准确接口：

```swift
struct ResponsesStreamEncoder {
    let response_id: String
    let model: String
    private(set) var sequence_number: Int

    init(response_id: String, model: String)
    mutating func start_events() -> [String]
    mutating func text_delta(_ delta: String) -> String
    mutating func finish_text(_ result: GatewayResult) -> [String]
    mutating func finish_tools(_ result: GatewayResult) -> [String]
    mutating func error_event(_ error: GatewayProtocolError) -> String
}
```

每个返回字符串使用 `data: `、JSON object 和两个换行。`text_delta`
每次只放当前增量；
`response.completed` 放完整最终 Response object。

- [ ] **Step 4: 把 encoder 接入 HTTP handler**

`stream: true` 且没有活动工具时：先写 start events，再通过
`GatewayPipeline.stream_text` 逐 delta 写出，累计完整文本，最后写结束事件。

有活动工具时：先 `GatewayPipeline.generate`，再写 start events 和完整工具事件。
SSE header 已写出后的异常必须写 `error` event，不能写 assistant 文本。

- [ ] **Step 5: 运行测试并确认 GREEN**

```bash
bash Tests/run-tests.sh --auto
```

Expected: Responses SSE 契约和 HTTP 流式测试通过，所有 sequence 连续递增。

- [ ] **Step 6: 提交**

```bash
git add Sources/http-server-responses.swift \
  Tests/responses-protocol-tests.swift Tests/HTTPServerIntegrationTests.swift
git diff --cached --check
git commit -m "feat: stream OpenAI Responses events"
```

---

### Task 6: Gemini GenerateContent 非流式协议

**Files:**

- Create: `Sources/http-server-gemini.swift`
- Create: `Tests/gemini-protocol-tests.swift`
- Modify: `Sources/HTTPServer.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

- Consumes: Task 2 的统一请求和结果。
- Produces: `GeminiRoute`、`parse_gemini_route(_:)`、
  `parse_gemini_request(_:, model:, stream:)`、
  `make_gemini_response(_:, response_id:)`。

- [ ] **Step 1: 写 Gemini 路径和请求失败测试**

创建 `Tests/gemini-protocol-tests.swift`，断言：

```swift
let route = try parse_gemini_route(
    "/v1beta/models/gemini-3.8-flash:generateContent?key=test"
)
precondition(route.model == "gemini-3.8-flash")
precondition(route.stream == false)
```

构造包含 `systemInstruction`、user/model 文本、`functionCall`、
`functionResponse`、`functionDeclarations` 和 ANY tool mode 的请求，断言统一请求
保留每一项语义。

增加空模型、额外 path segment、`inlineData`、`fileData`、`googleSearch` 和
`codeExecution` 的失败断言。

- [ ] **Step 2: 运行测试并确认 RED**

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，编译错误指出 `parse_gemini_route` 不存在。

- [ ] **Step 3: 实现严格路径与请求解析**

在 `Sources/http-server-gemini.swift` 实现：

```swift
struct GeminiRoute {
    let model: String
    let stream: Bool
}

func parse_gemini_route(_ path: String) throws -> GeminiRoute

func parse_gemini_request(
    _ request: [String: Any],
    model: String,
    stream: Bool
) throws -> GatewayRequest
```

`functionDeclarations` 转成 `GatewayTool`。AUTO、NONE、ANY 和
`allowedFunctionNames` 转成统一工具策略；ANY 加单个允许函数时使用 `.named`，
否则使用 `.required`。

- [ ] **Step 4: 实现非流式 Gemini 响应和 handler**

实现：

```swift
func make_gemini_response(
    _ result: GatewayResult,
    response_id: String
) -> [String: Any]

extension HTTPServer {
    func handle_gemini(
        _ conn: NWConnection,
        body: Data,
        route: GeminiRoute
    )
}
```

文本映射成 `parts[].text`，工具映射成 `parts[].functionCall`。文本和合法
工具调用的 `finishReason` 都使用 `STOP`；工具调用成功时 content 中必须有
functionCall，不能放进 text。

`HTTPServer.route` 在 default 前调用 `parse_gemini_route`；只有严格匹配成功时
进入 Gemini handler，其他路径继续返回 `404`。

- [ ] **Step 5: 运行测试并确认 GREEN**

把新测试加入 `Tests/run-tests.sh`，运行：

```bash
bash Tests/run-tests.sh --auto
```

Expected: Gemini 非流式、路径和 unsupported 测试全部通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/http-server-gemini.swift Sources/HTTPServer.swift \
  Tests/gemini-protocol-tests.swift Tests/run-tests.sh
git diff --cached --check
git commit -m "feat: add Gemini GenerateContent endpoint"
```

---

### Task 7: Gemini SSE、鉴权和协议错误 envelope

**Files:**

- Modify: `Sources/http-server-gemini.swift`
- Modify: `Sources/HTTPServer.swift`
- Modify: `Tests/gemini-protocol-tests.swift`
- Modify: `Tests/HTTPServerIntegrationTests.swift`

**Interfaces:**

- Consumes: Task 6 的 Gemini parser 和 response builder。
- Produces: `gemini_sse_chunk(_:)`、`gemini_error(_:)`、
  `openai_error(_:)`、协议感知鉴权错误。

- [ ] **Step 1: 写 Gemini SSE 和错误失败测试**

断言两个 text delta 形成两个 SSE chunk：

```swift
precondition(stream.contains("data: "))
precondition(stream.contains("\"text\":\"Hel\""))
precondition(stream.contains("\"text\":\"lo\""))
precondition(!stream.contains("[DONE]"))
```

断言 Gemini `400` envelope 为：

```json
{
  "error": {
    "code": 400,
    "message": "image input is not supported",
    "status": "INVALID_ARGUMENT"
  }
}
```

HTTP 测试分别用 Bearer、`x-api-key`、`x-goog-api-key`、query key 调用，
并断言错误 key 得到 `401`。

- [ ] **Step 2: 运行测试并确认 RED**

```bash
bash Tests/run-tests.sh --auto
```

Expected: SSE 或协议错误 envelope 断言失败。

- [ ] **Step 3: 实现 Gemini SSE**

实现：

```swift
func gemini_sse_chunk(_ response: [String: Any]) -> String {
    "data: \(jsonString(response))\n\n"
}
```

文本流每个 delta 构造一个只有当前 delta 的 candidate。最终 chunk 增加
`finishReason` 和完整 usage。工具流完整解析后输出一个 functionCall chunk。

- [ ] **Step 4: 实现协议感知错误**

在 HTTPServer 根据 path 选择 OpenAI、Anthropic 或 Gemini error builder。
统一 status 仍由 `GatewayProtocolError.http_status` 决定。鉴权发生在 handler 前，
但必须根据 path 返回正确 envelope。

SSE 已开始后的 Gemini 错误输出一个 `data:` error object 并关闭连接。

- [ ] **Step 5: 运行测试并确认 GREEN**

```bash
bash Tests/run-tests.sh --auto
```

Expected: Gemini SSE、四种鉴权形式和协议错误测试通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/http-server-gemini.swift Sources/HTTPServer.swift \
  Tests/gemini-protocol-tests.swift Tests/HTTPServerIntegrationTests.swift
git diff --cached --check
git commit -m "feat: stream Gemini responses and normalize errors"
```

---

### Task 8: 配置迁移与 Gemini2API 产品身份

**Files:**

- Modify: `Sources/Config.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/SettingsWindow.swift`
- Modify: `Sources/Prompt.swift`
- Modify: `build.sh`
- Modify: `make-dmg.sh`
- Modify: `.github/workflows/build.yml`
- Create: `Tests/config-migration-tests.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

- Consumes: 现有 `Store` JSON 字段。
- Produces: `Store.init(config_root:)` 可测试初始化、`migrate_legacy_config()`、
  Gemini2API App 与 Release 产物。

- [ ] **Step 1: 写配置迁移失败测试**

创建临时 root，在旧目录写入：

```json
{
  "port": 18081,
  "default_model": "gemini-3.8-flash",
  "api_keys": ["test-key"]
}
```

创建 `Store(config_root: root)` 并调用 `load()`，断言：

```swift
precondition(store.port == 18081)
precondition(store.path.path.hasSuffix(".config/gemini2api/config.json"))
precondition(file_manager.fileExists(atPath: store.path.path))
precondition(file_manager.fileExists(atPath: legacy_path.path))
```

再让新旧配置同时存在，断言新配置优先且旧文件内容未改变。

- [ ] **Step 2: 运行测试并确认 RED**

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，因为 `Store` 目前没有 `init(config_root:)` 且仍使用旧目录。

- [ ] **Step 3: 实现配置注入和迁移**

为 `Store` 增加：

```swift
init(config_root: URL = FileManager.default.homeDirectoryForCurrentUser)

func migrate_legacy_config() throws
```

`path` 指向 `.config/gemini2api/config.json`，`legacy_path` 指向旧路径。
只有新文件不存在且旧文件存在时才读取旧 JSON 并原子写入新文件。
日志只能包含错误类型和路径类别，不能输出 JSON 内容。

- [ ] **Step 4: 完成产品重命名**

执行精确替换：

- 菜单、About、设置窗口：`Gemini2API`。
- About URL：`https://github.com/4she2run2024/gemini-api`。
- 不支持图片的提示：`Gemini2API`。
- `build.sh`：`APP="Gemini2API"`、`VERSION="0.1.0"`、
  Bundle ID `com.gemini2api.gateway`。
- `make-dmg.sh`：`DMG="Gemini2API.dmg"`。
- CI ZIP、artifact 和 Release files 使用新名称。

- [ ] **Step 5: 运行测试并检查命名残留**

```bash
bash Tests/run-tests.sh --auto
rg -n "Gemini Free|GeminiFree|wp-x/gemini-free" \
  Sources Tests build.sh make-dmg.sh .github README.md
```

Expected: 测试通过；`rg` 只允许 README 的迁移说明或测试中的旧配置 fixture。

- [ ] **Step 6: 提交**

```bash
git add Sources/Config.swift Sources/AppDelegate.swift \
  Sources/SettingsWindow.swift Sources/Prompt.swift build.sh make-dmg.sh \
  .github/workflows/build.yml Tests/config-migration-tests.swift \
  Tests/run-tests.sh
git diff --cached --check
git commit -m "feat: rename the app to Gemini2API"
```

---

### Task 9: 七个 endpoint 的完整 HTTP 验收与 README

**Files:**

- Modify: `Tests/HTTPServerIntegrationTests.swift`
- Modify: `Tests/run-tests.sh`
- Rewrite: `README.md`
- Modify: `.github/workflows/build.yml`

**Interfaces:**

- Consumes: Tasks 1-8 的完整 API Gateway。
- Produces: 七路 HTTP acceptance、中文 README 0.1.0 和统一 CI gate。

- [ ] **Step 1: 写 endpoint 验收矩阵**

在 HTTP integration test 中建立以下矩阵，每条都验证 status 和协议关键字段：

```swift
let endpoint_cases = [
    ("GET", "/v1/models", "\"object\":\"list\""),
    ("POST", "/v1/chat/completions", "chat.completion"),
    ("POST", "/v1/responses", "\"object\":\"response\""),
    ("POST", "/v1/messages", "\"type\":\"message\""),
    ("POST", "/v1/messages/count_tokens", "input_tokens"),
    (
        "POST",
        "/v1beta/models/gemini-3.8-flash:generateContent",
        "candidates"
    ),
    (
        "POST",
        "/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse",
        "data:"
    ),
]
```

对 Chat、Responses、Messages 和 Gemini generation 增加文本、工具、工具结果
续轮和 unsupported 输入用例。增加 unknown route `404` 和 fake generator error
`502`。

- [ ] **Step 2: 运行完整矩阵**

```bash
bash Tests/run-tests.sh --auto
```

Expected: 全部矩阵断言通过。若失败，停止文档工作，使用
`superpowers:systematic-debugging` 定位根因，再为根因补一个能看到 RED 的
回归测试。

- [ ] **Step 3: 重写 README 0.1.0**

README 必须按以下顺序包含：

1. `# Gemini2API 0.1.0`
2. 项目说明
3. 功能特性
4. API 与兼容矩阵
5. 前置要求
6. 安装方法
7. 使用方法
8. OpenAI SDK、Codex、Claude Code、Anthropic SDK、Gemini SDK 示例
9. 配置说明与旧配置迁移
10. 已知限制
11. 常见问题
12. 构建与测试
13. 更新历史
14. 致谢与许可证

七个 endpoint 都必须有 curl 或 SDK 示例。兼容矩阵必须区分“支持”、
“接受但不保证生效”和“明确不支持”。依赖章节写明 macOS 13+，源码
构建需要 Xcode Command Line Tools，DMG 制作额外需要 `create-dmg`。

- [ ] **Step 4: 把统一测试入口接入 CI**

`.github/workflows/build.yml` 的 Test step 只调用：

```yaml
- name: Test
  run: bash Tests/run-tests.sh --auto
```

Build、ZIP、DMG 和 artifact 文件名必须全部为 Gemini2API 新名称。
删除 workflow 中自动创建 Release 的 step，Release 由 Task 11 在用户确认后
一次性创建，避免 tag workflow 与 `gh release create` 竞争。

- [ ] **Step 5: 运行完整测试并提交**

```bash
bash Tests/run-tests.sh --auto
git diff --check
rg -n "^# Gemini2API 0\.1\.0$" README.md
git add Tests/HTTPServerIntegrationTests.swift Tests/run-tests.sh \
  README.md .github/workflows/build.yml
git diff --cached --check
git commit -m "docs: document Gemini2API 0.1.0 compatibility"
```

Expected: 所有测试通过，README 版本断言命中一行。

---

### Task 10: 构建、真实上游与官方 SDK smoke test

**Files:**

- Verify: `Gemini2API.app`
- Verify: `Gemini2API.dmg`
- Verify: `Gemini2API-macOS.zip`
- Create: `Tests/real-upstream-smoke.swift`
- Create: `Tests/sdk-smoke-server.swift`
- Create: `Tests/sdk-smoke.py`
- Create: `Tests/gemini-sdk-smoke.mjs`
- No project dependency files may be created.

**Interfaces:**

- Consumes: Task 9 的完成分支。
- Produces: 本地构建证据、真实 Gemini Web 证据和三种官方 SDK 证据。

- [ ] **Step 1: 运行静态、测试与构建 gate**

```bash
bash Tests/run-tests.sh --auto
git diff --check
./build.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' \
  Gemini2API.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  Gemini2API.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  Gemini2API.app/Contents/Info.plist
```

Expected: `Gemini2API`、`com.gemini2api.gateway`、`0.1.0`。

- [ ] **Step 2: 构建 Release 附件**

```bash
ditto -c -k --keepParent Gemini2API.app Gemini2API-macOS.zip
./make-dmg.sh
test -s Gemini2API-macOS.zip
test -s Gemini2API.dmg
```

Expected: 两个附件存在且非空。若 `create-dmg` 不存在，先报告版本检查；
只有用户已经批准的临时验收依赖可以安装。

- [ ] **Step 3: 运行真实 Gemini Web smoke test**

创建 `Tests/real-upstream-smoke.swift`。它使用随机端口启动
`HTTPServer(generator: Engine.shared, config: store)`，等待 `GET /` 返回
200，然后向 `/v1/responses` 发送以下 body：

```json
{
  "model": "gemini-3.8-flash",
  "input": "Reply with exactly: Gemini2API upstream ok",
  "store": false
}
```

解析 response object，并断言第一个 `output_text.text` 非空且包含
`Gemini2API upstream ok`。失败时只打印 HTTP status 和脱敏错误，不输出
Cookie、API Key 或原始上游 payload。

Compile and run:

```bash
SMOKE_BIN_DIR="$(mktemp -d)"
swiftc \
  Sources/AnthropicProtocol.swift \
  Sources/Config.swift \
  Sources/Engine.swift \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/Models.swift \
  Sources/Prompt.swift \
  Sources/ToolCalling.swift \
  Sources/Util.swift \
  Sources/gateway-protocol.swift \
  Sources/gateway-pipeline.swift \
  Sources/http-server-responses.swift \
  Sources/http-server-gemini.swift \
  Tests/real-upstream-smoke.swift \
  -framework Network -framework CryptoKit \
  -o "$SMOKE_BIN_DIR/real-upstream-smoke"
"$SMOKE_BIN_DIR/real-upstream-smoke"
```

- [ ] **Step 4: 创建隔离 SDK 环境并记录版本**

```bash
SDK_ENV_DIR="$(mktemp -d)"
python3 -m venv "$SDK_ENV_DIR"
"$SDK_ENV_DIR/bin/python" -m pip install --upgrade openai anthropic
SDK_NODE_DIR="$(mktemp -d)"
npm install --prefix "$SDK_NODE_DIR" @google/genai
"$SDK_ENV_DIR/bin/python" - <<'PY'
from importlib.metadata import version
for package in ("openai", "anthropic"):
    print(f"{package}={version(package)}")
PY
npm list --prefix "$SDK_NODE_DIR" @google/genai
```

不得生成 `requirements.txt`、lockfile 或项目虚拟环境。

- [ ] **Step 5: 用三个官方 SDK 调用本地 fake-server acceptance**

创建 `Tests/sdk-smoke-server.swift`，其 fake generator 对文本请求返回
`Gemini2API SDK ok`，对活动工具请求返回一个合法 `Read` tool_call。
端口从 `GEMINI2API_SMOKE_PORT` 读取，启动成功后持续服务，收到 TERM 后退出。

创建 `Tests/sdk-smoke.py`：

```python
"""使用 OpenAI 和 Anthropic 官方 SDK 验证 Gemini2API。"""

import os

from anthropic import Anthropic
from openai import OpenAI

base_url = os.environ["GEMINI2API_BASE_URL"]
openai_client = OpenAI(api_key="test-key", base_url=f"{base_url}/v1")
anthropic_client = Anthropic(api_key="test-key", base_url=base_url)

models = list(openai_client.models.list())
assert models and models[0].id

chat = openai_client.chat.completions.create(
    model="gemini-3.8-flash",
    messages=[{"role": "user", "content": "Say SDK ok"}],
)
assert chat.choices[0].message.content

response = openai_client.responses.create(
    model="gemini-3.8-flash",
    input="Say SDK ok",
    store=False,
)
assert response.output_text

stream_text = "".join(
    event.delta
    for event in openai_client.responses.create(
        model="gemini-3.8-flash",
        input="Say SDK ok",
        store=False,
        stream=True,
    )
    if event.type == "response.output_text.delta"
)
assert stream_text

message = anthropic_client.messages.create(
    model="gemini-3.8-flash",
    max_tokens=128,
    messages=[{"role": "user", "content": "Say SDK ok"}],
)
assert message.content[0].text

count = anthropic_client.messages.count_tokens(
    model="gemini-3.8-flash",
    messages=[{"role": "user", "content": "Count this"}],
)
assert count.input_tokens > 0

with anthropic_client.messages.stream(
    model="gemini-3.8-flash",
    max_tokens=128,
    messages=[{"role": "user", "content": "Say SDK ok"}],
) as stream:
    assert "".join(stream.text_stream)
```

创建 `Tests/gemini-sdk-smoke.mjs`，使用：

```javascript
import {GoogleGenAI} from "@google/genai";

const base_url = process.env.GEMINI2API_BASE_URL;
const client = new GoogleGenAI({
  apiKey: "test-key",
  httpOptions: {
    baseUrl: base_url,
    headers: {"x-goog-api-key": "test-key"},
  },
});

const response = await client.models.generateContent({
  model: "gemini-3.8-flash",
  contents: "Say SDK ok",
});
if (!response.text) throw new Error("empty Gemini SDK response");

let stream_text = "";
const stream = await client.models.generateContentStream({
  model: "gemini-3.8-flash",
  contents: "Say SDK ok",
});
for await (const chunk of stream) stream_text += chunk.text ?? "";
if (!stream_text) throw new Error("empty Gemini SDK stream");
```

脚本调用 `client.models.generateContent()` 和
`client.models.generateContentStream()`，并断言响应文本为非空。

编译并后台启动 fake server，等待 readiness 后运行两个 smoke 文件。每项都必须
被 SDK 解码。Google Python SDK 的自定义 Base URL 当前只支持 enterprise 模式，
因此 Gemini smoke 明确使用支持 `httpOptions.baseUrl` 的官方 Node SDK。

- [ ] **Step 6: 回收临时环境并核验 worktree**

使用 Finder/系统废纸篓能力把 `$SDK_ENV_DIR`、`$SDK_NODE_DIR` 和所有 smoke
binary 目录移入废纸篓，不执行永久删除。

```bash
git status --short --branch
git diff --check
```

Expected: 只剩预期源码、测试、README 和文档变更；构建产物被 `.gitignore`
排除。

- [ ] **Step 7: 提交可重复 smoke test**

```bash
git add Tests/real-upstream-smoke.swift Tests/sdk-smoke-server.swift \
  Tests/sdk-smoke.py Tests/gemini-sdk-smoke.mjs
git diff --cached --check
git commit -m "test: add upstream and official SDK smoke checks"
```

---

### Task 11: 推送、PR、确认门禁、merge 与 v0.1.0 Release

**Files:**

- Verify: Git history and GitHub state only.

**Interfaces:**

- Consumes: Task 10 的本地验证证据和构建附件。
- Produces: feature branch、PR、用户确认后的 main merge 与 `v0.1.0` Release。

- [ ] **Step 1: 最终本地验证并推送 branch**

```bash
bash Tests/run-tests.sh --auto
git diff --check
git status --short --branch
git push origin feat/api-gateway
```

确认 `git ls-remote origin refs/heads/feat/api-gateway` 与 `git rev-parse HEAD`
完全相同。

- [ ] **Step 2: 创建 PR**

```bash
PR_BODY=$'## 最终行为\n'
PR_BODY+=$'- 提供七个兼容 endpoint。\n'
PR_BODY+=$'- 产品重命名为 Gemini2API。\n\n'
PR_BODY+=$'## 验证\n'
PR_BODY+=$'- 完整 Swift 测试与通用构建。\n'
PR_BODY+=$'- 真实上游与三个官方 SDK smoke test。\n\n'
PR_BODY+=$'## 已知限制\n'
PR_BODY+=$'- 多模态、托管工具和服务端状态明确返回 unsupported。'
gh pr create \
  -R 4she2run2024/gemini-api \
  --base main \
  --head feat/api-gateway \
  --title "feat: release Gemini2API 0.1.0" \
  --body "$PR_BODY"
```

PR body 只包含最终行为、测试证据和已知限制；不得记录中间试错叙述。

- [ ] **Step 3: 回查 PR 并暂停请求确认**

```bash
PR_NUMBER="$(gh pr view feat/api-gateway \
  -R 4she2run2024/gemini-api --json number --jq .number)"
gh pr view "$PR_NUMBER" -R 4she2run2024/gemini-api \
  --json number,state,headRefName,headRefOid,baseRefName,mergeable,url
```

必须报告准确 PR 编号、head SHA、base 和 mergeable。回复最后一行必须为：

将 `$PR_NUMBER` 的实际十进制值写入固定句式，并在发送前检查句中已经是
数字，不得保留变量名或占位符。

在用户确认前不得执行后续步骤。

- [ ] **Step 4: 用户确认后重新检查 tag、Release 和 PR head**

```bash
PR_NUMBER="$(gh pr view feat/api-gateway \
  -R 4she2run2024/gemini-api --json number --jq .number)"
PR_HEAD="$(gh pr view "$PR_NUMBER" -R 4she2run2024/gemini-api \
  --json headRefOid --jq .headRefOid)"
gh pr view "$PR_NUMBER" -R 4she2run2024/gemini-api \
  --json state,mergeable,headRefOid,baseRefName
test -z "$(git ls-remote --tags origin refs/tags/v0.1.0)"
if gh release view v0.1.0 -R 4she2run2024/gemini-api >/dev/null 2>&1; then
  exit 1
fi
```

PR 必须是 OPEN、base 为 main、head 未移动且 mergeable；tag 与 Release 必须
不存在。任一条件变化就停止并报告。

- [ ] **Step 5: merge 并回查 main**

```bash
gh pr merge "$PR_NUMBER" \
  -R 4she2run2024/gemini-api \
  --merge \
  --match-head-commit "$PR_HEAD"
MERGE_SHA="$(gh pr view "$PR_NUMBER" -R 4she2run2024/gemini-api \
  --json mergeCommit --jq .mergeCommit.oid)"
REMOTE_MAIN="$(git ls-remote origin refs/heads/main | cut -f1)"
test "$MERGE_SHA" = "$REMOTE_MAIN"
```

- [ ] **Step 6: 创建 Release 并上传附件**

```bash
gh release create v0.1.0 \
  Gemini2API-macOS.zip \
  Gemini2API.dmg \
  -R 4she2run2024/gemini-api \
  --target "$MERGE_SHA" \
  --title "Gemini2API v0.1.0" \
  --generate-notes
```

- [ ] **Step 7: 独立核验 main、tag、Release 和附件**

```bash
gh api repos/4she2run2024/gemini-api/git/ref/tags/v0.1.0
gh release view v0.1.0 -R 4she2run2024/gemini-api \
  --json tagName,targetCommitish,isDraft,isPrerelease,url,assets
git ls-remote origin refs/heads/main refs/tags/v0.1.0
```

最终报告必须分别说明：测试、build、真实上游、三个 SDK、PR、merge、tag、
Release 和两个附件。任何未验证项必须标记为未验证或失败。
