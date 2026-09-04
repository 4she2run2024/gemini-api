# Gemini2API Headless CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 Gemini2API 0.2.0 独立通用 CLI，使现有 API Gateway 可在前台或
受控 daemon 中运行，同时安全提供 `status` 和 `stop`。

**Architecture:** 菜单栏 App 继续使用现有 AppKit 入口；独立 `gemini2api` target
只编译 Foundation、Network、CryptoKit、共享 Gateway 核心和 `Sources/cli/`。
`GatewayRuntime` 统一服务生命周期，CLI 层负责纯参数解析，daemon 层通过
原子状态、
进程身份和 readiness pipe 管理单个当前用户实例。

**Tech Stack:** Swift 6、Foundation、Network、CryptoKit、Darwin、Bash、
GitHub Actions；App 保留 AppKit 与 ServiceManagement，CLI 不链接 AppKit。

**Spec:**
`docs/superpowers/specs/2026-09-04-gemini2api-headless-cli-design.md`

## Global Constraints

- 产品显示名必须为 `Gemini2API`，版本必须为 `0.2.0`，Release tag 为 `v0.2.0`。
- 开发 branch 固定为 `feat/headless-cli`，PR base 固定为 `main`。
- GitHub 目标固定为已确认的 `4she2run2024/gemini-api`。
- 不改写 `Sources/Engine.swift` 的 Gemini Web 协议行为或现有模型目录。
- 不引入第三方依赖，不迁移到 Swift Package Manager，不安装 LaunchAgent。
- CLI 参数只覆盖内存中的 host、port、default model，不调用 `Store.save()`。
- CLI 不接受 Cookie、API Key、token、proxy 等敏感命令行参数。
- `stop` 只向身份完整匹配的托管 daemon 发送一次 `SIGTERM`，不发送 `SIGKILL`。
- 文件级回收只使用 macOS Trash，不使用 `rm` 或 `removeItem`。
- 用户路径通过 `FileManager` 或脚本当前位置动态生成，不硬编码绝对
  用户路径。
- 新变量和函数使用 `snake_case`，常量使用 `UPPER_CASE`，新文件使用
  `kebab-case`。
- 新 Swift 文件写中文用途和使用方法；函数说明功能、参数和返回值。
- 代码和文档每行不超过 100 字符，不保留临时调试输出。
- 每个生产行为遵循 RED、GREEN、REFACTOR；对应测试必须先失败再最小实现。
- PR 创建后暂停；未再次获得确认，不 merge、不创建 tag 或 Release。

---

## File Responsibility Map

- `Sources/gateway-runtime.swift`：共享配置覆盖、listener readiness、信号和停止。
- `Sources/HTTPServer.swift`：向 runtime 暴露 listener 失败，不改变路由语义。
- `Sources/cli/cli-command.swift`：纯命令解析、帮助、版本和退出码。
- `Sources/cli/runtime-state.swift`：动态路径、锁、状态 JSON、权限和进程身份。
- `Sources/cli/daemon-logger.swift`：daemon stdio、脱敏日志和 5 MiB 轮转。
- `Sources/cli/daemon-controller.swift`：posix_spawn/exec、readiness、status、stop
  和单实例。
- `Sources/cli/cli-main.swift`：CLI `@main` 入口和依赖装配。
- `Tests/cli-command-tests.swift`：命令、参数和模型覆盖契约。
- `Tests/gateway-runtime-tests.swift`：配置不落盘、ready、失败和信号生命周期。
- `Tests/runtime-state-tests.swift`：状态、权限、锁、原子发布和 PID 身份。
- `Tests/daemon-logger-tests.swift`：日志权限、脱敏和可恢复轮转。
- `Tests/daemon-controller-tests.swift`：状态分类、所有权判断和安全停止。
- `Tests/cli-integration-tests.sh`：真实前台/daemon 进程闭环与冲突场景。
- `Tests/build-artifact-tests.sh`：通用架构、版本和 CLI 无 AppKit 链接。
- `Tests/run-tests.sh`：统一执行旧测试、新 Swift 测试和 shell 测试。
- `build.sh`：显式构建 App 与独立通用 CLI。
- `.github/workflows/build.yml`：验证并上传 App、DMG 和 CLI 三类附件。
- `README.md`：0.2.0 安装、命令、配置、状态、日志和兼容说明。

---

### Task 1: 建立纯 CLI 命令契约

**Files:**

- Create: `Sources/cli/cli-command.swift`
- Create: `Tests/cli-command-tests.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

```swift
let GEMINI2API_VERSION = "0.2.0"

