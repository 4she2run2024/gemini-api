# Gemini2API API Gateway 设计说明

## 1. 项目目标

Gemini2API 是一个运行在 macOS 菜单栏中的本地 API Gateway。它继续使用现有
Gemini Web 生成核心，同时向本地客户端提供 OpenAI、Anthropic 和 Gemini 三类
兼容接口。

`v0.1.0` 必须提供以下七个 endpoint：

1. `GET /v1/models`
2. `POST /v1/chat/completions`
3. `POST /v1/responses`
4. `POST /v1/messages`
5. `POST /v1/messages/count_tokens`
6. `POST /v1beta/models/{model}:generateContent`
7. `POST /v1beta/models/{model}:streamGenerateContent`

目标客户端包括 OpenAI SDK、Codex、Claude Code、Anthropic SDK、Gemini SDK，以及
其他允许配置 Base URL 的程序。

## 2. 设计原则

- 不重写 `Engine` 中的 Gemini Web 请求、流式解析、重试和 Cookie 逻辑。
- 所有协议通过统一的请求和结果模型进入同一个生成管线。
- 不把无法实现的能力伪装成成功；不支持的输入必须返回明确错误。
- 不引入新的项目运行时依赖。
- 保留现有 OpenAI Chat 和 Anthropic Messages 的可用行为及工具调用能力。
- Swift 文件、函数和协议保持单一职责，避免在路由文件中重复 prompt 逻辑。
- 代码、文档和注释使用中文说明，标识符遵循项目命名规范。
- 文件系统路径从系统 API 或脚本所在目录动态生成，不硬编码用户绝对
  路径。

## 3. v0.1.0 范围

### 3.1 支持的能力

- 文本输入与输出。
- system、developer、user、assistant 等角色映射。
- 多轮对话。
- OpenAI、Anthropic 和 Gemini 的本地 function calling。
- function call 结果续轮。
- 非流式响应。
- 文本 SSE 增量响应。
- 工具调用的协议合法流式事件。
- 请求和响应 token 的近似统计。
- Bearer、`x-api-key`、`x-goog-api-key` 和 `key` query 参数鉴权。

### 3.2 明确不支持的能力

以下能力返回对应协议格式的 `400` 错误，不静默忽略：

- 图片、音频、视频、PDF、文件 URL 和内联二进制输入。
- OpenAI 内置 web search、file search、computer use、code interpreter 等托管工具。
- Gemini Google Search、code execution、file search、URL context 等托管工具。
- 后台 Responses 任务。
- 服务端持久 conversation state。
- 依赖服务端保存内容的 `previous_response_id`、`conversation` 或 `store: true`。

`temperature`、`top_p`、`max_tokens`、`max_output_tokens` 和 `stop` 等生成控制参数
允许 SDK 发送，但 Gemini Web 后端不保证严格执行。README 必须在兼容
矩阵中标记这类参数为“接受但不保证生效”。

## 4. 产品身份

- 产品显示名：`Gemini2API`
- App 名：`Gemini2API.app`
- Bundle ID：`com.gemini2api.gateway`
- DMG：`Gemini2API.dmg`
- ZIP：`Gemini2API-macOS.zip`
- GitHub 仓库：`4she2run2024/gemini-api`
- 版本：`0.1.0`
- Release tag：`v0.1.0`

菜单、设置窗口、About 面板、构建脚本、DMG、CI artifact 和 README 统一使用
`Gemini2API`。About 链接指向新仓库。

## 5. 配置迁移

新配置目录由 `FileManager.default.homeDirectoryForCurrentUser` 动态生成，逻辑路径为
`.config/gemini2api/config.json`。

启动时采用以下顺序：

1. 新配置存在时直接读取新配置。
2. 新配置不存在而旧的 `.config/gemini-web2api/config.json` 存在时，
   读取旧配置并写入新配置。
3. 两者都不存在时使用默认配置。
4. 后续保存只写新配置。
5. 不修改或删除旧配置，使 Gemini Free 可以继续独立使用。

迁移失败不能崩溃。应用保留默认配置，并向标准错误输出一条不包含
Cookie、API Key 或其他敏感值的错误说明。

## 6. 总体架构

```text
HTTP 路由与鉴权
        |
        v
协议请求适配器
        |
        v
GatewayRequest + GatewayToolPolicy
        |
        v
GatewayPipeline
        |
        v
现有 TextGenerating / Engine
        |
        v
GatewayResult
        |
        v
协议响应编码器与 SSE 事件
```

### 6.1 HTTP 层

`HTTPServer.swift` 只负责：

- 读取 HTTP request line、headers 和 body。
- CORS 与 OPTIONS。
- API Key 鉴权。
- 静态路由和 Gemini 动态模型路由匹配。
- JSON、SSE 和 HTTP status 写出。

动态 Gemini 路径必须严格匹配：

- `/v1beta/models/{model}:generateContent`
- `/v1beta/models/{model}:streamGenerateContent`

