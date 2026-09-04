# Gemini2API 0.2.0

<p align="center">
  <img src="logo.png" width="200" alt="Gemini2API">
</p>

## 项目说明

Gemini2API 是一个 macOS 本地 API Gateway。它可以通过菜单栏 App 或独立的
headless CLI 运行，复用 Gemini 网页端生成核心，向允许配置 Base URL 的客户端
提供 OpenAI、Anthropic 和 Gemini 风格的文本接口。

本项目不是 Google、OpenAI 或 Anthropic 的官方服务。协议兼容只覆盖下文列出的
能力；客户端名称或配置示例不代表该客户端的全部功能均受支持。

## 功能特性

- 提供 OpenAI Models、Chat Completions 与 Responses 接口。
- 提供 Anthropic Messages 与 token count 接口。
- 提供 Gemini GenerateContent 与流式 GenerateContent 接口。
- 支持文本、多轮角色、本地 function calling 和工具结果续轮。
- 支持非流式 JSON 与协议对应的 SSE 文本增量。
- 支持 CLI 前台服务和退出终端后继续运行的当前用户 daemon。
- 支持查询 daemon 状态，并在完整验证进程身份后安全停止托管实例。
- 使用 Bearer、`x-api-key`、`x-goog-api-key` 或 `key` query 参数鉴权。
- 保留旧 Gemini Free 配置，并一次性迁移到 Gemini2API 的独立配置目录。
- 以 Swift 构建 Intel 与 Apple 芯片通用 App 和 CLI，不增加运行时依赖。

## API 与兼容矩阵

默认绑定地址为 `0.0.0.0:8081`；本机客户端通过 `http://127.0.0.1:8081` 访问。
OpenAI 客户端的 Base URL 通常需要
追加 `/v1`。

| Endpoint | 协议 | v0.2.0 状态 | 关键输出 |
| --- | --- | --- | --- |
| `GET /v1/models` | OpenAI | 支持 | `object: list` |
| `POST /v1/chat/completions` | OpenAI | 支持 | `chat.completion` 或 SSE |
| `POST /v1/responses` | OpenAI | 支持 | Response object 或 Responses SSE |
| `POST /v1/messages` | Anthropic | 支持 | Message object 或 Anthropic SSE |
| `POST /v1/messages/count_tokens` | Anthropic | 支持 | 近似 `input_tokens` |
| `POST /v1beta/models/{model}:generateContent` | Gemini | 支持 | `candidates` |
| `POST /v1beta/models/{model}:streamGenerateContent` | Gemini | 支持 | `data:` SSE |

| 能力类别 | 状态 | 说明 |
| --- | --- | --- |
| 文本、system/developer/user/assistant、多轮对话 | 支持 | 转换到共享生成管线 |
| 本地 function calling、工具结果续轮 | 支持 | 仅能调用请求中声明的工具 |
| 非流式 JSON、文本 SSE、工具事件 | 支持 | Gemini SSE 不发送 `[DONE]` |
| Bearer、`x-api-key`、`x-goog-api-key`、`key` query | 支持 | 共用设置中的 Key 集合 |
| 生成控制参数 | 接受但不保证生效 | 网页后端可能忽略 |
| 媒体、文件与二进制 | 明确不支持 | 返回 `400` |
| 托管工具 | 明确不支持 | 仅支持本地函数 |
| Responses 服务端状态 | 明确不支持 | `store: true` 等返回 `400` |

## 前置要求

| 场景 | 最低要求 | 安装或检查命令 |
| --- | --- | --- |
| 运行 App 或 CLI | macOS 13.0+ | `sw_vers -productVersion` |
| 源码构建与测试 | Swift 6.0+ 的 Xcode Command Line Tools | `xcode-select --install` |
| 制作 DMG | `create-dmg` 1.3.0+ | `brew install create-dmg` |