enum CLIExitCode: Int32 {
    case success = 0
    case usage = 2
    case stopped = 3
    case conflict = 4
    case runtime = 5
}

struct ServeOptions: Equatable {
    let host: String?
    let port: Int?
    let model: String?
    let daemon: Bool
}

enum CLICommand: Equatable {
    case serve(ServeOptions)
    case status(json: Bool)
    case stop(timeout: TimeInterval)
    case version
    case help
}

func parse_cli_command(_ arguments: [String]) throws -> CLICommand
func cli_usage() -> String
```

- [ ] **Step 1: 写参数解析失败测试**

覆盖空参数、未知命令、合法 `serve`、合法 `status --json`、默认/自定义
stop timeout、
端口边界、缺值、重复参数、错误作用域参数和 help/version：

```swift
precondition(try_parse(["serve"]) == .serve(
    ServeOptions(host: nil, port: nil, model: nil, daemon: false)))
precondition(try_parse(["status", "--json"]) == .status(json: true))
precondition(try_parse(["stop"]) == .stop(timeout: 10))
expect_usage_error(["serve", "--port", "0"])
expect_usage_error(["status", "--daemon"])
expect_usage_error(["serve", "--model", "unknown-model"])
expect_usage_error(["serve", "--model", "gemini-3.8-flash@think=5"])
```

模型校验必须基于 `MODELS`，基础模型存在且 `@think` 为 `0...4` 才接受。

- [ ] **Step 2: 运行新增测试并确认 RED**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，编译错误包含 `cannot find 'parse_cli_command' in scope`。

- [ ] **Step 3: 实现完整但纯粹的解析器**

解析器一次性验证全部参数，不启动 Network、不访问文件系统。空参数作为
usage error；`--help`、`-h`、`--version` 只允许作为顶层单一参数。
错误描述只包含参数名和错误类别，
不回显任意用户值。

- [ ] **Step 4: 验证 GREEN 和行宽**

Run:

```bash
bash Tests/run-tests.sh --auto
awk 'length($0) > 100 { print FNR ":" $0; bad=1 } END { exit bad }' \
  Sources/cli/cli-command.swift Tests/cli-command-tests.swift
```

Expected: PASS，且行宽命令无输出。

- [ ] **Step 5: Commit**

```bash
git add Sources/cli/cli-command.swift Tests/cli-command-tests.swift \
  Tests/run-tests.sh
git commit -m "feat: define headless CLI commands"
```

---

### Task 2: 抽取可测试的共享 GatewayRuntime

**Files:**

- Create: `Sources/gateway-runtime.swift`
- Create: `Tests/gateway-runtime-tests.swift`
- Modify: `Sources/HTTPServer.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

```swift
struct RuntimeOverrides: Equatable {
    let host: String?
    let port: Int?
    let model: String?
}

struct RuntimeEndpoint: Equatable {
    let host: String
    let port: Int
}

final class GatewayRuntime {
    init(store: Store, generator: TextGenerating)
    func configure(_ overrides: RuntimeOverrides) throws -> RuntimeEndpoint
    func start(readiness_timeout: TimeInterval = 10) throws
    func install_termination_handlers()
    func wait_until_termination()
    func stop()
}
```

`HTTPServer` 增加以下只读生命周期出口：

```swift
var state_did_fail: ((Error) -> Void)?
```

- [ ] **Step 1: 写 runtime 失败测试**

使用隔离配置根、随机 loopback 端口和 fake generator，覆盖：

- `Store.load()` 后 CLI overrides 只改变内存。
- 配置文件 SHA-256 和 bytes 在 configure/start/stop 后不变。
- listener 进入 ready 后 `start()` 才成功返回。
- 已占用端口使 `start()` 返回 runtime error。
- `SIGINT` 与 `SIGTERM` 通过 `DispatchSourceSignal` 唤醒等待并停止 listener。

测试不得向测试 runner 本身发送终止信号；信号用隔离 helper 子进程验收。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，找不到 `GatewayRuntime`。

- [ ] **Step 3: 实现最小共享 lifecycle**

`GatewayRuntime` 使用注入的 `Store` 和 `TextGenerating` 构造独立 `HTTPServer`。
ready/failure 用锁保护的一次性结果和 semaphore 协调；signal callback
只调用安全的
Dispatch handler。`configure` 校验端口、host 和模型，但绝不调用 `save()`。

`HTTPServer` 的 `.failed(let error)` 分支先报告 `state_did_fail`，再更新 running；
App 的现有 `stateDidChange` 行为保持不变。