模型不能为空，路径尾部不能包含额外 segment。query 参数不参与路由
匹配，但参与鉴权和 `alt=sse` 兼容判断。

### 6.2 统一协议模型

新增 `GatewayProtocol.swift`，至少定义以下职责明确的类型：

- `GatewayRole`：system、developer、user、assistant、tool。
- `GatewayContent`：文本、工具调用、工具结果；媒体类型在解析阶段转为
  unsupported 错误。
- `GatewayMessage`：角色与 content 列表。
- `GatewayTool`：名称、说明和 JSON Schema 参数。
- `GatewayToolChoice`：auto、none、required、指定工具。
- `GatewayRequest`：模型、消息、工具、工具策略和 stream 标记。
- `GatewayResult`：模型、文本、工具调用、输入/输出 token 和结束原因。
- `GatewayProtocolError`：非法请求、unsupported、上游失败和工具协议失败。

这些类型只表达 Gemini Web 核心能够消费或产生的语义，不包含某个外部
协议专属字段。

### 6.3 统一生成管线

新增 `GatewayPipeline.swift`：

1. 把 `GatewayRequest` 转成结构化单条 prompt。
2. 复用现有本地工具提示词格式和 `ToolCallPolicy`。
3. 解析模型生成的 `tool_call` 或 `function_call` block。
4. 校验模型只能调用请求声明的工具。
5. 返回 `GatewayResult`。
6. 无活动工具时使用 `generateStream` 输出文本 delta。
7. 有活动工具时先完整生成并校验，再由协议编码器输出工具事件。

现有 `messagesToPrompt`、Anthropic prompt 和工具辅助函数应迁移为共享
构件，但不得改变已经通过测试的角色和工具续轮语义。

## 7. Endpoint 契约

### 7.1 `GET /v1/models`

返回 OpenAI list object。每个模型包含稳定的 `id`、`object`、`created`、`owned_by`
和说明。列表来自现有 `MODELS`，不复制第二份模型表。

### 7.2 `POST /v1/chat/completions`

保留当前 OpenAI Chat 行为，并改为通过 `GatewayPipeline` 执行。支持：

- string content 和文本 content part。
- system、developer、user、assistant、tool。
- OpenAI function tool 定义。
- `tool_choice` 的 none、auto、required 和指定函数。
- 普通文本实时 SSE。
- 工具调用在完整解析后返回合法 `tool_calls`。

### 7.3 `POST /v1/responses`

支持以下输入：

- `instructions` 字符串。
- `input` 字符串。
- message item array 中的 `input_text`。
- assistant message 与 `output_text`。
- `function_call` 和 `function_call_output` 续轮。
- `type: function` 的本地工具声明。
- `tool_choice` 的 none、auto、required 和指定函数。
- `stream: true`。
- `store: false` 或省略 `store`。

非流式响应至少包含稳定的 `id`、`object`、`created_at`、`status`、
`model`、`output`、`usage`、`tools`、`tool_choice` 和错误相关字段。
文本使用 message item 加 `output_text`；工具调用使用独立
`function_call` item。

文本流依次产生创建、output item、content part、text delta、text done、
item done 和完成事件。工具流在完整解析后产生 function-call arguments
相关事件。事件必须携带单调递增的 `sequence_number`，最终
`response.completed` 包含完整 Response object。

### 7.4 `POST /v1/messages`

保留当前 Anthropic Messages 与 Claude Code 行为，并通过共享管线执行。
支持 system、text、tool_use、tool_result、工具选择、非流式 Message
object 与 Anthropic SSE 事件序列。

### 7.5 `POST /v1/messages/count_tokens`

使用与 `/v1/messages` 相同的输入规范化和 prompt 构建逻辑，返回
`{"input_tokens": number}`。计数继续使用明确标注的近似算法。

### 7.6 `POST /v1beta/models/{model}:generateContent`

支持：

- `contents` 中的 user 和 model 角色。
- text part。
- `systemInstruction` 的 text part。
- `tools[].functionDeclarations`。
- `toolConfig.functionCallingConfig` 的 AUTO、NONE、ANY 和允许函数列表。
- `functionCall` 与 `functionResponse` 续轮。

文本响应使用 `candidates[].content.parts[].text`；工具响应使用
`candidates[].content.parts[].functionCall`。响应包含 `finishReason`、`index`、
`usageMetadata`、`modelVersion` 和 `responseId`。

### 7.7 `POST /v1beta/models/{model}:streamGenerateContent`

请求解析与非流式 Gemini endpoint 相同。文本通过 SSE 输出，每个 chunk 使用
`data: <GenerateContentResponse>`。工具调用完整解析后作为一个合法 Gemini response
chunk 输出。Gemini SSE 不追加 OpenAI 的 `[DONE]` 标记。

## 8. 鉴权

配置中没有 API Key 时保持免密。配置了 Key 后接受：

- `Authorization: Bearer <key>`
- `x-api-key: <key>`
- `x-goog-api-key: <key>`
- query 中的 `key=<key>`

