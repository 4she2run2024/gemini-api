// 用途：验证 CLIApplication 的 status state-first 编排与 factory 调用顺序。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import Foundation

private final class CLIMainFakeGenerator: TextGenerating {
    // 功能：返回固定文本，避免 CLI main 测试访问真实上游。
    // 参数：request 为生成请求。
    // 返回值：固定测试文本。
    func generate(_ request: GenerationRequest) throws -> String {
        "cli main test"
    }

    // 功能：返回固定流式文本。
    // 参数：request 为请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if !isCancelled() { onDelta("cli main test") }
    }
}

private final class CLIMainProcessInspector: ProcessInspecting {
    private let identity: ProcessIdentity

    // 功能：创建始终返回指定身份的进程查询器。
    // 参数：identity 为与测试 state 匹配的身份。
    // 返回值：初始化后的查询器。
    init(identity: ProcessIdentity) {
        self.identity = identity
    }

    // 功能：返回固定进程身份。
    // 参数：pid 为状态中的测试 PID。
    // 返回值：固定身份。
    func inspect(pid: Int32) throws -> ProcessIdentity? {
        identity
    }
}

private final class CLIMainHealthChecker: HealthChecking {
    private(set) var calls: [(String, Int)] = []

    // 功能：记录 state endpoint 并返回健康。
    // 参数：host、port 为探测地址；timeout 为最长等待时间。
    // 返回值：固定 healthy。
    func check(host: String, port: Int, timeout: TimeInterval) -> HealthResult {
        calls.append((host, port))
        return .healthy
    }
}

private final class CLIMainEventRecorder {
    private var values: [String] = []

    // 功能：按发生顺序记录 factory 事件。
    // 参数：value 为固定事件名。
    // 返回值：无。
    func append(_ value: String) {
        values.append(value)
    }

    // 功能：读取事件顺序。
    // 参数：无。
    // 返回值：当前完整事件数组。
    func snapshot() -> [String] {
        values
    }
}

@main
struct CLIMainTests {
    // 功能：验证匹配 state 先于损坏的 Store endpoint/model 被使用。
    // 参数：无。
    // 返回值：全部断言通过时正常退出。
    static func main() throws {
        let test_root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini2api-cli-main-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: test_root,
            withIntermediateDirectories: true)
        defer { recycle_test_root_best_effort(test_root) }

        let executable_path = test_root.appendingPathComponent("gemini2api").path
        let identity = ProcessIdentity(
            executable_path: executable_path,
            process_started_at: 1_788_520_000_123_456)
        let state = DaemonState(
            pid: 4_201,
            executable_path: executable_path,
            process_started_at: identity.process_started_at,
            instance_id: "cli-main-state-first",
            host: "127.0.0.1",
            port: 18_082,
            version: GEMINI2API_VERSION)
        let inspector = CLIMainProcessInspector(identity: identity)
        let paths = RuntimePaths(
            application_support_directory: test_root.appendingPathComponent("support"),
            logs_directory: test_root.appendingPathComponent("logs"))
        let state_store = RuntimeStateStore(
            paths: paths,
            process_inspector: inspector,
            trash_item: { _ in })
        try state_store.publish(state)

        let store = Store(config_root: test_root.appendingPathComponent("config"))
        store.host = "invalid host"
        store.port = 0
        store.defaultModel = "unknown-model"
        let health_checker = CLIMainHealthChecker()
        let events = CLIMainEventRecorder()
        let application = CLIApplication(
            store: store,
            generator_factory: {
                events.append("generator")
                return CLIMainFakeGenerator()
            },
            controller_factory: { loaded_store, _ in
                events.append("controller")
                return DaemonController(
                    store: loaded_store,
                    state_store: state_store,
                    health_checker: health_checker,
                    process_inspector: inspector,
                    signal_sender: { _, _ in 0 })
            },
            runtime_factory: { loaded_store, generator in
                events.append("runtime")
                return GatewayRuntime(store: loaded_store, generator: generator)
            })

        precondition(application.run(arguments: ["status"]) == .success)
        precondition(events.snapshot() == ["generator", "controller"])
        precondition(health_checker.calls.count == 1)
        precondition(health_checker.calls[0].0 == state.host)
        precondition(health_checker.calls[0].1 == state.port)
        precondition(cli_health_text(true) == "是")
        precondition(cli_health_text(false) == "否")
        precondition(cli_health_text(nil) == "未知")
        print("CLIMainTests passed")
    }

    // 功能：尽力把测试目录移入当前用户废纸篓。
    // 参数：test_root 为动态测试根。
    // 返回值：无；失败时保留目录供诊断。
    private static func recycle_test_root_best_effort(_ test_root: URL) {
        var recycled_url: NSURL?
        try? FileManager.default.trashItem(
            at: test_root,
            resultingItemURL: &recycled_url)
    }
}