- [ ] **Step 4: 验证 GREEN、旧 HTTP 回归和 ThreadSanitizer**

Run:

```bash
bash Tests/run-tests.sh --auto
swiftc -sanitize=thread -g \
  Sources/Config.swift Sources/Engine.swift Sources/Models.swift \
  Sources/Prompt.swift Sources/ToolCalling.swift Sources/Util.swift \
  Sources/gateway-protocol.swift Sources/gateway-pipeline.swift \
  Sources/HTTPServer.swift Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift Sources/gateway-runtime.swift \
  Tests/gateway-runtime-tests.swift -framework Network \
  -framework CryptoKit -o "$(mktemp -d)/gateway-runtime-tsan"
```

Expected: 全部测试 PASS；TSan binary 可编译，执行时无 data race 报告。

- [ ] **Step 5: Commit**

```bash
git add Sources/gateway-runtime.swift Sources/HTTPServer.swift \
  Tests/gateway-runtime-tests.swift Tests/run-tests.sh
git commit -m "feat: share gateway runtime lifecycle"
```

---

### Task 3: 实现安全状态、锁和进程身份

**Files:**

- Create: `Sources/cli/runtime-state.swift`
- Create: `Tests/runtime-state-tests.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

```swift
struct DaemonState: Codable, Equatable {
    let pid: Int32
    let executable_path: String
    let process_started_at: Int64
    let instance_id: String
    let host: String
    let port: Int
    let version: String
}

struct ProcessIdentity: Equatable {
    let executable_path: String
    let process_started_at: Int64
}

protocol ProcessInspecting {
    func inspect(pid: Int32) throws -> ProcessIdentity?
}

enum IdentityResult: Equatable {
    case match
    case missing
    case mismatch
    case uncertain
}

final class DaemonLock {
    func unlock()
}

struct RuntimePaths {
    init(application_support_directory: URL, logs_directory: URL)
    static func current_user(
        file_manager: FileManager = .default
    ) throws -> RuntimePaths
}

final class RuntimeStateStore {
    init(
        paths: RuntimePaths,
        process_inspector: ProcessInspecting,
        trash_item: @escaping (URL) throws -> Void
    )
    func acquire_lock() throws -> DaemonLock
    func load() throws -> DaemonState?
    func publish(_ state: DaemonState) throws
    func recycle_stale_state() throws
    func identity_matches(_ state: DaemonState) -> IdentityResult
}
```

- [ ] **Step 1: 写状态与身份失败测试**

测试注入临时 Application Support/Logs 根和 fake process inspector，覆盖：

- 系统 API 生成的生产路径尾部精确匹配 spec，测试路径不依赖当前用户名。
- runtime/log 目录最终权限 `0700`；state/lock 权限 `0600`。
- `DaemonState` 所有必需字段 JSON round-trip。
- publish 使用同目录 staging + rename，失败不覆盖旧状态。
- staging 和 stale state 传给注入的 Trash closure，不永久删除。
- 两个 lock contender 只有一个获得排他锁，lock 文件固定保留。
- PID 不存在、EPERM、路径不匹配、启动时间不匹配、版本不匹配均不属于
  daemon。
- PID 重用时旧 state 明确分类为 mismatch。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，找不到 `DaemonState` 和 `RuntimeStateStore`。

- [ ] **Step 3: 实现动态路径与原子状态**

生产路径通过 `.applicationSupportDirectory`、`.libraryDirectory` 和用户 domain 解析；
日志根由 Library URL 追加 `Logs/Gemini2API`。使用 `mkdir`/`open`/`fchmod`、
`O_NOFOLLOW` 和同目录 `rename` 收紧权限并避免 symlink 替换。

`DarwinProcessInspector` 使用 `proc_pidpath` 与 `PROC_PIDTBSDINFO`；启动时间统一换算为
Unix 微秒。`kill(pid, 0)` 的 `EPERM` 只产生 identity uncertain，绝不视为可停止。

- [ ] **Step 4: 验证 GREEN 和并发安全**

Run:

```bash
bash Tests/run-tests.sh --auto
for attempt in 1 2 3; do bash Tests/run-tests.sh --auto; done
```

Expected: 四轮全部 PASS，无残留 state staging 文件。

- [ ] **Step 5: Commit**

```bash
git add Sources/cli/runtime-state.swift Tests/runtime-state-tests.swift \
  Tests/run-tests.sh
git commit -m "feat: secure daemon runtime state"
```

---

### Task 4: 实现 daemon 日志和可恢复轮转

**Files:**

- Create: `Sources/cli/daemon-logger.swift`
- Create: `Tests/daemon-logger-tests.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

