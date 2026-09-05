# Gemini2API Headless CLI 0.2.0 设计

## 1. 背景与目标

Gemini2API 0.1.0 只能通过 AppKit 菜单栏应用启动 HTTP 服务。直接执行
App bundle 内的主二进制虽然可以从终端发起，但仍会创建 `NSApplication`，
不能作为真正不依赖 AppKit 的 headless 服务。

0.2.0 新增独立通用二进制 `gemini2api`，使用户可以：

- 在终端前台运行现有 API Gateway。
- 使用 `--daemon` 启动脱离终端的当前用户后台进程。
- 查询托管 daemon 的进程身份和 HTTP 健康状态。
- 只停止由 CLI 自己创建且身份验证通过的 daemon。
- 继续复用现有配置、HTTP 协议适配和 Gemini Web 生成核心。

本功能不重写 `Engine.swift`，不引入第三方运行时依赖，也不把菜单栏 App
改成命令行程序。

## 2. 已确认的产品决策

- 开发 branch：`feat/headless-cli`。
- 产品版本：`0.2.0`。
- Release tag：`v0.2.0`。
- CLI 使用独立、不链接 AppKit 的通用二进制。
- CLI 默认读取现有 `~/.config/gemini2api/config.json`。
- 命令行参数只覆盖当前运行，不写回配置。
- `serve` 默认前台运行，`serve --daemon` 启动用户级临时 daemon。
- daemon 在关闭终端后继续运行，但注销或重启后停止。
- 不安装 LaunchAgent 或系统 LaunchDaemon。
- 同一时间只允许一个由 CLI 管理的 daemon。
- `stop` 不得停止菜单栏 App、其他前台实例或占用端口的第三方进程。
- 完成后先创建 pull request；只有再次获得用户确认才 merge 和创建 Release。

## 3. 方案选择

### 3.1 采用方案

新增独立 CLI target，并让 App 与 CLI 共用 `Store`、`HTTPServer`、
`GatewayPipeline` 和 `Engine`：

```text
Gemini2API.app
    -> AppDelegate
    -> Store + HTTPServer + Engine

gemini2api
    -> CLICommand
       -> serve
       -> serve --daemon
       -> status
       -> stop
    -> Store + HTTPServer + Engine
```

CLI 源文件放在 `Sources/cli/`。现有 App 构建只编译 `Sources/*.swift`，不会把
CLI 的 `@main` 入口编入 App。CLI 构建显式选择共享核心文件和 `Sources/cli/`
文件，排除 `AppDelegate.swift`、`SettingsWindow.swift` 与现有 `main.swift`。

### 3.2 未采用方案

- 不在 App 主二进制中按参数分流，因为这仍会链接 AppKit，不能满足真正
  headless 的目标。
- 不在本版本改造成 Swift Package Manager 多 target，因为这会扩大构建、CI
  和目录迁移范围。
- 不用 shell wrapper 模拟 CLI，因为它不能提供可靠的 PID 身份、readiness 和
  安全停止契约。

## 4. 命令行契约

### 4.1 命令

```text
gemini2api serve [--host HOST] [--port PORT] [--model MODEL]
gemini2api serve [--host HOST] [--port PORT] [--model MODEL] --daemon
gemini2api status [--json]
gemini2api stop [--timeout SECONDS]
gemini2api --version
gemini2api --help
```

所有命令都是非交互式的，不等待终端问答。`--help` 输出中文用法说明。

### 4.2 参数语义

- `--host`：覆盖本次监听地址；必须为可由 `NWEndpoint.Host` 接受的非空值。
- `--port`：覆盖本次端口；只接受 `1...65535`。
- `--model`：覆盖本次默认模型；基础模型必须存在于 `MODELS`，可选
  `@think=N` 只接受 `N` 为 `0...4`，未知模型不得静默回退。
- `--daemon`：只允许和 `serve` 一起使用。
- `--json`：只允许和 `status` 一起使用。
- `--timeout`：只允许和 `stop` 一起使用；默认 10 秒，必须大于 0。

未知命令、重复且冲突的参数、缺失参数值或非法取值返回参数错误，
不启动服务。

### 4.3 配置优先级

```text
CLI 本次参数
    > ~/.config/gemini2api/config.json
    > Store 声明默认值
```

CLI 加载 `Store.shared` 后只修改内存中的 `host`、`port` 和 `defaultModel`。
不调用 `save()`，不修改配置文件。Cookie、代理、`auth_user`、`xsrf_token` 和
Gateway API Key 等敏感字段没有命令行参数，避免出现在 shell history 或进程
参数列表。

### 4.4 退出码

