// 用途：验证 daemon 状态分类、健康探测、安全停止与后台进程生命周期。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import CryptoKit
import Darwin
import Dispatch
import Foundation

private final class ControllerFakeGenerator: TextGenerating {
    // 功能：返回固定文本，避免 controller 测试访问真实上游。
    // 参数：request 为 HTTP 路由生成的请求。
    // 返回值：固定响应文本。
    func generate(_ request: GenerationRequest) throws -> String {
        "controller test"
    }

    // 功能：返回固定流式增量，避免 controller 测试访问真实上游。
    // 参数：request 为生成请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if !isCancelled() { onDelta("controller test") }
    }
}

private final class ControllerFakeProcessInspector: ProcessInspecting {
    private let result: (Int32) throws -> ProcessIdentity?

    // 功能：创建由测试闭包控制的进程查询器。
    // 参数：result 为 PID 对应的身份结果。
    // 返回值：初始化后的查询器。
    init(result: @escaping (Int32) throws -> ProcessIdentity?) {
        self.result = result
    }

    // 功能：返回测试指定的进程身份。
    // 参数：pid 为待查询进程号。
    // 返回值：存在时返回身份，不存在时为 nil，也可抛错。
    func inspect(pid: Int32) throws -> ProcessIdentity? {
        try result(pid)
    }
}

private final class RecordingHealthChecker: HealthChecking {
    private let result: HealthResult
    private(set) var calls: [(host: String, port: Int, timeout: TimeInterval)] = []

    // 功能：创建返回固定结果的健康检查器。
    // 参数：result 为每次探测返回值。
    // 返回值：初始化后的检查器。
    init(result: HealthResult) {
        self.result = result
    }

    // 功能：记录探测地址并返回固定结果。
    // 参数：host、port 和 timeout 为 controller 提供的探测参数。
    // 返回值：初始化时指定的结果。
    func check(host: String, port: Int, timeout: TimeInterval) -> HealthResult {
        calls.append((host, port, timeout))
        return result
    }
}

private enum ControllerTestError: Error {
    case identity_uncertain
    case socket_failed
}

private enum ProcessStep {
    case identity(ProcessIdentity)
    case missing
    case uncertain
}

private final class SequencedProcessInspector: ProcessInspecting {
    private let lock = NSLock()
    private let steps: [ProcessStep]
    private var index = 0

    // 功能：创建按调用顺序返回身份结果的查询器。
    // 参数：steps 至少包含一个结果，耗尽后重复最后一项。
    // 返回值：初始化后的查询器。
    init(steps: [ProcessStep]) {
        precondition(!steps.isEmpty)
        self.steps = steps
    }

    // 功能：返回当前步骤并推进序号。
    // 参数：pid 为待查询进程号。
    // 返回值：身份、nil 或不确定错误。
    func inspect(pid: Int32) throws -> ProcessIdentity? {
        lock.lock()
        let step = steps[min(index, steps.count - 1)]
        index += 1
        lock.unlock()
        switch step {
        case .identity(let identity):
            return identity
        case .missing:
            return nil
        case .uncertain:
            throw ControllerTestError.identity_uncertain
        }
    }
}

private final class SignalRecorder {
    private let lock = NSLock()
    private let handler: (Int32, Int32) -> Int32
    private var stored_records: [(pid: Int32, signal_number: Int32)] = []

    // 功能：创建可选择真实转发的 signal recorder。
    // 参数：handler 为记录后执行的边界操作，默认模拟成功。
    // 返回值：初始化后的 recorder。
    init(handler: @escaping (Int32, Int32) -> Int32 = { _, _ in 0 }) {
        self.handler = handler
    }

    // 功能：记录一次 signal 请求并模拟成功。
    // 参数：pid 和 signal_number 为目标进程与信号。
    // 返回值：固定返回零。
    func send(pid: Int32, signal_number: Int32) -> Int32 {
        lock.lock()
        stored_records.append((pid, signal_number))
        lock.unlock()
        return handler(pid, signal_number)
    }