```swift
enum DaemonLogLevel: String {
    case info
    case error
}

final class DaemonLogger {
    init(
        log_url: URL,
        maximum_bytes: UInt64 = 5 * 1024 * 1024,
        trash_item: @escaping (URL) throws -> Void
    )
    func redirect_standard_streams() throws
    func start_rotation_monitor()
    func write(_ level: DaemonLogLevel, event: String, fields: [String: String])
    func rotate_if_needed() throws
    func stop()
}
```

- [ ] **Step 1: 写日志失败测试**

覆盖新文件 `0600`、低于阈值不轮转、到阈值先切换 fd 再回收旧日志、
回收失败继续写当前文件、timer stop 幂等。敏感字段测试至少包含 `Cookie`、
`Authorization`、
`x-api-key`、`x-goog-api-key`、`key`、request body 和 upstream body，断言均未落盘。

stdio 重定向测试在 helper 子进程中运行，避免污染统一 test runner。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，找不到 `DaemonLogger`。

- [ ] **Step 3: 实现白名单日志字段和轮转**

`write` 只接受内部定义的 event，并从 allowlist 输出时间、阶段、host、
port、PID、
HTTP status、错误类别和 retry count。未知字段丢弃。日志满 5 MiB 时先打开新的
`0600` staging 文件，保留旧 fd，在 `dup2` 后用 macOS `RENAME_SWAP` 交换
canonical/staging 路径，再把包含旧 inode 的 staging 路径交给 Trash。交换失败时
恢复旧 fd，继续写原日志。

同时静态审查现有 `Engine` 和 `Store` 的 stderr 写入，确认只记录
retry/error type，不记录请求 body、上游 body 或 header。发现任一非白名单
写入时，先写脱敏失败测试，
再只收紧该输出点。

- [ ] **Step 4: 验证 GREEN**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: PASS，测试输出和临时日志中不含 secret fixture。

- [ ] **Step 5: Commit**

```bash
git add Sources/cli/daemon-logger.swift Tests/daemon-logger-tests.swift \
  Tests/run-tests.sh
git commit -m "feat: add secure daemon logging"
```

---

### Task 5: 编排 status、stop 与 daemon 生命周期

**Files:**

- Create: `Sources/cli/daemon-controller.swift`
- Create: `Tests/daemon-controller-tests.swift`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

```swift
enum DaemonStatus: String, Codable {
    case running
    case unhealthy
    case stopped
    case unmanaged
    case conflict
}

struct StatusReport: Codable, Equatable {
    let state: DaemonStatus
    let managed: Bool
    let healthy: Bool?
    let pid: Int32?
    let host: String?
    let port: Int?
    let version: String?
}

protocol HealthChecking {
    func check(host: String, port: Int, timeout: TimeInterval) -> HealthResult
}

enum HealthResult: Equatable {
    case healthy
    case unreachable
    case foreign_response
}

final class DaemonController {
    init(
        store: Store,
        state_store: RuntimeStateStore,
        health_checker: HealthChecking,
        process_inspector: ProcessInspecting,
        signal_sender: @escaping (Int32, Int32) -> Int32,
        spawn_environment: [String: String]
    )
    func serve_daemon(options: ServeOptions) -> CLIExitCode
    func status() -> (StatusReport, CLIExitCode)
    func stop(timeout: TimeInterval) -> CLIExitCode
}

struct DaemonChildInvocation: Equatable {
    static func parse(arguments: [String]) -> DaemonChildInvocationParseResult
}

final class DaemonChildRunner {
    init(
        store: Store,
        generator: TextGenerating,
        runtime_factory: @escaping (Store, TextGenerating) -> GatewayRuntime,
        state_store: RuntimeStateStore,
        logger_factory: @escaping () throws -> DaemonLogger,
        process_inspector: ProcessInspecting
    )
    func run(_ invocation: DaemonChildInvocation) -> Never
}
```

- [ ] **Step 1: 写 status 分类失败测试**

用 fake state/process/health 组合逐项覆盖稳定输出：

| state | identity | `GET /` | 结果 | exit |
| --- | --- | --- | --- | --- |
| 无 | 无 | 无响应 | `stopped` | 3 |
| 无 | 无 | Gemini2API healthy | `unmanaged` | 4 |
| 无 | 无 | 其他 HTTP | `conflict` | 4 |
| 有 | match | 200 + `status: ok` | `running` | 0 |
| 有 | match | 失败 | `unhealthy` | 3 |
| 有 | mismatch/uncertain | 任意 | `conflict` | 4 |