`create-dmg` 只用于生成 DMG，不是 App 的运行时依赖。OpenAI、Anthropic 和
Gemini SDK 也只是后文示例的可选客户端依赖，不会写入本项目。
0.2.0 没有新增 runtime dependency；独立 CLI 不链接 AppKit。

## 安装方法

从 [Releases](../../releases/latest) 下载 App 附件 `Gemini2API.dmg` 或
`Gemini2API-macOS.zip`。DMG 安装方式是把 `Gemini2API.app` 拖入 Applications。

如需独立 CLI，请下载 `gemini2api-macOS`。以下示例动态使用当前用户目录；
如果目标已经存在，只提示用户处理，不会覆盖原文件：

```bash
download_path="./gemini2api-macOS"
bin_dir="${HOME}/.local/bin"
target_path="${bin_dir}/gemini2api"

mkdir -p "$bin_dir"
if [[ -e "$target_path" || -L "$target_path" ]]; then
  printf '目标已存在，请先备份或移动：%s\n' "$target_path" >&2
else
  install -m 0755 "$download_path" "$target_path"
fi

export PATH="$bin_dir:$PATH"
gemini2api --version
```

要让后续终端也能找到 CLI，请把 `bin_dir` 对应目录加入 shell 的 `PATH` 配置。

从源码构建：

```bash
repo_dir="gemini-api"
git clone https://github.com/4she2run2024/gemini-api.git "$repo_dir"
cd "$repo_dir"
./build.sh
open Gemini2API.app
./gemini2api-macOS --version
```

## 使用方法

启动 `Gemini2API.app` 后，通过菜单栏的“设置”确认端口、监听地址与
API Key。App 用户可以继续只使用菜单栏入口；CLI 是可选入口。

### CLI 命令

```text
gemini2api serve [--host HOST] [--port PORT] [--model MODEL]
gemini2api serve [--host HOST] [--port PORT] [--model MODEL] --daemon
gemini2api status [--json]
gemini2api stop [--timeout SECONDS]
gemini2api --version
gemini2api --help
```

`serve` 默认在当前终端前台运行；`serve --daemon` 启动当前用户的托管 daemon。
daemon 会在终端关闭后继续运行，但注销或重启后停止，本版本不会安装
LaunchAgent 或系统 LaunchDaemon。CLI 不需要交互式问答，例如：

```bash
# 前台运行；按 Ctrl-C 或发送 SIGTERM 停止
gemini2api serve --host 127.0.0.1 --port 8081 \
  --model gemini-3.6-flash

# 或启动 daemon，查询状态后安全停止；stop 默认等待 10 秒
gemini2api serve --daemon
gemini2api status --json
gemini2api stop --timeout 10
```

`status --json` 输出固定字段；无值字段编码为 `null`，`state` 只会是
`running`、`unhealthy`、`stopped`、`unmanaged` 或 `conflict`：

```json
{
  "healthy": true,
  "host": "127.0.0.1",
  "managed": true,
  "pid": 12345,
  "port": 8081,
  "state": "running",
  "version": "0.2.0"
}
```

CLI 使用以下稳定退出码：

| 退出码 | 含义 |
| --- | --- |
| `0` | 命令成功，或 `status` 确认托管 daemon 健康 |
| `2` | 命令、参数或配置错误 |
| `3` | daemon 未运行，或进程存在但 HTTP 健康检查失败 |
| `4` | PID 身份不匹配，或端口、实例所有权冲突 |
| `5` | HTTP listener、daemon 化、状态发布或停止等待失败 |

### HTTP 请求

以下七个示例在未配置 API Key 时可以直接运行；如已配置 Key，请增加
`Authorization: Bearer <key>` 或对应协议支持的其他鉴权方式。