所有 `/v1` 和 `/v1beta` endpoint 使用同一个 Key 集合。鉴权失败返回
`401`，且响应体采用请求协议的错误 envelope；无法确定协议时使用通用
JSON 错误。

## 9. 错误语义

- `400`：JSON、路径模型、消息、工具或工具选择非法；能力不支持；请求
  服务端状态。
- `401`：API Key 无效。
- `404`：endpoint 不存在。
- `502`：Gemini Web 上游错误；模型工具 block 畸形；调用未声明工具。

OpenAI 使用 `error` object；Anthropic 使用 `type: error` 和嵌套 error object；Gemini
使用包含 HTTP code、status 和 message 的 error object。错误消息不能包含 Cookie、
API Key、原始鉴权 header 或完整上游 payload。

流式请求在 SSE header 写出前发生的错误使用普通 JSON status。header
已写出后发生的上游错误使用协议内错误事件，并正常关闭连接，不能把
错误文本伪装成 assistant 输出。

## 10. 文件规划

新增：

- `Sources/GatewayProtocol.swift`
- `Sources/GatewayPipeline.swift`
- `Sources/HTTPServer+Responses.swift`
- `Sources/HTTPServer+Gemini.swift`
- `Tests/GatewayProtocolTests.swift`
- `Tests/ResponsesProtocolTests.swift`
- `Tests/GeminiProtocolTests.swift`

修改：

- `Sources/HTTPServer.swift`
- `Sources/HTTPServer+OpenAI.swift`
- `Sources/HTTPServer+Anthropic.swift`
- `Sources/AnthropicProtocol.swift`
- `Sources/Prompt.swift`
- `Sources/ToolCalling.swift`
- `Sources/AppDelegate.swift`
- `Sources/SettingsWindow.swift`
- `Sources/Config.swift`
- `build.sh`
- `make-dmg.sh`
- `.github/workflows/build.yml`
- `.gitignore`
- `README.md`

如果实现过程中证明现有职责无需修改，不为满足清单而制造无意义 diff。
不得改写 `Sources/Engine.swift` 的 Gemini Web 协议行为。

## 11. 测试设计

### 11.1 单元测试

覆盖：

- 三类协议的角色和文本映射。
- system instructions。
- 工具定义、工具选择、工具调用和工具结果。
- unsupported 媒体和托管工具。
- 模型路径解析。
- 响应字段和结束原因。
- token usage。
- 配置迁移且旧文件保持不变。

所有生产逻辑必须先有失败测试，再进行最小实现。

### 11.2 SSE 契约测试

验证：

- OpenAI Chat `[DONE]`。
- OpenAI Responses 事件顺序、ID 一致性和递增 `sequence_number`。
- Anthropic message_start 到 message_stop。
- Gemini `data:` chunk、文本拼接和无 `[DONE]`。
- 工具事件只能引用实际声明的工具。
- 流式错误不会伪装成 assistant 文本。

### 11.3 HTTP 集成测试

使用随机本地端口和 fake generator，覆盖七个 endpoint，并验证：

- 非流式文本。
- 流式文本。
- function calling。
- function result 续轮。
- `400`、`401`、`404` 和 `502`。
- query string 路由与鉴权。

### 11.4 构建与真实验收

- 运行全部 Swift 测试。
- 运行 `./build.sh` 并核验 App 名、Bundle ID 和版本。
- 运行 `git diff --check`。
- 启动隔离端口，使用真实 Gemini Web 完成最小文本 smoke test。
- 在临时隔离环境安装稳定版 OpenAI、Anthropic 和 Google SDK。
- 分别使用自定义 Base URL 调用对应 endpoint。
- 临时环境不写入项目依赖，验收后移入废纸篓。

如果网络、Gemini Web 协议或第三方 SDK 阻止真实验收，必须报告具体失败
证据，不能用 fake generator 测试代替并宣称真实 SDK 验收成功。

## 12. README 与 Release

README 标题为 `# Gemini2API 0.1.0`，使用中文并包含：

- 项目说明。
- 功能特性。
- 兼容矩阵。
- 前置要求。
- 安装方法。
- 七个 endpoint 的使用示例。
- OpenAI SDK、Codex、Claude Code、Anthropic SDK 和 Gemini SDK 配置示例。
- 配置说明与迁移行为。
- 已知限制。
- 常见问题。
- 更新历史。

完成实现和验证后：

1. commit 并推送 `feat/api-gateway`。
2. 创建以 `main` 为 base 的 pull request。
3. 回查 PR head、base 和 mergeability。
4. 报告 PR 编号并请求 merge 与 Release 确认。
5. 获得确认后 merge。
6. 基于准确的 main merge commit 创建 `v0.1.0` Release。
7. 回查 main、tag、Release 和附件指向同一交付版本。

PR、merge、Release 和附件发布必须作为可区分的状态报告，不能因为其中
一个完成而推断其他步骤完成。
