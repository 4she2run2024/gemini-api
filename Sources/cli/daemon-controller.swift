// 用途：编排 Gemini2API daemon 的健康状态、安全停止和后台生命周期。
// 使用方法：注入已加载 Store、runtime/state/logger 与系统边界后，调用对应
// 命令方法。

import Darwin
import Foundation

@_silgen_name("fork")
private func system_fork() -> pid_t

private let HEALTH_CHECK_TIMEOUT_SECONDS: TimeInterval = 2
private let STOP_POLL_INTERVAL_SECONDS: TimeInterval = 0.02
private let DAEMON_READINESS_TIMEOUT_SECONDS: TimeInterval = 10

private enum DaemonReadiness: UInt8 {
    case ready = 1
    case conflict = 2
    case runtime_failure = 3
}

private enum ParentReadinessResult {
    case message(DaemonReadiness)
    case early_exit
    case timeout
}

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

    private enum CodingKeys: String, CodingKey {
        case state
        case managed
        case healthy
        case pid
        case host
        case port
        case version
    }

    // 功能：编码稳定状态对象，Optional 缺失值保留为 null。
    // 参数：encoder 为目标编码器。
    // 返回值：无；编码失败时抛出编码器错误。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(managed, forKey: .managed)
        try encode_optional(healthy, forKey: .healthy, into: &container)
        try encode_optional(pid, forKey: .pid, into: &container)
        try encode_optional(host, forKey: .host, into: &container)
        try encode_optional(port, forKey: .port, into: &container)
        try encode_optional(version, forKey: .version, into: &container)
    }

    // 功能：把 Optional 按值或显式 null 编入 keyed container。
    // 参数：value 为可选值；key 为字段；container 为目标容器。
    // 返回值：无；编码失败时抛出编码器错误。
    private func encode_optional<Value: Encodable>(
        _ value: Value?,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

protocol HealthChecking {
    // 功能：同步探测 Gemini2API 无鉴权根路由。
    // 参数：host、port 为目标地址；timeout 为最长等待秒数。
    // 返回值：健康、不可达或外部响应分类。
    func check(host: String, port: Int, timeout: TimeInterval) -> HealthResult
}

enum HealthResult: Equatable {
    case healthy
    case unreachable
    case foreign_response
}

private final class HealthResultBox {
    private let lock = NSLock()
    private var result: HealthResult?

    // 功能：线程安全保存健康检查结果。
    // 参数：result 为完成回调产生的分类。
    // 返回值：无。
    func store(_ result: HealthResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    // 功能：线程安全读取健康检查结果。
    // 参数：无。
    // 返回值：尚未完成时为 nil。
    func load() -> HealthResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

struct URLSessionHealthChecker: HealthChecking {
    // 功能：以临时 URLSession 同步探测 GET / 并严格验证响应结构。
    // 参数：host、port 为目标地址；timeout 为最长等待秒数。
    // 返回值：仅 HTTP 200 object 且 status ok 时为 healthy。
    func check(host: String, port: Int, timeout: TimeInterval) -> HealthResult {
        guard timeout > 0,
              timeout.isFinite,
              (1...65_535).contains(port),
              let url = make_url(host: host, port: port) else {
            return .unreachable
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let completed = DispatchSemaphore(value: 0)
        let result_box = HealthResultBox()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let task = session.dataTask(with: request) { data, response, error in
            result_box.store(classify_response(data: data, response: response, error: error))
            completed.signal()
        }
        task.resume()

        guard completed.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            return .unreachable
        }
        session.finishTasksAndInvalidate()
        return result_box.load() ?? .unreachable
    }

    // 功能：经 URLComponents 构造不拼接用户文本的 HTTP 根地址。
    // 参数：host、port 为经过配置层加载的目标地址。
    // 返回值：合法 URL；无法构造时为 nil。
    private func make_url(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }
}

// 功能：把 URLSession 回调严格分类为健康、不可达或外部响应。
// 参数：data、response、error 为一次 GET / 的完成结果。
// 返回值：网络失败为 unreachable，协议不符为 foreign_response。
private func classify_response(
    data: Data?,
    response: URLResponse?,
    error: Error?
) -> HealthResult {
    guard error == nil else { return .unreachable }
    guard let http_response = response as? HTTPURLResponse,
          let data else {
        return .unreachable
    }
    guard http_response.statusCode == 200,
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          root["status"] as? String == "ok" else {
        return .foreign_response
    }
    return .healthy
}

final class DaemonController {
    private let store: Store
    private let generator: TextGenerating
    private let runtime_factory: (Store, TextGenerating) -> GatewayRuntime
    private let state_store: RuntimeStateStore
    private let logger_factory: () throws -> DaemonLogger
    private let health_checker: HealthChecking
    private let process_inspector: ProcessInspecting
    private let signal_sender: (Int32, Int32) -> Int32

    // 功能：创建可测试的 daemon 生命周期编排器。
    // 参数：store 为已加载配置；generator 仅供 runtime 构造；
    // 其余参数为边界依赖。
    // 返回值：初始化后的编排器。
    init(
        store: Store,
        generator: TextGenerating,
        runtime_factory: @escaping (Store, TextGenerating) -> GatewayRuntime,
        state_store: RuntimeStateStore,
        logger_factory: @escaping () throws -> DaemonLogger,
        health_checker: HealthChecking,
        process_inspector: ProcessInspecting,
        signal_sender: @escaping (Int32, Int32) -> Int32
    ) {
        self.store = store
        self.generator = generator
        self.runtime_factory = runtime_factory
        self.state_store = state_store
        self.logger_factory = logger_factory
        self.health_checker = health_checker
        self.process_inspector = process_inspector
        self.signal_sender = signal_sender
    }

    // 功能：持锁解析当前状态，再 fork 并等待 child 完整 ready。
    // 参数：options 为本次只驻留内存的 serve 覆盖，必须标记 daemon。
    // 返回值：ready、冲突或运行时失败对应的 CLI 退出码。
    func serve_daemon(options: ServeOptions) -> CLIExitCode {
        guard options.daemon else { return .usage }
        let daemon_lock: DaemonLock
        do {
            daemon_lock = try state_store.acquire_lock()
        } catch {
            return .conflict
        }

        do {
            if let existing_state = try state_store.load() {
                switch state_store.identity_matches(existing_state) {
                case .missing:
                    try state_store.recycle_stale_state()
                case .match, .mismatch, .uncertain:
                    return .conflict
                }
            }
        } catch {
            return .conflict
        }

        var pipe_descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&pipe_descriptors) == 0 else { return .runtime }
        set_close_on_exec_best_effort(pipe_descriptors[0])
        set_close_on_exec_best_effort(pipe_descriptors[1])

        let child_pid = system_fork()
        guard child_pid >= 0 else {
            _ = Darwin.close(pipe_descriptors[0])
            _ = Darwin.close(pipe_descriptors[1])
            return .runtime
        }
        if child_pid == 0 {
            _ = Darwin.close(pipe_descriptors[0])
            run_daemon_child(
                options: options,
                readiness_descriptor: pipe_descriptors[1],
                daemon_lock: daemon_lock)
        }

        _ = Darwin.close(pipe_descriptors[1])
        let readiness = wait_for_parent_readiness(
            descriptor: pipe_descriptors[0],
            timeout: DAEMON_READINESS_TIMEOUT_SECONDS)
        _ = Darwin.close(pipe_descriptors[0])
        switch readiness {
        case .message(.ready):
            return .success
        case .message(.conflict):
            reap_child(child_pid)
            return .conflict
        case .message(.runtime_failure), .early_exit:
            reap_child(child_pid)
            return .runtime
        case .timeout:
            _ = signal_sender(child_pid, SIGTERM)
            reap_child(child_pid)
            return .runtime
        }
    }

    // 功能：结合状态身份和根路由健康结果生成稳定报告。
    // 参数：无；地址来自 daemon 状态或已加载配置。
    // 返回值：状态报告及对应 CLI 退出码。
    func status() -> (StatusReport, CLIExitCode) {
        let loaded_state: DaemonState?
        do {
            loaded_state = try state_store.load()
        } catch {
            return (StatusReport(
                state: .conflict,
                managed: false,
                healthy: nil,
                pid: nil,
                host: nil,
                port: nil,
                version: nil), .conflict)
        }

        guard let state = loaded_state else {
            return status_without_state()
        }
        let base_report = StatusReport(
            state: .conflict,
            managed: false,
            healthy: nil,
            pid: state.pid,
            host: state.host,
            port: state.port,
            version: state.version)
        switch state_store.identity_matches(state) {
        case .match:
            return status_for_matching_state(state)
        case .missing:
            return (StatusReport(
                state: .stopped,
                managed: false,
                healthy: false,
                pid: state.pid,
                host: state.host,
                port: state.port,
                version: state.version), .stopped)
        case .mismatch, .uncertain:
            return (base_report, .conflict)
        }
    }

    // 功能：只对完整匹配的托管进程发送一次 SIGTERM，并等待原身份消失。
    // 参数：timeout 为最长等待秒数。
    // 返回值：停止成功、未运行、冲突或运行时超时退出码。
    func stop(timeout: TimeInterval) -> CLIExitCode {
        guard timeout > 0, timeout.isFinite else { return .runtime }
        let loaded_state: DaemonState?
        do {
            loaded_state = try state_store.load()
        } catch {
            return .conflict
        }
        guard let state = loaded_state else { return .stopped }
        switch state_store.identity_matches(state) {
        case .match:
            break
        case .missing:
            return .stopped
        case .mismatch, .uncertain:
            return .conflict
        }

        errno = 0
        guard signal_sender(state.pid, SIGTERM) == 0 else {
            return errno == ESRCH ? .success : .runtime
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                guard let identity = try process_inspector.inspect(pid: state.pid) else {
                    return .success
                }
                guard identity.executable_path == state.executable_path,
                      identity.process_started_at == state.process_started_at else {
                    return .success
                }
            } catch {
                // 身份暂时无法确定时不得向 PID 发送第二次信号。
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .runtime }
            Thread.sleep(forTimeInterval: min(STOP_POLL_INTERVAL_SECONDS, remaining))
        }
    }

    // 功能：在无 daemon 状态时探测加载配置中的固定 endpoint。
    // 参数：无。
    // 返回值：stopped、unmanaged 或 conflict 报告与退出码。
    private func status_without_state() -> (StatusReport, CLIExitCode) {
        let result = health_checker.check(
            host: health_probe_host(store.host),
            port: store.port,
            timeout: HEALTH_CHECK_TIMEOUT_SECONDS)
        let classification: (DaemonStatus, CLIExitCode, Bool)
        switch result {
        case .healthy:
            classification = (.unmanaged, .conflict, true)
        case .unreachable:
            classification = (.stopped, .stopped, false)
        case .foreign_response:
            classification = (.conflict, .conflict, false)
        }
        return (StatusReport(
            state: classification.0,
            managed: false,
            healthy: classification.2,
            pid: nil,
            host: store.host,
            port: store.port,
            version: nil), classification.1)
    }

    // 功能：只使用可信状态地址探测匹配 daemon 的健康性。
    // 参数：state 为已核验进程身份的状态。
    // 返回值：running 或 unhealthy 报告与退出码。
    private func status_for_matching_state(
        _ state: DaemonState
    ) -> (StatusReport, CLIExitCode) {
        let result = health_checker.check(
            host: health_probe_host(state.host),
            port: state.port,
            timeout: HEALTH_CHECK_TIMEOUT_SECONDS)
        let is_healthy = result == .healthy
        return (StatusReport(
            state: is_healthy ? .running : .unhealthy,
            managed: true,
            healthy: is_healthy,
            pid: state.pid,
            host: state.host,
            port: state.port,
            version: state.version), is_healthy ? .success : .stopped)
    }

    // 功能：把全接口监听地址转换为 loopback 健康探测地址。
    // 参数：host 为报告中保留的原始监听地址。
    // 返回值：0.0.0.0 对应 127.0.0.1，其余地址原样返回。
    private func health_probe_host(_ host: String) -> String {
        host == "0.0.0.0" ? "127.0.0.1" : host
    }

    // 功能：在 fork child 中按安全顺序启动 daemon，并以固定 byte 报告结果。
    // 参数：options 为覆盖；readiness_descriptor 为 pipe 写端；
    // daemon_lock 保持持锁。
    // 返回值：不返回；最终调用 _exit。
    private func run_daemon_child(
        options: ServeOptions,
        readiness_descriptor: Int32,
        daemon_lock: DaemonLock
    ) -> Never {
        _ = daemon_lock
        guard setsid() >= 0, redirect_stdin_to_null() else {
            write_readiness(.runtime_failure, to: readiness_descriptor)
            _ = Darwin.close(readiness_descriptor)
            _exit(CLIExitCode.runtime.rawValue)
        }

        var logger: DaemonLogger?
        var runtime: GatewayRuntime?
        var published_state: DaemonState?
        var outcome = DaemonReadiness.runtime_failure
        var startup_stage = "startup"
        do {
            let child_logger = try logger_factory()
            logger = child_logger
            try child_logger.redirect_standard_streams()
            child_logger.write(
                .info,
                event: "daemon_starting",
                fields: ["stage": "startup", "pid": String(getpid())])

            let child_runtime = runtime_factory(store, generator)
            runtime = child_runtime
            let endpoint = try child_runtime.configure(RuntimeOverrides(
                host: options.host,
                port: options.port,
                model: options.model))
            child_runtime.install_termination_handlers()
            try child_runtime.start(readiness_timeout: DAEMON_READINESS_TIMEOUT_SECONDS)
            child_logger.start_rotation_monitor()
            startup_stage = "listening"

            guard let identity = try process_inspector.inspect(pid: getpid()) else {
                throw DaemonChildError.identity_unavailable
            }
            let state = DaemonState(
                pid: getpid(),
                executable_path: identity.executable_path,
                process_started_at: identity.process_started_at,
                instance_id: UUID().uuidString,
                host: endpoint.host,
                port: endpoint.port,
                version: GEMINI2API_VERSION)
            try state_store.publish(state)
            published_state = state
            child_logger.write(
                .info,
                event: "daemon_ready",
                fields: [
                    "stage": "listening",
                    "host": endpoint.host,
                    "port": String(endpoint.port),
                    "pid": String(getpid()),
                ])
            outcome = .ready
        } catch GatewayRuntimeError.listener_failed {
            outcome = .conflict
        } catch {
            outcome = .runtime_failure
        }

        if outcome != .ready {
            logger?.write(
                .error,
                event: "daemon_error",
                fields: [
                    "stage": startup_stage,
                    "pid": String(getpid()),
                    "error_category": "system_call_failed",
                ])
        }

        write_readiness(outcome, to: readiness_descriptor)
        _ = Darwin.close(readiness_descriptor)
        guard outcome == .ready, let published_state else {
            runtime?.stop()
            logger?.stop()
            if let published_state {
                recycle_state_if_owned(published_state)
            }
            _exit(outcome == .conflict
                ? CLIExitCode.conflict.rawValue
                : CLIExitCode.runtime.rawValue)
        }

        runtime?.wait_until_termination()
        runtime?.stop()
        logger?.stop()
        recycle_state_if_owned(published_state)
        _exit(CLIExitCode.success.rawValue)
    }

    // 功能：退出前重新核验完整状态与当前身份，
    // 只回收本 child 发布的状态。
    // 参数：owned_state 为本 child 成功发布的不可变状态。
    // 返回值：无；读取、核验或回收失败均保留现状。
    private func recycle_state_if_owned(_ owned_state: DaemonState) {
        guard let current_state = try? state_store.load(),
              current_state == owned_state,
              state_store.identity_matches(current_state) == .match else {
            return
        }
        try? state_store.recycle_stale_state()
    }
}

private enum DaemonChildError: Error {
    case identity_unavailable
}

// 功能：让 daemon child 的 stdin 指向操作系统空设备。
// 参数：无。
// 返回值：打开和 dup2 均成功时为 true。
private func redirect_stdin_to_null() -> Bool {
    let descriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    return Darwin.dup2(descriptor, STDIN_FILENO) >= 0
}

// 功能：为 readiness pipe 设置 close-on-exec，避免未来 exec 泄漏。
// 参数：descriptor 为 pipe fd。
// 返回值：无；当前进程不 exec，因此失败不改变协议正确性。
private func set_close_on_exec_best_effort(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0 else { return }
    _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
}

// 功能：向 pipe 完整写入一个固定 readiness 枚举 byte。
// 参数：message 为固定分类；descriptor 为 child pipe 写端。
// 返回值：无；父进程消失时尽快结束 child 启动路径。
private func write_readiness(_ message: DaemonReadiness, to descriptor: Int32) {
    var byte = message.rawValue
    while true {
        let count = withUnsafePointer(to: &byte) { pointer in
            Darwin.write(descriptor, pointer, 1)
        }
        if count < 0 && errno == EINTR { continue }
        return
    }
}

// 功能：在固定期限内读取一个 readiness byte，并区分 EOF 与 timeout。
// 参数：descriptor 为 parent pipe 读端；timeout 为最长秒数。
// 返回值：固定消息、child early exit 或 timeout。
private func wait_for_parent_readiness(
    descriptor: Int32,
    timeout: TimeInterval
) -> ParentReadinessResult {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return .timeout }
        let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
        var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let poll_result = Darwin.poll(&item, 1, max(milliseconds, 1))
        if poll_result == 0 { return .timeout }
        if poll_result < 0 {
            if errno == EINTR { continue }
            return .early_exit
        }

        var byte: UInt8 = 0
        let count = withUnsafeMutablePointer(to: &byte) { pointer in
            Darwin.read(descriptor, pointer, 1)
        }
        if count < 0 && errno == EINTR { continue }
        guard count == 1, let message = DaemonReadiness(rawValue: byte) else {
            return .early_exit
        }
        return .message(message)
    }
}

// 功能：同步回收一个确认属于当前 parent 的已退出 child。
// 参数：pid 为 fork 返回的精确 child PID。
// 返回值：无；EINTR 时重试，其余错误结束。
private func reap_child(_ pid: Int32) {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        if errno != EINTR { return }
    }
}