```text
0  命令成功，或 status 确认托管 daemon 健康
2  命令、参数或配置错误
3  daemon 未运行，或进程存在但 HTTP 健康检查失败
4  PID 身份不匹配，或端口/实例所有权冲突
5  HTTP listener、daemon 化或运行状态发布失败
```

## 5. 前台服务生命周期

`gemini2api serve` 执行以下步骤：

1. 解析全部参数，不接受部分解析结果。
2. 加载现有配置并应用本次内存覆盖。
3. 初始化 `HTTPServer(generator: Engine.shared, config: Store.shared)`。
4. 注册基于 `DispatchSourceSignal` 的 `SIGINT` 和 `SIGTERM` 处理。
5. 启动 listener，并等待 `HTTPServer.running == true`。
6. 在标准输出打印不含凭据的监听地址和 PID。
7. 保持 run loop，直到收到终止信号或 listener 失败。
8. 调用 `HTTPServer.stop()` 后退出。

信号 callback 只触发同步事件，不在 POSIX signal handler 中执行 Swift、Foundation
或文件系统操作。

前台实例不创建 daemon 状态文件，因此 `stop` 永远不会终止它。如果前台实例
使用非配置端口启动，`status` 不负责扫描或发现该任意端口。

## 6. Daemon 生命周期

### 6.1 启动

`gemini2api serve --daemon` 在启动任何 Network 线程前执行：

1. 打开持久的 daemon lock 文件并取得排他锁。
2. 检查现有 daemon 状态；活动且身份匹配时返回所有权冲突。
3. 对确认失效的 stale 状态执行废纸篓回收。
4. 创建父子 readiness pipe。
5. 动态解析当前 executable path，并以 `posix_spawn` 启动同一 executable；
   同时设置 `POSIX_SPAWN_SETSID` 和 `POSIX_SPAWN_CLOEXEC_DEFAULT`，不在多线程
   parent 的 fork child 中执行 Swift、Foundation 或 Network，也不继承 unrelated fd。
6. spawn file actions 只显式保留标准流、lock 和 readiness：标准流先稳定映射到
   `/dev/null`，lock/readiness 写端从受控高位源 fd 映射到不低于 3 的保留
   child fd。
7. 新进程先解析未公开的内部 child invocation，再重新加载 Store 并重建
   generator、runtime、state 和 logger；公开 parser 与帮助均不暴露该 invocation。
8. exec child 接管 flock、把 stdout/stderr 指向受控日志文件，启动 HTTP 服务并
   等待 listener ready。
9. child 原子发布 daemon 状态，再通过 pipe 返回 ready；状态 executable path
   必须来自 exec 后的真实进程身份。
10. parent 在 spawn 成功后只关闭自己的 lock descriptor，不调用 `LOCK_UN`；
    最多等待 10 秒，只有收到 ready 才返回退出码 0。

production child 使用空 `envp`，不得继承 parent 的 HOME、PATH、proxy、token 或
其他环境项；配置只由 exec 后重新加载的 Store 恢复。测试只能通过 controller
initializer 注入明确 allowlist 中的非敏感测试模式变量，key/value 不合法时
fail closed。

`/dev/null` 是操作系统设备路径，不是用户数据路径；其他用户目录和临时
路径均由系统 API 动态获取。

child 启动失败时，通过 readiness pipe 返回脱敏错误类别，回收未发布的 staging
状态并退出。readiness 超时时 parent 只发送一次 `SIGTERM`，用有界 `WNOHANG`
回收，不发送 `SIGKILL`，也不把“已经 spawn”视为“服务已经可用”。

### 6.2 单实例与并发启动

daemon lock 文件固定保留在运行状态目录中，不删除。启动、stale 状态判断和
状态发布在同一排他锁保护下完成。第二个并发启动者必须看到活动状态或
锁冲突，不能覆盖第一个实例的状态。

端口已经由 App、前台 CLI 或其他程序占用时，listener 启动失败。CLI 只报告
冲突，不查杀端口 owner。用户可以通过 `--port` 在不同端口启动前台实例，
但仍只能有一个托管 daemon。

### 6.3 退出

daemon 收到 `SIGTERM` 后：

1. 停止 HTTP listener。
2. 停止日志轮转 timer。
3. 验证当前状态仍属于自身。
4. 把 daemon 状态文件移入 macOS 废纸篓。
5. 关闭日志和锁后退出。

daemon 不安装登录项，因此注销或重启后不会自动恢复。

## 7. 运行状态与进程身份

### 7.1 动态路径

路径使用 `FileManager` 的用户域目录 API 生成：

```text
Application Support/Gemini2API/runtime/daemon.json
Application Support/Gemini2API/runtime/daemon.lock
Logs/Gemini2API/gemini2api.log
```