```bash
base_url="http://127.0.0.1:8081"

# 1. GET /v1/models
curl "$base_url/v1/models"

# 2. POST /v1/chat/completions
curl "$base_url/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.8-flash","messages":[{"role":"user","content":"你好"}]}'

# 3. POST /v1/responses
curl "$base_url/v1/responses" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.8-flash","input":"你好","store":false}'

# 4. POST /v1/messages
curl "$base_url/v1/messages" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"gemini-3.8-flash","max_tokens":256,"messages":[{"role":"user","content":"你好"}]}'

# 5. POST /v1/messages/count_tokens
curl "$base_url/v1/messages/count_tokens" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.8-flash","messages":[{"role":"user","content":"你好"}]}'

# 6. POST /v1beta/models/{model}:generateContent
curl "$base_url/v1beta/models/gemini-3.8-flash:generateContent" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"你好"}]}]}'

# 7. POST /v1beta/models/{model}:streamGenerateContent
curl -N "$base_url/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"你好"}]}]}'
```

## CLI 服务客户端示例

先运行 `gemini2api serve` 或 `gemini2api serve --daemon`，再使用以下 Base URL
把 Codex、Claude Code、OpenAI SDK、Anthropic SDK 或 Gemini SDK 指向 CLI 服务。
当前协议已经通过真实 Gemini Web 上游 smoke，
并在隔离环境中通过 OpenAI Python SDK 3.8.0、Anthropic Python SDK 1.3.0 和
Google Gen AI Node SDK 2.21.0 的文本、流式与本地 function calling smoke。
这仍不代表客户端全部能力均受支持；升级 SDK 后应重新执行验收。
安装客户端依赖时，应使用隔离环境和当前稳定版：

```bash
sdk_env_dir="$(mktemp -d)"
python3 -m venv "$sdk_env_dir"
"$sdk_env_dir/bin/python" -m pip install --upgrade openai anthropic
sdk_node_dir="$(mktemp -d)"
npm install --prefix "$sdk_node_dir" @google/genai
```

### OpenAI SDK

OpenAI Python SDK 当前要求 Python 3.10+。`base_url` 必须包含 `/v1`：

```python
import os
from openai import OpenAI

client = OpenAI(
    api_key=os.environ.get("GEMINI2API_API_KEY", "local-placeholder"),
    base_url="http://127.0.0.1:8081/v1",
)
response = client.responses.create(
    model="gemini-3.8-flash",
    input="只回复 Gemini2API ok",
    store=False,
)
print(response.output_text)
```

### Codex

在用户级 `~/.codex/config.toml` 中增加自定义 Responses provider：

```toml
model = "gemini-3.8-flash"
model_provider = "gemini2api"

[model_providers.gemini2api]
name = "Gemini2API"
base_url = "http://127.0.0.1:8081/v1"
env_key = "GEMINI2API_API_KEY"
wire_api = "responses"
requires_openai_auth = false
```

启动前设置环境变量。服务未配置 Key 时，也要给需要 token 的客户端一个
非空占位值：

```bash
export GEMINI2API_API_KEY="local-placeholder"
codex
```

Codex 的托管 web search、后台任务和服务端 conversation state 不在兼容范围内。

### Claude Code

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:8081"
export ANTHROPIC_AUTH_TOKEN="${GEMINI2API_API_KEY:-local-placeholder}"
export ANTHROPIC_MODEL="gemini-3.8-flash"
export ANTHROPIC_DEFAULT_MODEL="gemini-3.8-flash"
claude
```

可在 Claude Code 的 `/status` 中确认 Anthropic Base URL 是否指向本机。

### Anthropic SDK

```python
import os
from anthropic import Anthropic

client = Anthropic(
    api_key=os.environ.get("GEMINI2API_API_KEY", "local-placeholder"),
    base_url="http://127.0.0.1:8081",
)
message = client.messages.create(
    model="gemini-3.8-flash",
    max_tokens=256,
    messages=[{"role": "user", "content": "只回复 Gemini2API ok"}],
)
print(message.content[0].text)
```

### Gemini SDK

下面使用 Google Gen AI JavaScript SDK 的 `httpOptions.baseUrl`：

```javascript
import {GoogleGenAI} from "@google/genai";