    // 功能：返回线程安全的 signal 记录快照。
    // 参数：无。
    // 返回值：按发送顺序排列的记录。
    func records() -> [(pid: Int32, signal_number: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return stored_records
    }
}

private struct StatusFixture {
    let controller: DaemonController
    let health_checker: RecordingHealthChecker
    let state_store: RuntimeStateStore
}

private struct StopFixture {
    let controller: DaemonController
    let signal_recorder: SignalRecorder
}

private struct DaemonFixture {
    let controller: DaemonController
    let state_store: RuntimeStateStore
    let paths: RuntimePaths
    let signal_recorder: SignalRecorder
}

private struct PortOwner {
    let process: Process
    let completed: DispatchSemaphore
    let port: Int
}

private struct ServeHelper {
    let process: Process
    let completed: DispatchSemaphore
    let output_pipe: Pipe
}

@main
struct DaemonControllerTests {
    // 功能：运行 daemon controller 的全部行为测试。
    // 参数：无。
    // 返回值：全部断言通过时正常退出，否则终止测试进程。
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--port-owner-helper" {
            try run_port_owner_helper()
            return
        }
        if CommandLine.arguments.dropFirst().first == "--serve-helper" {
            try run_serve_helper()
            return
        }
        let test_root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini2api-controller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: test_root,
            withIntermediateDirectories: true)
        defer { recycle_test_root_best_effort(test_root) }

        try test_status_without_state(test_root: test_root)
        try test_status_with_matching_state(test_root: test_root)
        try test_status_rejects_untrusted_identity(test_root: test_root)
        try test_status_json_keeps_null_fields()
        try test_url_session_health_checker()
        try test_stop_rejects_untrusted_identity(test_root: test_root)
        try test_stop_sends_one_sigterm_and_accepts_exit(test_root: test_root)
        try test_stop_accepts_pid_reuse(test_root: test_root)
        try test_stop_times_out_without_sigkill(test_root: test_root)
        try test_concurrent_daemon_start_publishes_ready_state(test_root: test_root)
        try test_stale_state_is_recycled_before_daemon_start(test_root: test_root)
        try test_child_preserves_replaced_state(test_root: test_root)
        try test_port_owner_survives_daemon_conflict(test_root: test_root)
        try test_child_early_exit_returns_runtime(test_root: test_root)
        try test_readiness_timeout_cleans_child(test_root: test_root)
        print("DaemonControllerTests passed")
    }

    // 功能：验证无托管状态时区分 stopped、unmanaged 和外部端口冲突。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；状态矩阵不符时终止测试。
    private static func test_status_without_state(test_root: URL) throws {
        let cases: [(HealthResult, DaemonStatus, CLIExitCode, Bool)] = [
            (.unreachable, .stopped, .stopped, false),
            (.healthy, .unmanaged, .conflict, true),
            (.foreign_response, .conflict, .conflict, false),
        ]
        for (index, item) in cases.enumerated() {
            let fixture = make_status_fixture(
                root: test_root.appendingPathComponent("no-state-\(index)"),
                health_result: item.0,
                process_result: { _ in nil })
            let (report, exit_code) = fixture.controller.status()
            precondition(report == StatusReport(
                state: item.1,
                managed: false,
                healthy: item.3,
                pid: nil,
                host: "0.0.0.0",
                port: 18_081,
                version: nil))
            precondition(exit_code == item.2)
            precondition(fixture.health_checker.calls.count == 1)
            precondition(fixture.health_checker.calls[0].host == "127.0.0.1")
            precondition(fixture.health_checker.calls[0].port == 18_081)
        }
    }

    // 功能：验证匹配状态使用记录地址，并按健康结果分类 running/unhealthy。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；地址、报告或退出码不符时终止测试。
    private static func test_status_with_matching_state(test_root: URL) throws {
        let cases: [(HealthResult, DaemonStatus, CLIExitCode, Bool)] = [
            (.healthy, .running, .success, true),
            (.unreachable, .unhealthy, .stopped, false),
        ]
        for (index, item) in cases.enumerated() {
            let state = make_state(pid: 4_200 + Int32(index), host: "0.0.0.0")
            let fixture = try make_published_status_fixture(
                root: test_root.appendingPathComponent("matching-\(index)"),
                state: state,
                health_result: item.0,
                process_result: { _ in ProcessIdentity(
                    executable_path: state.executable_path,
                    process_started_at: state.process_started_at) })
            let (report, exit_code) = fixture.controller.status()
            precondition(report == StatusReport(
                state: item.1,
                managed: true,
                healthy: item.3,
                pid: state.pid,
                host: state.host,
                port: state.port,
                version: state.version))
            precondition(exit_code == item.2)
            precondition(fixture.health_checker.calls.count == 1)
            precondition(fixture.health_checker.calls[0].host == "127.0.0.1")
            precondition(fixture.health_checker.calls[0].port == state.port)
        }
    }

    // 功能：验证身份不匹配或不确定时报告 conflict 且不探测端口。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；不可信状态被当作托管实例时终止测试。
    private static func test_status_rejects_untrusted_identity(test_root: URL) throws {
        let state = make_state(pid: 4_300, host: "127.0.0.1")
        let process_results: [(Int32) throws -> ProcessIdentity?] = [
            { _ in ProcessIdentity(
                executable_path: state.executable_path,
                process_started_at: state.process_started_at + 1) },
            { _ in throw ControllerTestError.identity_uncertain },
        ]
        for (index, process_result) in process_results.enumerated() {
            let fixture = try make_published_status_fixture(
                root: test_root.appendingPathComponent("untrusted-\(index)"),
                state: state,
                health_result: .healthy,
                process_result: process_result)
            let (report, exit_code) = fixture.controller.status()
            precondition(report == StatusReport(
                state: .conflict,
                managed: false,
                healthy: nil,
                pid: state.pid,
                host: state.host,
                port: state.port,
                version: state.version))
            precondition(exit_code == .conflict)
            precondition(fixture.health_checker.calls.isEmpty)
        }
    }

    // 功能：验证稳定 JSON 始终编码七个字段且缺失值为 null。
    // 参数：无。
    // 返回值：无；字段被省略或值错误时终止测试。
    private static func test_status_json_keeps_null_fields() throws {
        let report = StatusReport(
            state: .stopped,
            managed: false,
            healthy: nil,
            pid: nil,
            host: nil,
            port: nil,
            version: nil)
        let data = try JSONEncoder().encode(report)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any] else {
            preconditionFailure("状态 JSON 根必须是 object")
        }
        precondition(Set(json.keys) == Set([
            "state", "managed", "healthy", "pid", "host", "port", "version",
        ]))
        precondition(json["state"] as? String == "stopped")
        precondition(json["managed"] as? Bool == false)
        for key in ["healthy", "pid", "host", "port", "version"] {
            precondition(json[key] is NSNull)
        }
    }

    // 功能：验证真实健康检查只接受 HTTP 200、object 根和 status ok。
    // 参数：无。
    // 返回值：无；健康或外部响应分类错误时终止测试。
    private static func test_url_session_health_checker() throws {
        let checker = URLSessionHealthChecker()
        let healthy = try OneShotHTTPServer(body: "{\"status\":\"ok\"}")
        healthy.start()
        precondition(checker.check(
            host: "127.0.0.1",
            port: healthy.port,
            timeout: 2) == .healthy)
        healthy.wait()

        let foreign = try OneShotHTTPServer(body: "{\"status\":\"wrong\"}")
        foreign.start()
        precondition(checker.check(
            host: "127.0.0.1",
            port: foreign.port,
            timeout: 2) == .foreign_response)
        foreign.wait()

        let unavailable = try OneShotHTTPServer(
            status_code: 503,
            body: "{\"status\":\"ok\"}")
        unavailable.start()
        precondition(checker.check(
            host: "127.0.0.1",
            port: unavailable.port,
            timeout: 2) == .foreign_response)
        unavailable.wait()

        let unreachable_port = try available_loopback_port()
        precondition(checker.check(
            host: "127.0.0.1",
            port: unreachable_port,
            timeout: 0.2) == .unreachable)
    }

    // 功能：验证身份不匹配或 EPERM 类不确定结果绝不发送 signal。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；不可信目标收到 signal 时终止测试。
    private static func test_stop_rejects_untrusted_identity(test_root: URL) throws {
        let state = make_state(pid: 4_400, host: "127.0.0.1")
        let current = identity(for: state)
        let cases: [[ProcessStep]] = [
            [.identity(ProcessIdentity(
                executable_path: current.executable_path,
                process_started_at: current.process_started_at + 1))],
            [.uncertain],
        ]
        for (index, steps) in cases.enumerated() {
            let fixture = try make_stop_fixture(
                root: test_root.appendingPathComponent("stop-untrusted-\(index)"),
                state: state,
                steps: steps)
            precondition(fixture.controller.stop(timeout: 0.05) == .conflict)
            precondition(fixture.signal_recorder.records().isEmpty)
        }
    }

    // 功能：验证匹配身份只收到一次 SIGTERM，原 PID 消失即成功。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；信号或退出码不符时终止测试。
    private static func test_stop_sends_one_sigterm_and_accepts_exit(
        test_root: URL
    ) throws {
        let state = make_state(pid: 4_500, host: "127.0.0.1")
        let fixture = try make_stop_fixture(
            root: test_root.appendingPathComponent("stop-exit"),
            state: state,
            steps: [.identity(identity(for: state)), .missing])
        precondition(fixture.controller.stop(timeout: 0.2) == .success)
        let records = fixture.signal_recorder.records()
        precondition(records.count == 1)
        precondition(records[0].pid == state.pid)
        precondition(records[0].signal_number == SIGTERM)
    }

    // 功能：验证 SIGTERM 后 PID 复用视为原 daemon 已停止。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；复用进程被继续等待或再次 signal 时终止测试。
    private static func test_stop_accepts_pid_reuse(test_root: URL) throws {
        let state = make_state(pid: 4_600, host: "127.0.0.1")
        let replacement = ProcessIdentity(
            executable_path: state.executable_path,
            process_started_at: state.process_started_at + 1)
        let fixture = try make_stop_fixture(
            root: test_root.appendingPathComponent("stop-reuse"),
            state: state,
            steps: [.identity(identity(for: state)), .identity(replacement)])
        precondition(fixture.controller.stop(timeout: 0.2) == .success)
        precondition(fixture.signal_recorder.records().count == 1)
    }

    // 功能：验证同一身份持续存活时超时且不升级为 SIGKILL。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；超时分类或信号数错误时终止测试。
    private static func test_stop_times_out_without_sigkill(test_root: URL) throws {
        let state = make_state(pid: 4_700, host: "127.0.0.1")
        let fixture = try make_stop_fixture(
            root: test_root.appendingPathComponent("stop-timeout"),
            state: state,
            steps: [.identity(identity(for: state))])
        precondition(fixture.controller.stop(timeout: 0.06) == .runtime)
        let records = fixture.signal_recorder.records()
        precondition(records.count == 1)
        precondition(records[0].signal_number == SIGTERM)
        precondition(!records.contains(where: { $0.signal_number == SIGKILL }))
    }

    // 功能：验证并发 daemon 启动只有一个 ready，
    // 且 ready 前已发布可探测状态。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；锁、状态、listener 或清理契约不符时终止测试。
    private static func test_concurrent_daemon_start_publishes_ready_state(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("daemon-concurrent")
        let port = try available_loopback_port()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate_path = root.appendingPathComponent("start.gate")
        let first = make_daemon_fixture(root: root, port: port)
        let helpers = try [
            start_serve_helper(root: root, port: port, gate_path: gate_path),
            start_serve_helper(root: root, port: port, gate_path: gate_path),
        ]
        try Data("go".utf8).write(to: gate_path)
        let helper_results = try helpers.map(wait_for_serve_helper)
        let raw_values = helper_results.map(\.exit_code).sorted()
        precondition(raw_values == [CLIExitCode.success.rawValue,
                                    CLIExitCode.conflict.rawValue])
        precondition(helper_results.allSatisfy { $0.signal_count == 0 })
        guard let state = try first.state_store.load() else {
            preconditionFailure("ready 返回前必须发布 daemon 状态")
        }
        defer { force_cleanup_daemon(pid: state.pid) }
        precondition(first.state_store.identity_matches(state) == .match)
        precondition(URLSessionHealthChecker().check(
            host: "127.0.0.1",
            port: state.port,
            timeout: 2) == .healthy)
        try assert_no_state_staging(paths: first.paths)
        precondition(first.controller.stop(timeout: 3) == .success)
        try wait_for_child_exit(pid: state.pid, timeout: 3)
        let final_state = try first.state_store.load()
        precondition(final_state == nil)
    }

    // 功能：验证确认 missing 的旧状态先移入夹具回收区，
    // 再允许新 daemon ready。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；stale 状态未回收或新实例未启动时终止测试。
    private static func test_stale_state_is_recycled_before_daemon_start(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("daemon-stale")
        let port = try available_loopback_port()
        let fixture = make_daemon_fixture(root: root, port: port)
        let stale_state = make_state(pid: Int32.max, host: "127.0.0.1")
        try fixture.state_store.publish(stale_state)
        let gate_path = root.appendingPathComponent("start.gate")
        try Data("go".utf8).write(to: gate_path)
        let helper = try start_serve_helper(
            root: root,
            port: port,
            gate_path: gate_path)
        let helper_result = try wait_for_serve_helper(helper)
        precondition(helper_result.exit_code == CLIExitCode.success.rawValue)
        guard let state = try fixture.state_store.load() else {
            preconditionFailure("stale 回收后必须发布新状态")
        }
        defer { force_cleanup_daemon(pid: state.pid) }
        precondition(state.pid != stale_state.pid)
        let recycled_names = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("recycled").path)
        precondition(recycled_names.contains(where: { $0.hasSuffix("-daemon.json") }))
        precondition(fixture.controller.stop(timeout: 3) == .success)
        try wait_for_child_exit(pid: state.pid, timeout: 3)
        let final_state = try fixture.state_store.load()
        precondition(final_state == nil)
    }

    // 功能：验证 child 退出时不会回收已被其他 owner 状态替换的文件。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；外部状态被 child 当作自身状态回收时终止测试。
    private static func test_child_preserves_replaced_state(test_root: URL) throws {
        let root = test_root.appendingPathComponent("daemon-replaced-state")
        let port = try available_loopback_port()
        let fixture = make_daemon_fixture(root: root, port: port)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate_path = root.appendingPathComponent("start.gate")
        try Data("go".utf8).write(to: gate_path)
        let helper = try start_serve_helper(
            root: root,
            port: port,
            gate_path: gate_path)
        let helper_result = try wait_for_serve_helper(helper)
        precondition(helper_result.exit_code == CLIExitCode.success.rawValue)
        guard let daemon_state = try fixture.state_store.load() else {
            preconditionFailure("ready daemon 必须存在状态")
        }
        defer { force_cleanup_daemon(pid: daemon_state.pid) }

        let inspector = DarwinProcessInspector()
        guard let parent_identity = try inspector.inspect(pid: getpid()) else {
            throw ControllerTestError.identity_uncertain
        }
        let replacement = DaemonState(
            pid: getpid(),
            executable_path: parent_identity.executable_path,
            process_started_at: parent_identity.process_started_at,
            instance_id: "replacement-owner",
            host: "127.0.0.1",
            port: port,
            version: GEMINI2API_VERSION)
        try fixture.state_store.publish(replacement)
        precondition(Darwin.kill(daemon_state.pid, SIGTERM) == 0)
        try wait_for_child_exit(pid: daemon_state.pid, timeout: 3)
        let retained_state = try fixture.state_store.load()
        precondition(retained_state == replacement)
    }

    // 功能：验证外部进程占用端口时返回 conflict，且不向 owner 发送 signal。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；owner 被影响或错误分类时终止测试。
    private static func test_port_owner_survives_daemon_conflict(
        test_root: URL
    ) throws {
        let owner = try start_port_owner()
        defer { stop_port_owner(owner) }
        let root = test_root.appendingPathComponent("daemon-port-conflict")
        let fixture = make_daemon_fixture(root: root, port: owner.port)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate_path = root.appendingPathComponent("start.gate")
        try Data("go".utf8).write(to: gate_path)
        let helper = try start_serve_helper(
            root: root,
            port: owner.port,
            gate_path: gate_path)
        let helper_result = try wait_for_serve_helper(helper)
        precondition(helper_result.exit_code == CLIExitCode.conflict.rawValue)
        precondition(helper_result.signal_count == 0)
        precondition(fixture.signal_recorder.records().isEmpty)
        precondition(Darwin.kill(owner.process.processIdentifier, 0) == 0)
        let state = try fixture.state_store.load()
        precondition(state == nil)
    }

    // 功能：验证 child 在写 readiness 前直接退出时父进程返回 runtime。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；EOF 被误判为 ready 时终止测试。
    private static func test_child_early_exit_returns_runtime(test_root: URL) throws {
        let root = test_root.appendingPathComponent("daemon-early-exit")
        let fixture = make_daemon_fixture(
            root: root,
            port: try available_loopback_port(),
            logger_factory: { _exit(27) })
        precondition(fixture.controller.serve_daemon(options: ServeOptions(
            host: nil,
            port: nil,
            model: nil,
            daemon: true)) == .runtime)
        let state = try fixture.state_store.load()
        precondition(state == nil)
    }

    // 功能：验证父进程等待 readiness 十秒超时后终止并回收精确 child。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；超时码、目标 PID 或 child 清理不符时终止测试。
    private static func test_readiness_timeout_cleans_child(test_root: URL) throws {
        let root = test_root.appendingPathComponent("daemon-timeout")
        let paths = make_runtime_paths(root: root)
        let signal_recorder = SignalRecorder(handler: Darwin.kill)
        let fixture = make_daemon_fixture(
            root: root,
            port: try available_loopback_port(),
            signal_recorder: signal_recorder,
            logger_factory: {
                Thread.sleep(forTimeInterval: 11)
                return DaemonLogger(
                    log_url: paths.log_path,
                    trash_item: make_fixture_recycler(root: root))
            })
        precondition(fixture.controller.serve_daemon(options: ServeOptions(
            host: nil,
            port: nil,
            model: nil,
            daemon: true)) == .runtime)
        let records = signal_recorder.records()
        precondition(records.count == 1)
        precondition(records[0].signal_number == SIGTERM)
        precondition(records[0].pid != getpid())
        errno = 0
        precondition(Darwin.kill(records[0].pid, 0) == -1 && errno == ESRCH)
        let state = try fixture.state_store.load()
        precondition(state == nil)
    }

    // 功能：创建未发布状态的 controller 测试夹具。
    // 参数：root 为隔离根；health_result 和 process_result 控制边界结果。
    // 返回值：controller 与可审计健康检查器。
    private static func make_status_fixture(
        root: URL,
        health_result: HealthResult,
        process_result: @escaping (Int32) throws -> ProcessIdentity?
    ) -> StatusFixture {
        let process_inspector = ControllerFakeProcessInspector(result: process_result)
        let health_checker = RecordingHealthChecker(result: health_result)
        let store = Store(config_root: root.appendingPathComponent("config"))
        store.host = "0.0.0.0"
        store.port = 18_081
        let paths = RuntimePaths(
            application_support_directory: root.appendingPathComponent("support"),
            logs_directory: root.appendingPathComponent("logs"))
        let state_store = RuntimeStateStore(
            paths: paths,
            process_inspector: process_inspector,
            trash_item: make_fixture_recycler(root: root))
        let controller = DaemonController(
            store: store,
            generator: ControllerFakeGenerator(),
            runtime_factory: { store, generator in
                GatewayRuntime(store: store, generator: generator)
            },
            state_store: state_store,
            logger_factory: {
                DaemonLogger(
                    log_url: paths.log_path,
                    trash_item: make_fixture_recycler(root: root))
            },
            health_checker: health_checker,
            process_inspector: process_inspector,
            signal_sender: { pid, signal_number in Darwin.kill(pid, signal_number) })
        return StatusFixture(
            controller: controller,
            health_checker: health_checker,
            state_store: state_store)
    }

    // 功能：创建并发布状态后返回 controller 测试夹具。
    // 参数：root、state 及两个可注入边界结果。
    // 返回值：带已发布状态的 controller 与健康检查器。
    private static func make_published_status_fixture(
        root: URL,
        state: DaemonState,
        health_result: HealthResult,
        process_result: @escaping (Int32) throws -> ProcessIdentity?
    ) throws -> StatusFixture {
        let fixture = make_status_fixture(
            root: root,
            health_result: health_result,
            process_result: process_result)
        try fixture.state_store.publish(state)
        return fixture
    }

    // 功能：创建带顺序身份结果和 signal recorder 的 stop 夹具。
    // 参数：root、state 及查询步骤为场景输入。
    // 返回值：已发布状态的 controller 与 recorder。
    private static func make_stop_fixture(
        root: URL,
        state: DaemonState,
        steps: [ProcessStep]
    ) throws -> StopFixture {
        let process_inspector = SequencedProcessInspector(steps: steps)
        let signal_recorder = SignalRecorder()
        let store = Store(config_root: root.appendingPathComponent("config"))
        let paths = RuntimePaths(
            application_support_directory: root.appendingPathComponent("support"),
            logs_directory: root.appendingPathComponent("logs"))
        let state_store = RuntimeStateStore(
            paths: paths,
            process_inspector: process_inspector,
            trash_item: make_fixture_recycler(root: root))
        try state_store.publish(state)
        let controller = DaemonController(
            store: store,
            generator: ControllerFakeGenerator(),
            runtime_factory: { store, generator in
                GatewayRuntime(store: store, generator: generator)
            },
            state_store: state_store,
            logger_factory: {
                DaemonLogger(
                    log_url: paths.log_path,
                    trash_item: make_fixture_recycler(root: root))
            },
            health_checker: RecordingHealthChecker(result: .unreachable),
            process_inspector: process_inspector,
            signal_sender: { pid, signal_number in
                signal_recorder.send(pid: pid, signal_number: signal_number)
            })
        return StopFixture(controller: controller, signal_recorder: signal_recorder)
    }

    // 功能：创建使用真实 runtime、进程查询和隔离文件树的 daemon 夹具。
    // 参数：root、port 为场景路径和端口；可覆盖 signal 与 logger 边界。
    // 返回值：controller、状态存储、路径和 recorder。
    private static func make_daemon_fixture(
        root: URL,
        port: Int,
        signal_recorder: SignalRecorder? = nil,
        logger_factory: (() throws -> DaemonLogger)? = nil
    ) -> DaemonFixture {
        let paths = make_runtime_paths(root: root)
        let process_inspector = DarwinProcessInspector()
        let recorder = signal_recorder ?? SignalRecorder(handler: Darwin.kill)
        let store = Store(config_root: root.appendingPathComponent("config"))
        store.host = "127.0.0.1"
        store.port = port
        let state_store = RuntimeStateStore(
            paths: paths,
            process_inspector: process_inspector,
            trash_item: make_fixture_recycler(root: root))
        let make_logger = logger_factory ?? {
            DaemonLogger(
                log_url: paths.log_path,
                trash_item: make_fixture_recycler(root: root))
        }
        let controller = DaemonController(
            store: store,
            generator: ControllerFakeGenerator(),
            runtime_factory: { store, generator in
                GatewayRuntime(store: store, generator: generator)
            },
            state_store: state_store,
            logger_factory: make_logger,
            health_checker: URLSessionHealthChecker(),
            process_inspector: process_inspector,
            signal_sender: { pid, signal_number in
                recorder.send(pid: pid, signal_number: signal_number)
            })
        return DaemonFixture(
            controller: controller,
            state_store: state_store,
            paths: paths,
            signal_recorder: recorder)
    }

    // 功能：从场景根动态派生受管 runtime 与日志路径。
    // 参数：root 为隔离场景根。
    // 返回值：RuntimePaths。
    private static func make_runtime_paths(root: URL) -> RuntimePaths {
        RuntimePaths(
            application_support_directory: root.appendingPathComponent("support"),
            logs_directory: root.appendingPathComponent("logs"))
    }

    // 功能：构造字段完整且版本有效的 daemon 状态。
    // 参数：pid 和 host 为测试分支输入。
    // 返回值：固定其余字段的状态。
    private static func make_state(pid: Int32, host: String) -> DaemonState {
        DaemonState(
            pid: pid,
            executable_path: "/tmp/gemini2api-test",
            process_started_at: 1_788_520_000_123_456,
            instance_id: "controller-test-instance",
            host: host,
            port: 18_082,
            version: GEMINI2API_VERSION)
    }

    // 功能：从测试状态提取与其完全匹配的进程身份。
    // 参数：state 为字段完整的 daemon 状态。
    // 返回值：对应路径和启动时间身份。
    private static func identity(for state: DaemonState) -> ProcessIdentity {
        ProcessIdentity(
            executable_path: state.executable_path,
            process_started_at: state.process_started_at)
    }

    // 功能：短暂占用系统分配端口后释放。
    // 参数：无。
    // 返回值：可用于下一次监听的 loopback 端口。
    private static func available_loopback_port() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControllerTestError.socket_failed }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bind_result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bind_result == 0 else { throw ControllerTestError.socket_failed }
        var assigned = sockaddr_in()
        var assigned_length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name_result = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &assigned_length)
            }
        }
        guard name_result == 0 else { throw ControllerTestError.socket_failed }
        return Int(in_port_t(bigEndian: assigned.sin_port))
    }

    // 功能：断言 runtime 目录没有遗留 daemon 状态 staging。
    // 参数：paths 为测试场景路径。
    // 返回值：无；发现 staging 时终止测试。
    private static func assert_no_state_staging(paths: RuntimePaths) throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: paths.runtime_directory.path)
        precondition(!names.contains(where: {
            $0.hasPrefix("daemon.json.") && $0.hasSuffix(".staging")
        }))
    }

    // 功能：等待并回收当前测试进程直接 fork 的指定 child。
    // 参数：pid 为精确 child；timeout 为最长等待秒数。
    // 返回值：无；未能按时回收时抛错。
    private static func wait_for_child_exit(pid: Int32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return }
            if result == -1 && errno == ECHILD {
                errno = 0
                if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ControllerTestError.identity_uncertain
    }

    // 功能：失败清理阶段只终止并回收已记录的精确 daemon PID。
    // 参数：pid 为当前测试启动的 daemon child。
    // 返回值：无；先 SIGTERM，必要时才以 SIGKILL 防止 helper 泄漏。
    private static func force_cleanup_daemon(pid: Int32) {
        guard pid > 1, pid != getpid() else { return }
        _ = Darwin.kill(pid, SIGTERM)
        if (try? wait_for_child_exit(pid: pid, timeout: 2)) != nil { return }
        _ = Darwin.kill(pid, SIGKILL)
        _ = try? wait_for_child_exit(pid: pid, timeout: 2)
    }

    // 功能：启动一个独立 CLI helper，等待 gate 后执行真实 serve --daemon。
    // 参数：root、port 为共享场景；gate_path 为并发起跑文件。
    // 返回值：可等待且可读取固定结果的 helper。
    private static func start_serve_helper(
        root: URL,
        port: Int,
        gate_path: URL
    ) throws -> ServeHelper {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--serve-helper",
            root.path,
            String(port),
            gate_path.path,
        ]
        let output_pipe = Pipe()
        process.standardOutput = output_pipe
        process.standardError = output_pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        return ServeHelper(
            process: process,
            completed: completed,
            output_pipe: output_pipe)
    }

    // 功能：等待并解析独立 serve helper 的固定字段结果。
    // 参数：helper 为本测试启动的精确进程。
    // 返回值：CLI raw exit 与 signal 计数。
    private static func wait_for_serve_helper(
        _ helper: ServeHelper
    ) throws -> (exit_code: Int32, signal_count: Int) {
        guard helper.completed.wait(timeout: .now() + 15) == .success else {
            _ = Darwin.kill(helper.process.processIdentifier, SIGTERM)
            if helper.completed.wait(timeout: .now() + 2) != .success {
                _ = Darwin.kill(helper.process.processIdentifier, SIGKILL)
                _ = helper.completed.wait(timeout: .now() + 2)
            }
            throw ControllerTestError.identity_uncertain
        }
        helper.process.waitUntilExit()
        let data = helper.output_pipe.fileHandleForReading.readDataToEndOfFile()
        let fields = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard helper.process.terminationStatus == 0,
              fields.count == 4,
              fields[0] == "EXIT",
              let exit_code = Int32(fields[1]),
              fields[2] == "SIGNALS",
              let signal_count = Int(fields[3]) else {
            throw ControllerTestError.socket_failed
        }
        return (exit_code, signal_count)
    }

    // 功能：在独立进程中等待起跑 gate，再执行一次真实 daemon 启动。
    // 参数：root、port、gate 路径来自命令行。
    // 返回值：无；固定字段输出由父测试解析。
    private static func run_serve_helper() throws {
        guard CommandLine.arguments.count == 5,
              let port = Int(CommandLine.arguments[3]) else {
            throw ControllerTestError.socket_failed
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let gate_path = URL(fileURLWithPath: CommandLine.arguments[4])
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: gate_path.path) {
            guard deadline.timeIntervalSinceNow > 0 else {
                throw ControllerTestError.identity_uncertain
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let signal_recorder = SignalRecorder(handler: Darwin.kill)
        let fixture = make_daemon_fixture(
            root: root,
            port: port,
            signal_recorder: signal_recorder)
        let exit_code = fixture.controller.serve_daemon(options: ServeOptions(
            host: "127.0.0.1",
            port: port,
            model: nil,
            daemon: true))
        write_stdout(
            "EXIT \(exit_code.rawValue) SIGNALS \(signal_recorder.records().count)\n")
    }

    // 功能：启动独立测试进程占用随机 loopback 端口。
    // 参数：无。
    // 返回值：已报告 ready 的 owner 进程及端口。
    private static func start_port_owner() throws -> PortOwner {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--port-owner-helper"]
        let output_pipe = Pipe()
        process.standardOutput = output_pipe
        process.standardError = output_pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        do {
            let line = try read_line(output_pipe.fileHandleForReading)
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  fields[0] == "READY",
                  let port = Int(fields[1]) else {
                throw ControllerTestError.socket_failed
            }
            return PortOwner(process: process, completed: completed, port: port)
        } catch {
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            _ = completed.wait(timeout: .now() + 2)
            throw error
        }
    }

    // 功能：精确终止并等待端口 owner helper。
    // 参数：owner 为本测试启动的独立进程。
    // 返回值：无；超时才升级 SIGKILL 防止测试泄漏。
    private static func stop_port_owner(_ owner: PortOwner) {
        guard owner.process.isRunning else { return }
        _ = Darwin.kill(owner.process.processIdentifier, SIGTERM)
        if owner.completed.wait(timeout: .now() + 2) == .success { return }
        _ = Darwin.kill(owner.process.processIdentifier, SIGKILL)
        _ = owner.completed.wait(timeout: .now() + 2)
    }

    // 功能：作为独立 helper 绑定随机端口并保持存活。
    // 参数：无。
    // 返回值：收到测试进程 signal 后由系统终止。
    private static func run_port_owner_helper() throws {
        let descriptor = try make_listening_socket()
        defer { _ = Darwin.close(descriptor.0) }
        write_stdout("READY \(descriptor.1)\n")
        while true { _ = pause() }
    }

    // 功能：创建绑定随机 loopback 端口的监听 socket。
    // 参数：无。
    // 返回值：descriptor 与系统分配端口。
    private static func make_listening_socket() throws -> (Int32, Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControllerTestError.socket_failed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bind_result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bind_result == 0, Darwin.listen(descriptor, 1) == 0 else {
            _ = Darwin.close(descriptor)
            throw ControllerTestError.socket_failed
        }
        var assigned = sockaddr_in()
        var assigned_length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name_result = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &assigned_length)
            }
        }
        guard name_result == 0 else {
            _ = Darwin.close(descriptor)
            throw ControllerTestError.socket_failed
        }
        return (descriptor, Int(in_port_t(bigEndian: assigned.sin_port)))
    }

    // 功能：逐 byte 读取 helper readiness 单行。
    // 参数：handle 为 helper stdout pipe。
    // 返回值：包含换行的 UTF-8 文本。
    private static func read_line(_ handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                throw ControllerTestError.socket_failed
            }
            data.append(byte)
            if byte[0] == 0x0A { return String(decoding: data, as: UTF8.self) }
        }
    }

    // 功能：完整写入 helper 标准输出。
    // 参数：text 为固定 readiness 文本。
    // 返回值：无。
    private static func write_stdout(_ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    STDOUT_FILENO,
                    address.advanced(by: offset),
                    buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    // 功能：创建仅在夹具内移动文件的回收闭包。
    // 参数：root 为当前场景目录。
    // 返回值：把目标移动到 root/recycled 的闭包。
    private static func make_fixture_recycler(root: URL) -> (URL) throws -> Void {
        return { url in
            let recycled = root.appendingPathComponent("recycled", isDirectory: true)
            try FileManager.default.createDirectory(
                at: recycled,
                withIntermediateDirectories: true)
            let destination = recycled.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    // 功能：把完整测试目录移入当前用户废纸篓。
    // 参数：root 为唯一测试目录。
    // 返回值：无；失败时输出固定诊断，不永久删除。
    private static func recycle_test_root_best_effort(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            var recycled_url: NSURL?
            try FileManager.default.trashItem(at: root, resultingItemURL: &recycled_url)
        } catch {
            FileHandle.standardError.write(Data("controller 测试目录回收失败\n".utf8))
        }
    }
}

private final class OneShotHTTPServer {
    let port: Int
    private let descriptor: Int32
    private let status_code: Int
    private let body: String
    private let completed = DispatchSemaphore(value: 0)

    // 功能：创建只响应一次的 loopback HTTP server。
    // 参数：status_code 和 body 为固定 HTTP 响应。
    // 返回值：持有随机监听端口的 server。
    init(status_code: Int = 200, body: String) throws {
        self.status_code = status_code
        self.body = body
        let local_descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard local_descriptor >= 0 else { throw ControllerTestError.socket_failed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bind_result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    local_descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bind_result == 0, Darwin.listen(local_descriptor, 1) == 0 else {
            _ = Darwin.close(local_descriptor)
            throw ControllerTestError.socket_failed
        }
        var assigned = sockaddr_in()
        var assigned_length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name_result = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(local_descriptor, $0, &assigned_length)
            }
        }
        guard name_result == 0 else {
            _ = Darwin.close(local_descriptor)
            throw ControllerTestError.socket_failed
        }
        descriptor = local_descriptor
        port = Int(in_port_t(bigEndian: assigned.sin_port))
    }

    // 功能：后台接受一个连接并返回固定 JSON。
    // 参数：无。
    // 返回值：无；结束时发布 completed。
    func start() {
        DispatchQueue.global().async { [self] in
            defer {
                _ = Darwin.close(descriptor)
                completed.signal()
            }
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { _ = Darwin.close(client) }
            var request = [UInt8](repeating: 0, count: 2_048)
            _ = Darwin.read(client, &request, request.count)
            let response = """
            HTTP/1.1 \(status_code) Test\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            response.withCString { pointer in
                _ = Darwin.write(client, pointer, strlen(pointer))
            }
        }
    }

    // 功能：等待单次响应处理完成。
    // 参数：无。
    // 返回值：无；两秒未结束时终止测试。
    func wait() {
        precondition(completed.wait(timeout: .now() + 2) == .success)
    }
}