实现中不得硬编码用户主目录。Application Support、runtime 和 Logs 目录权限为
`0700`；状态、锁和日志文件权限为 `0600`。

### 7.2 状态结构

`daemon.json` 至少包含：

```json
{
  "pid": 12345,
  "executable_path": "动态解析后的实际路径",
  "process_started_at": 1788520000123456,
  "instance_id": "随机实例 ID",
  "host": "127.0.0.1",
  "port": 8081,
  "version": "0.2.0"
}
```

`process_started_at` 是 macOS process API 返回值换算后的 Unix 微秒时间戳。

状态采用临时 staging 文件、`0600` 权限和原子 rename 发布。发布失败时不破坏
已有状态。未发布 staging 文件和确认失效的旧状态只移入废纸篓，
不永久删除。

### 7.3 身份校验

`status` 和 `stop` 必须同时验证：

- PID 大于 1 且 `kill(pid, 0)` 表明进程存在或当前用户无信号权限。
- 通过 macOS process API 读取的实际可执行文件路径与状态记录一致。
- 进程启动时间与状态记录一致，防止 PID 重用。
- 状态版本和必要字段结构合法。

只有四项全部通过，实例才属于 CLI。状态文件存在但身份不匹配时报告
冲突，不发送任何信号。`kill(pid, 0)` 返回 `EPERM` 时也按身份不确定处理，
不发送信号。

## 8. status 与 stop

### 8.1 status

存在合法 daemon 状态时，`status` 使用状态中记录的 host/port；监听地址为
`0.0.0.0` 时，健康检查目标转换为 `127.0.0.1`。健康检查调用无需鉴权的
`GET /`，并要求 HTTP 200 和 `status: ok`。

没有 daemon 状态时，`status` 使用配置中的端口探测 `GET /`：

- 无响应：报告 stopped，退出码 3。
- 有健康响应但无托管状态：报告 unmanaged，不推断 owner，退出码 4。
- 有非 Gemini2API 响应：报告 port conflict，退出码 4。

文本输出适合人读；`--json` 输出稳定对象：

```json
{
  "state": "running",
  "managed": true,
  "healthy": true,
  "pid": 12345,
  "host": "127.0.0.1",
  "port": 8081,
  "version": "0.2.0"
}
```

`state` 只使用 `running`、`unhealthy`、`stopped`、`unmanaged`、
`conflict`。缺少的值编码为 `null`，不省略稳定字段。

### 8.2 stop

`stop` 读取并验证 daemon 状态。验证失败时返回退出码 3 或 4，不发送信号。
验证成功后发送一次 `SIGTERM`，并在 `--timeout` 秒内轮询原 PID 和启动时间：

- 进程正常退出：返回 0。
- PID 已被其他进程复用：视为原实例已停止，返回 0，但不触碰新进程。
- 到期仍为同一进程：返回 5，不发送 `SIGKILL`。

## 9. 日志与脱敏

前台模式把日志保留在当前终端。daemon 模式把 stdout/stderr 重定向到动态日志
路径，并以 `0600` 创建文件。

daemon 每秒检查日志大小。达到 5 MiB 时：

1. 创建并切换到新的 `0600` 日志文件描述符。
2. 原子替换 stdout/stderr 指向。
3. 把旧日志移入 macOS 废纸篓。

日志只允许包含：时间、命令阶段、监听 host/port、PID、HTTP status、错误类别
和重试次数。不得包含 Cookie、API Key、Authorization、完整请求 body 或完整
上游响应。日志轮转失败时保留当前日志继续写入，并记录不含真实敏感
路径的错误类别。

## 10. 组件边界

建议新增：

```text
Sources/gateway-runtime.swift
Sources/cli/cli-main.swift
Sources/cli/cli-command.swift
Sources/cli/daemon-controller.swift
Sources/cli/runtime-state.swift
Sources/cli/daemon-logger.swift
```

- `GatewayRuntime`：启动/停止共享 HTTP 服务、等待 ready、管理安全信号源；
  可注入 generator 和 Store 以便测试。
- `CLICommand`：纯参数解析和退出码映射，不接触 Network 或文件系统。
- `DaemonController`：posix_spawn、fd transfer、readiness、status 和 stop orchestration。
- `DaemonChildRunner`：在 exec 后接管 lock，重建依赖后启动、发布和清理 daemon。
- `RuntimeStateStore`：动态路径、权限、原子 JSON 状态、锁和废纸篓回收。
- `DaemonLogger`：stdio 重定向、大小检查和可恢复轮转。

各组件以小接口通信；参数解析测试不需要启动服务，状态测试不需要真实
Gemini Web，HTTP 生命周期测试可以注入 fake generator。

## 11. 构建、安装与发布

### 11.1 构建