断言 JSON 永远包含 `state`、`managed`、`healthy`、`pid`、`host`、`port`、
`version`，缺失值编码为 `null`。状态 host 为 `0.0.0.0` 时只把健康
探测地址转换为 `127.0.0.1`，报告中保留原 host。

- [ ] **Step 2: 写 stop 与 daemon 失败测试**

覆盖：

- 身份不匹配或 EPERM 时 signal recorder 为空。
- match 时只发送一次 `SIGTERM`。
- 原 PID 消失或被复用返回 0；同一 identity 超时返回 5，且无 `SIGKILL`。
- 两个并发 `serve --daemon` 只有一个 readiness 成功。
- stale state 经 Trash 回收后允许启动。
- 占用端口的 fake owner 仍存活，daemon 返回 4 且不发送 signal。
- 子进程只有 listener ready、state 原子发布成功后才向父进程写 ready。
- readiness 10 秒超时或 child early exit 均返回 5。
- parent 已有额外活动线程时，daemon 仍能 ready、status 和 stop。
- 关闭标准 fd 的独立 helper 中，lock/readiness fd 仍稳定且启动结果确定。
- 内部 child invocation 固定使用保留 fd，不被公开 parser 或帮助接受、展示。

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
bash Tests/run-tests.sh --auto
```

Expected: FAIL，找不到 `DaemonController`。

- [ ] **Step 4: 实现 status 和健康检查**

`URLSessionHealthChecker` 对无需鉴权的 `GET /` 要求 HTTP 200、JSON root object 和
`status == "ok"`。无 state 时使用已加载配置 host/port；有 state 时只使用 state
地址。输出渲染与状态判断分离，文本和 JSON 共用同一 `StatusReport`。

- [ ] **Step 5: 实现 daemon start 和安全 stop**

在启动 Network 线程前取得 lock。parent 动态解析当前 executable path，把 lock 和
readiness 源 fd 复制到受控高位后，用 `posix_spawn` 和 `POSIX_SPAWN_SETSID` 执行
同一 executable。file actions 把标准流映射到 `/dev/null`，把 lock/readiness 映射到
保留 child fd；parent 只 close 自己的 flock descriptor，不显式 `LOCK_UN`。

exec 后由隐藏 invocation 进入 `DaemonChildRunner`，重建 Store、generator、runtime、
state 和 logger。child 只通过 pipe 传固定枚举，不传原始错误；完成 runtime
start、
state publish 后才写 ready。退出时停止 listener/logger，重新核对自身 state 后只
回收自己的状态。Task 5 的测试 `@main` 注入隔离路径和 fake generator；Task 6 的
production `@main` 注入 `Store.shared`、`Engine.shared` 与当前用户运行路径。

stop 通过可注入 signal sender 发送一次 `SIGTERM`，按 PID + executable path + start
time 轮询。任何不确定身份直接拒绝；timeout 不升级信号。

- [ ] **Step 6: 验证 GREEN、并发重复和 TSan**

Run:

```bash
bash Tests/run-tests.sh --auto
for attempt in 1 2 3; do bash Tests/run-tests.sh --auto; done
```

Expected: 全部 PASS；无 orphan helper、无未回收 state staging、无 signal
发送给 owner。

- [ ] **Step 7: Commit**

```bash
git add Sources/cli/daemon-controller.swift \
  Tests/daemon-controller-tests.swift Tests/run-tests.sh
git commit -m "feat: manage headless daemon safely"
```

---

### Task 6: 接入独立 CLI 入口与端到端进程测试

**Files:**

- Create: `Sources/cli/cli-main.swift`
- Create: `Tests/cli-integration-tests.sh`
- Modify: `Tests/run-tests.sh`

**Interfaces:**

```swift
@main
struct Gemini2APICLI {
    static func main()
}

final class CLIApplication {
    init(
        store: Store,
        generator: TextGenerating,
        controller_factory: @escaping (Store, TextGenerating) throws
            -> DaemonController
    )
    func run(arguments: [String]) -> CLIExitCode
}
```

- [ ] **Step 1: 写 CLI 进程闭环失败测试**

shell 测试支持 `--auto`，使用 `mktemp -d` 隔离配置根、Application Support 和
Logs，使用随机 loopback 端口与 fake generator。测试编译时传入
`-D GEMINI2API_LIBRARY`，让 `cli-main.swift` 排除 production `@main`，再由 helper
入口向 `CLIApplication` 注入隔离的 `Store`、`RuntimePaths` 和 fake generator。
每个 helper 记录 PID，`trap` 只发送受控 TERM 并把临时目录移入当前用户 Trash。

验收：

1. `--help` 中文输出、`--version` 精确输出 `Gemini2API 0.2.0`。
2. 前台 serve ready 后 `GET /` 200；SIGINT、SIGTERM 均正常退出且无 daemon state。
3. daemon start -> status -> `status --json` -> request -> stop 闭环。
4. terminal parent 退出后 daemon 继续健康。
5. concurrent start 只有一个成功。
6. stale state 可回收；伪造 identity 不可 stop。
7. 端口 owner 不被杀；stop timeout 不产生 SIGKILL。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
bash Tests/cli-integration-tests.sh --auto
```