const client = new GoogleGenAI({
  apiKey: process.env.GEMINI2API_API_KEY ?? "local-placeholder",
  httpOptions: {
    baseUrl: "http://127.0.0.1:8081",
    headers: {"x-goog-api-key": process.env.GEMINI2API_API_KEY ?? "local-placeholder"},
  },
});
const response = await client.models.generateContent({
  model: "gemini-3.8-flash",
  contents: "只回复 Gemini2API ok",
});
console.log(response.text);
```

## 配置说明与旧配置迁移

CLI 的配置优先级为：

```text
CLI 本次参数 > ~/.config/gemini2api/config.json > Store 声明默认值
```

只有 `--host`、`--port` 和 `--model` 会覆盖本次运行的内存值；CLI 不会把覆盖值
写回配置。`--port` 只接受 `1...65535`，`--model` 只接受现有模型，可选的
`@think=N` 中 `N` 必须为 `0...4`。Cookie、代理、`auth_user`、`xsrf_token` 和
Gateway API Key 不提供 CLI 参数，仍由 App 或配置文件管理。

新配置逻辑路径为 `~/.config/gemini2api/config.json`。首次启动时按以下
顺序处理：

1. 新配置存在时直接读取。
2. 新配置缺失、旧 `~/.config/gemini-web2api/config.json` 存在时，校验并复制。
3. 两者都不存在时使用默认配置。
4. 后续保存只写新配置；旧配置不会被修改或删除。
5. 迁移失败时保留默认值，只向标准错误写出不含凭据和真实路径的
   错误类别。

以下是限制为本机访问的安全配置示例，并非默认值：

```json
{
  "port": 8081,
  "host": "127.0.0.1",
  "default_model": "gemini-3.6-flash",
  "api_keys": ["replace-with-a-long-random-key"],
  "cookie_file": null,
  "proxy": null,
  "launch_at_login": false
}
```

新配置目录会收紧为 `0700`，配置文件会以 `0600` staging 文件原子发布。
默认配置监听 `0.0.0.0` 且 API Key 为空；不需要局域网访问时，应在设置中
关闭局域网访问，使其监听 `127.0.0.1`。需要局域网访问时，务必设置高强度
API Key，并由系统防火墙限制来源。不要把 Cookie、API Key 或配置文件提交
到版本库。

### daemon 状态与日志

以下是供用户查看的路径形式；实现会通过 macOS 用户域 API 动态生成路径，
不会硬编码用户主目录：

```text
~/Library/Application Support/Gemini2API/runtime/daemon.json
~/Library/Application Support/Gemini2API/runtime/daemon.lock
~/Library/Logs/Gemini2API/gemini2api.log
```

Application Support、`runtime` 和 Logs 中的 Gemini2API 目录权限为 `0700`；
状态、锁和日志文件权限为 `0600`。daemon 日志达到 5 MiB 时轮转，旧日志移入
macOS 废纸篓，不永久删除。

同一端口只能由一个 listener 使用。App、前台 CLI、托管 daemon 或第三方程序
占用目标端口时，新实例只报告冲突，不查杀端口 owner。无托管状态时，
`status` 会探测配置中的端口，并把健康的 Gemini2API App 或前台 CLI 报告为
`unmanaged`。

`stop` 只会在状态文件、PID、实际可执行路径、进程启动时间和版本均
匹配时，向受托管 daemon 发送一次 `SIGTERM`。它不会停止 App、前台 CLI 或
第三方进程；超时后返回退出码 `5`，不会升级为 `SIGKILL`。

## 已知限制

- Gemini Web 是非官方上游，可能因网页协议、账号状态或网络变化而失效。
- 仅支持文本；媒体、文件和托管工具返回明确 `400`。
- function calling 依赖结构化提示词，不等同于 Gemini 官方原生函数声明能力。
- 带活动工具的响应需要完整生成并校验后才能发送，首字节延迟可能
  更高。
- token 数量是近似值，不能作为账单或精确上下文容量依据。
- 生成控制参数会被接受，但网页上游不保证严格执行。
- App 使用 ad-hoc 签名且未做 Apple 公证。
- CLI daemon 不会在注销或重启后自动恢复，并且同一时间只管理一个实例。
- 官方 SDK 或 Gemini Web 协议升级后需要重新运行独立 smoke 验收。

## 常见问题

### 首次打开提示“已损坏”或无法验证开发者怎么办？

确认 App 来自本仓库 Release 后执行：

```bash
xattr -dr com.apple.quarantine "Gemini2API.app"
```

### 为什么返回 401？

设置中存在 API Key 时，请提供 Bearer、`x-api-key`、`x-goog-api-key` 或
`key=<key>`。配置为空时服务保持免密，但部分 SDK 仍要求非空占位 token。

### 为什么局域网设备能访问，或者不能访问？

默认 `host` 是 `0.0.0.0`。关闭“局域网访问”后改为 `127.0.0.1`；
开启时还要检查 macOS 防火墙，并配置 API Key。

### 为什么工具调用没有立即流式返回？

工具 block 必须先完整生成、解析并确认只引用已声明工具，之后才能编码为
合法事件。

### 为什么 daemon 启动时报端口或实例冲突？

App、前台 CLI、已有 daemon 或其他程序可能已使用该端口。先运行
`gemini2api status --json` 查看分类；如需并行前台实例，可用 `--port` 选择其他
端口。`stop` 只处理身份验证通过的托管 daemon，不会清理未知占用者。

## 构建与测试

```bash
# 七 endpoint HTTP integration、全部 Swift 测试与 Release 脚本安全检查
bash Tests/run-tests.sh --auto