更新构建脚本，显式维护 App 与 CLI 的源文件集合。CLI 分别编译 arm64 和
x86_64，再用 `lipo` 生成通用 `gemini2api`。构建检查必须确认：

- `file` 和 `lipo -archs` 同时包含 `arm64`、`x86_64`。
- `otool -L` 不包含 AppKit。
- `gemini2api --version` 输出 `Gemini2API 0.2.0`。
- App plist 版本同步为 `0.2.0`。

CLI Release 附件命名为 `gemini2api-macOS`。用户下载后需要赋予执行权限并放入
自己的 PATH 目录；README 使用动态用户路径示例，不覆盖既有文件。

### 11.2 Release 附件

`v0.2.0` 包含且只新增一个 CLI 附件：

```text
Gemini2API-macOS.zip
Gemini2API.dmg
gemini2api-macOS
```

App、ZIP 和 DMG 继续保留。Release 前记录本地 SHA-256，并在上传后与 GitHub
asset digest 对比。

### 11.3 CI

CI 的 test step 继续只调用统一 runner。构建阶段同时生成通用 App 与通用 CLI，
验证架构、CLI 版本和无 AppKit 链接，再生成 ZIP/DMG。CI 不自动创建 tag 或
Release。

## 12. 测试策略

实现遵循测试驱动开发，每个行为先看到预期 RED，再做最小 GREEN。

### 12.1 单元测试

- 命令、参数、重复参数、缺失值和退出码。
- CLI 参数覆盖配置但不写回文件。
- runtime 状态 JSON 编解码和稳定字段。
- 动态目录、`0700`/`0600` 权限和原子发布。
- PID 不存在、PID 重用、可执行路径不匹配和状态版本不匹配。
- 日志脱敏、5 MiB 阈值和废纸篓轮转。

### 12.2 集成测试

- 前台服务 ready、HTTP 200、SIGINT 和 SIGTERM。
- daemon 启动、父进程 readiness、`status`、`status --json`、`stop` 闭环。
- 并发 daemon 启动只有一个成功。
- stale 状态被安全回收。
- 端口由 App/fake server 占用时拒绝启动且不终止 owner。
- stop 身份不匹配时不发送信号。
- stop 超时不升级为 `SIGKILL`。
- App 与现有七 endpoint 测试全部回归通过。

所有进程测试使用随机 loopback 端口、隔离的临时用户根目录和 fake generator；
临时目录与状态通过 macOS Trash 回收，不永久删除。

### 12.3 构建与 smoke

- CLI arm64/x86_64 通用二进制和无 AppKit 链接检查。
- App、ZIP、DMG 版本与完整性检查。
- 使用 CLI 前台模式连接真实 Gemini Web 上游，通过 `/v1/responses` 验证 HTTP 200
  与非空 `output_text`。
- 使用最终 CLI daemon 模式完成一次真实 start/status/request/stop 闭环。

## 13. README 与兼容性

README 标题更新为 `Gemini2API 0.2.0`，并新增：

- CLI 下载和安装。
- 前台与 daemon 使用示例。
- `status --json` 输出和退出码。
- 配置覆盖优先级。
- 日志、PID 和动态路径说明。
- App/CLI 端口冲突及安全停止说明。
- Codex、Claude Code 和 SDK 连接 CLI 服务的示例。
- 0.2.0 更新历史和依赖要求。

现有配置格式和七个 endpoint 不做不兼容修改。旧 App 用户可以继续只使用
菜单栏 App；CLI 是可选的新入口。

## 14. 明确不在本版本实现

- LaunchAgent、开机自动启动 CLI 或系统 LaunchDaemon。
- root/system-wide 服务。
- 多个托管 daemon 实例。
- 任意端口进程扫描或强制终止。
- `SIGKILL` 自动升级。
- CLI 修改或持久化配置。
- CLI 参数传递 Cookie、API Key 或其他凭据。
- Swift Package Manager 迁移。
- Gemini Web 核心、模型列表或协议行为重写。

## 15. 验收标准

只有同时满足以下条件才能创建 pull request：

1. 所有新增 CLI、daemon、安全和日志测试通过。
2. 现有七 endpoint、SDK、配置迁移和 Release 脚本测试无回归。
3. ThreadSanitizer 未发现新增竞态。
4. App 与 CLI 都是 arm64/x86_64 通用二进制。
5. CLI 不链接 AppKit，App plist 和 CLI 版本均为 0.2.0。
6. 真实前台和 daemon smoke 通过，且临时资源已移入废纸篓。
7. README、CI、构建脚本和 Release 附件清单同步更新。
8. 独立 code review 为 APPROVED，工作树干净。

pull request 创建后必须暂停。用户确认前不得 merge、创建 `v0.2.0` tag、Release
或上传附件。