Expected: FAIL，缺少 CLI `@main` 或测试 binary。

- [ ] **Step 3: 实现入口和退出码映射**

`CLIApplication` 先完整 parse，再加载 `Store.shared`。serve 把 `ServeOptions` 转为
`RuntimeOverrides`；foreground 直接运行 `GatewayRuntime`；daemon/status/stop 交给
`DaemonController`。所有 user-facing 错误写 stderr，stdout 仅保留正常结果或 JSON。

production `@main` 只在未定义 `GEMINI2API_LIBRARY` 时编译。它必须在公开 CLI parser
前检测 `DaemonChildInvocation`：有效 invocation 以 `Store.shared`、`Engine.shared`、
`RuntimePaths.current_user()`、logger 和 Darwin process inspector 重建
`DaemonChildRunner`，并在构造 runtime 前调用 `Store.shared.load()` 恢复非 argv
配置；非法内部 invocation 返回 usage。普通命令继续进入
`CLIApplication`。测试开关不得改变 Release binary 的公开命令或路径契约。

- [ ] **Step 4: 验证端到端 GREEN**

Run:

```bash
bash Tests/run-tests.sh --auto
bash Tests/cli-integration-tests.sh --auto
```

Expected: PASS；`pgrep` 检查没有测试 helper 残留，隔离状态和日志已移入 Trash。

- [ ] **Step 5: Commit**

```bash
git add Sources/cli/cli-main.swift Tests/cli-integration-tests.sh \
  Tests/run-tests.sh
git commit -m "feat: wire headless CLI entrypoint"
```

---

### Task 7: 生成并验证 App 与 CLI Release 产物

**Files:**

- Create: `Tests/build-artifact-tests.sh`
- Modify: `build.sh`
- Modify: `Tests/release-script-tests.sh`
- Modify: `Tests/run-tests.sh`
- Modify: `.github/workflows/build.yml`

- [ ] **Step 1: 写产物失败测试**

`Tests/build-artifact-tests.sh --auto` 精确断言：

```bash
test "$(lipo -archs Gemini2API.app/Contents/MacOS/Gemini2API)" = \
  "x86_64 arm64" || test "$(lipo -archs \
  Gemini2API.app/Contents/MacOS/Gemini2API)" = "arm64 x86_64"
test "$(lipo -archs gemini2api-macOS)" = "x86_64 arm64" || \
  test "$(lipo -archs gemini2api-macOS)" = "arm64 x86_64"
! otool -L gemini2api-macOS | grep -F AppKit
test "$(./gemini2api-macOS --version)" = "Gemini2API 0.2.0"
```