# 构建 Gemini2API.app 和 gemini2api-macOS
./build.sh

# 可选：构建 ZIP 与 DMG
ditto -c -k --keepParent Gemini2API.app Gemini2API-macOS.zip
./make-dmg.sh
```

GitHub Actions 的 Test step 只调用统一 runner，随后构建并验证通用 App 与 CLI，
再生成 `Gemini2API-macOS.zip` 和 `Gemini2API.dmg`。CI 不自动创建 Release。

## 更新历史

### 0.2.0

- 新增不链接 AppKit 的 `gemini2api-macOS` 通用 headless CLI。
- 新增前台 `serve`、托管 daemon、稳定状态输出和安全 stop 生命周期。
- 新增动态运行状态与日志路径、严格文件权限、脱敏日志和废纸篓轮转。
- 构建与 CI 同步验证 App、CLI 的双架构、版本和 Release 附件清单。
- 保持既有配置格式、七个 endpoint、SDK 用例和协议限制兼容。

### 0.1.0

- 统一 Gemini2API 产品身份、配置目录和构建产物名称。
- 增加 OpenAI Responses 与 Gemini GenerateContent 两类接口。
- 以共享生成管线连接七个 endpoint，并补齐鉴权、错误与 SSE 契约。
- 增加七 endpoint HTTP acceptance 和统一 CI 测试入口。
- 增加线程安全取消状态与 Release 脚本废纸篓安全检查。
- 增加真实 Gemini Web 上游与三个官方 SDK 的可重复 smoke test。

## 致谢与许可证

Gemini 网页协议逆向逻辑源自
[gemini-web2api](https://github.com/Sophomoresty/gemini-web2api)。Anthropic Messages
与工具事件映射参考了
[gemini-for-claude-code](https://github.com/coffeegrind123/gemini-for-claude-code)、
[UniClaudeProxy](https://github.com/vibheksoni/UniClaudeProxy) 和
[Anthropic 流式协议](https://platform.claude.com/docs/en/build-with-claude/streaming)。
Codex provider 字段参见
[OpenAI Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

本项目采用 [MIT License](LICENSE)。