另外读取 Info.plist，断言短版本与构建版本均为 `0.2.0`；断言 CLI
可执行位存在。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
./build.sh
bash Tests/build-artifact-tests.sh --auto
```

Expected: FAIL，当前无 `gemini2api-macOS`，App 版本仍为 `0.1.0`。

- [ ] **Step 3: 重构 build.sh 为显式 source manifests**

App manifest 包含共享 Sources 和 AppKit 三个入口文件；CLI manifest 包含共享 Sources
和全部 `Sources/cli/*.swift`，明确排除 `AppDelegate.swift`、`SettingsWindow.swift`、
`main.swift`。两者分别编译 arm64/x86_64 并用 `lipo` 合并。

沿用现有 `mktemp -d` 和 `move_to_trash`，新增旧 CLI artifact 的 Trash 回收。shell
变量改用 `snake_case`，但不为满足新规范批量重写无关旧脚本。

- [ ] **Step 4: 更新安全测试和 CI 附件**

Release 脚本测试增加 CLI 回收、无 `rm`、无硬编码 `/tmp` 和 source manifest 断言。
CI build 后运行 artifact test，artifact 上传路径必须精确为：

```text
Gemini2API-macOS.zip
Gemini2API.dmg
gemini2api-macOS
```

CI 不创建 tag 或 Release。

- [ ] **Step 5: 验证 GREEN**

Run:

```bash
bash Tests/run-tests.sh --auto
./build.sh
ditto -c -k --keepParent Gemini2API.app Gemini2API-macOS.zip
bash Tests/build-artifact-tests.sh --auto
bash Tests/release-script-tests.sh
```

Expected: PASS；`file` 显示 App/CLI 均为 universal，CLI 的 `otool -L` 无 AppKit。

- [ ] **Step 6: Commit**

```bash
git add build.sh Tests/build-artifact-tests.sh \
  Tests/release-script-tests.sh Tests/run-tests.sh \
  .github/workflows/build.yml
git commit -m "build: publish universal headless CLI"
```

---

### Task 8: 更新 0.2.0 README 用户契约

**Files:**

- Modify: `README.md`

- [ ] **Step 1: 写 README 静态失败检查**

在 `Tests/release-script-tests.sh` 增加断言，要求 README 包含：

- 标题 `# Gemini2API 0.2.0`。
- `gemini2api serve`、`serve --daemon`、`status --json`、`stop --timeout`。
- 退出码 0、2、3、4、5。
- CLI > config > Store default 的优先级。
- Application Support state、Logs 路径的动态说明与 `0700`/`0600` 权限。
- App/CLI 端口冲突、只停止托管 daemon、不使用 SIGKILL。
- Codex、Claude Code、OpenAI/Anthropic/Gemini SDK 连接 CLI 服务示例。
- 0.2.0 更新历史、macOS 13、Swift 6、无新增 runtime dependency。
- 七个 endpoint 的兼容表仍完整存在。

- [ ] **Step 2: 运行静态检查并确认 RED**

Run:

```bash
bash Tests/release-script-tests.sh
```

Expected: FAIL，README 仍是 `0.1.0` 且缺少 CLI 命令。

- [ ] **Step 3: 最小更新 README**

保留现有七 endpoint、SDK 用例和兼容限制。安装示例同时说明 App 附件和
`gemini2api-macOS`；用动态 `bin_dir` 示例安装 CLI，若目标已存在则先提示
用户处理，不覆盖文件。daemon 日志和 state 只展示 `~/Library/...`
用户文档形式，代码实现仍
必须使用系统 API。

- [ ] **Step 4: 验证 GREEN 和链接/行宽**

Run:

```bash
bash Tests/release-script-tests.sh
awk 'length($0) > 100 { print FNR ":" $0; bad=1 } END { exit bad }' README.md
```

Expected: PASS，七个 endpoint 表行数和路径均未减少。

- [ ] **Step 5: Commit**

```bash
git add README.md Tests/release-script-tests.sh
git commit -m "docs: document headless CLI 0.2.0"
```

---

### Task 9: 全量回归、真实上游和发布前证据

**Files:**

- Modify only if a failing acceptance test reveals an in-scope defect.

- [ ] **Step 1: 运行统一测试和七 endpoint 回归**

Run:

```bash
bash Tests/run-tests.sh --auto
```

必须确认以下测试仍通过：

```text
GET /v1/models
POST /v1/chat/completions
POST /v1/responses
POST /v1/messages
POST /v1/messages/count_tokens
POST /v1beta/models/{model}:generateContent
POST /v1beta/models/{model}:streamGenerateContent
```

- [ ] **Step 2: 运行 ThreadSanitizer 和 daemon 重复压力**

以 `Tests/run-tests.sh` 中同一 source manifest 编译 runtime/state/controller 测试的
TSan 版本并执行。随后连续运行 CLI integration 三次，并发启动场景每轮
至少 20 对。

Expected: 无 data race、无双成功、无 orphan、无误杀 port owner。

- [ ] **Step 3: 构建最终附件并计算摘要**

Run:

```bash
./build.sh
ditto -c -k --keepParent Gemini2API.app Gemini2API-macOS.zip
./make-dmg.sh
bash Tests/build-artifact-tests.sh --auto
shasum -a 256 Gemini2API-macOS.zip Gemini2API.dmg gemini2api-macOS
```

把 SHA-256 保存于 PR comment 的验收结果中，不新建未设计的 checksum 文件。

- [ ] **Step 4: 运行真实 Gemini Web 前台 smoke**

使用现有本机配置，不打印配置内容或凭据。通过最终
`gemini2api-macOS serve` 启动
随机 loopback 端口，请求 `/v1/responses`，验证 HTTP 200 和非空 `output_text`，
然后发送 SIGTERM 并确认无 daemon state。

- [ ] **Step 5: 运行真实 daemon smoke**

用最终 CLI 执行 start/status/request/stop；确认 terminal parent 结束后仍健康，stop
后原 PID 不存在，状态已进入 Trash，日志中无 Cookie、Authorization 或
request body。

- [ ] **Step 6: 独立 code review**

审查范围为 `origin/main...HEAD`，重点检查：

- PID reuse/EPERM/path/start-time 所有权边界。
- 多线程 parent 只走 posix_spawn/exec、ready 后才发布成功、stop 不误杀。
- 原子 state、权限、symlink 和 Trash 语义。
- stdout/stderr 轮转顺序和敏感信息白名单。
- CLI source manifest 不含 AppKit，App 行为无回归。
- 七 endpoint 与配置迁移无语义变化。

若审查发现问题，先新增失败测试，再最小修复、全量复验并单独 commit。

- [ ] **Step 7: 验证 Git 与远程 branch**

Run:

```bash
git status --short
git diff --check origin/main...HEAD
git log --oneline origin/main..HEAD
git push -u origin feat/headless-cli
git rev-parse HEAD
git rev-parse origin/feat/headless-cli
```

Expected: 工作树干净、diff check 无输出、本地与远程 SHA 一致。

---

### Task 10: 创建 PR 并停在 merge/Release 确认门

**Files:** None.

- [ ] **Step 1: 再核对 GitHub 写入目标**

Run:

```bash
gh auth status
gh repo view 4she2run2024/gemini-api \
  --json nameWithOwner,visibility,defaultBranchRef
```

Expected: repository 为 `4she2run2024/gemini-api`，default branch 为 `main`。

- [ ] **Step 2: 创建 pull request**

PR title：

```text
feat: add Gemini2API headless CLI
```

PR body 只写最终行为、测试证据、安全边界和 Release 附件，不描述
试错过程。

- [ ] **Step 3: 验证 PR 状态**

Run:

```bash
gh pr checks --watch
gh pr view --json number,state,mergeable,headRefName,baseRefName,url
```

Expected: PR open、base `main`、head `feat/headless-cli`、checks PASS、mergeable。

- [ ] **Step 4: 自动打开远程 PR 并暂停**

Run:

```bash
gh pr view --web
```

报告 PR number、URL、commit、checks、附件 SHA-256 和真实 smoke 结果。
将 `gh pr view` 返回的实际编号保存为 `pr_number`，最后一行必须为：

```text
**请确认合并 PR #${pr_number}，随后创建 v0.2.0 Release。**
```

未收到该确认前，不 merge、不创建 `v0.2.0` tag、不创建 Release、不上传附件。

---

## Final Verification Matrix

| Gate | Command or evidence | Pass condition |
| --- | --- | --- |
| Pure parser | `Tests/cli-command-tests.swift` | 参数、模型、退出码全覆盖 |
| Runtime | `Tests/gateway-runtime-tests.swift` | ready、信号、配置不落盘 |
| State identity | `Tests/runtime-state-tests.swift` | PID/path/start time/权限通过 |
| Logging | `Tests/daemon-logger-tests.swift` | 0600、脱敏、Trash 轮转 |
| Daemon | `Tests/daemon-controller-tests.swift` | 单实例、安全 stop、稳定 status |
| Process E2E | `Tests/cli-integration-tests.sh --auto` | foreground/daemon 闭环通过 |
| Seven endpoints | `Tests/run-tests.sh --auto` | 现有七 endpoint 全通过 |
| Race safety | TSan + repeated integration | 无 race、orphan、双成功或误杀 |
| Artifacts | `Tests/build-artifact-tests.sh --auto` | 双 universal、CLI 无 AppKit |
| Real upstream | foreground + daemon smoke | Responses 非空且 stop 干净 |
| Git | `git diff --check`, clean status | 无格式错误，工作树干净 |
| GitHub | PR checks and review | OPEN、PASS、APPROVED、mergeable |

## Release Boundary After User Confirmation

这部分不是实施计划的自动步骤。只有用户明确确认实际 PR number 和
v0.2.0 后，才执行：

1. merge PR 到 `main`。
2. 验证 `origin/main` 包含 PR merge commit 且 CI 通过。
3. 从该 main commit 创建 annotated tag `v0.2.0`。
4. 创建 GitHub Release，上传 ZIP、DMG、CLI 三个附件。
5. 对比本地 SHA-256 与 GitHub asset digest。
6. 验证 Release published、tag commit 正确、三个附件均可访问。

merge 与 Release 是独立写操作证据，不因 PR 可合并而视为已经完成。
