// 用途：提供 daemon 标准流日志与可恢复轮转。
// 使用方法：由 daemon controller 以 RuntimePaths.log_path 构造并启动。

import Darwin
import Foundation

private let DAEMON_LOG_DIRECTORY_MODE: mode_t = 0o700
private let DAEMON_LOG_FILE_MODE: mode_t = 0o600
private let ROTATION_INTERVAL_SECONDS: TimeInterval = 1

enum DaemonLogLevel: String {
    case info
    case error
}

private enum DaemonLoggerError: Error {
    case descriptor_rollback_failed
    case invalid_log_directory
    case invalid_log_file
    case system_call_failed
}

struct DaemonLoggerSystemCalls {
    let replace_descriptor: (Int32, Int32) -> Int32
    let swap_paths: (String, String) -> Int32

    // 功能：构造可测试的 fd 替换与路径交换边界。
    // 参数：replace_descriptor 包装 dup2；swap_paths 包装 RENAME_SWAP。
    // 返回值：初始化后的 syscall 集合。
    init(
        replace_descriptor: @escaping (Int32, Int32) -> Int32,
        swap_paths: @escaping (String, String) -> Int32
    ) {
        self.replace_descriptor = replace_descriptor
        self.swap_paths = swap_paths
    }

    // 功能：提供生产环境真实 Darwin syscall。
    // 参数：无。
    // 返回值：真实 syscall 集合。
    static func live() -> DaemonLoggerSystemCalls {
        DaemonLoggerSystemCalls(
            replace_descriptor: { Darwin.dup2($0, $1) },
            swap_paths: { canonical_path, staging_path in
                canonical_path.withCString { canonical_pointer in
                    staging_path.withCString { staging_pointer in
                        renamex_np(
                            canonical_pointer,
                            staging_pointer,
                            UInt32(RENAME_SWAP))
                    }
                }
            })
    }
}

final class DaemonLogger {
    private static let allowed_events: Set<String> = [
        "daemon_starting", "daemon_ready", "request_completed", "request_retry",
        "daemon_error", "rotation_error", "daemon_stopping",
    ]
    private static let allowed_stages: Set<String> = [
        "startup", "listening", "request", "retry", "rotation", "shutdown",
    ]
    private static let allowed_error_categories: Set<String> = [
        "none", "invalid_log_directory", "invalid_log_file", "system_call_failed",
        "rename_swap_failed", "descriptor_rollback_failed", "trash_failed",
        "rotation_failed",
    ]
    private static let ordered_field_names = [
        "stage", "host", "port", "pid", "http_status", "error_category", "retry_count",
    ]

    private let log_url: URL
    private let maximum_bytes: UInt64
    private let trash_item: (URL) throws -> Void
    private let system_calls: DaemonLoggerSystemCalls
    private let state_lock = NSLock()
    private let monitor_group = DispatchGroup()
    private let rotation_queue: DispatchQueue
    private let rotation_queue_key = DispatchSpecificKey<UInt8>()
    private var rotation_timer: DispatchSourceTimer?
    private var monitor_generation: UInt64 = 0
    private var is_stopping = false
    private var is_stopped = false

    // 功能：构造使用动态日志路径、大小阈值和可恢复回收器的
    // daemon logger。
    // 参数：log_url 为 RuntimePaths.log_path；maximum_bytes 为轮转阈值；
    // trash_item 把旧日志移入废纸篓。
    // 返回值：初始化后的 logger。
    convenience init(
        log_url: URL,
        maximum_bytes: UInt64 = 5 * 1024 * 1024,
        trash_item: @escaping (URL) throws -> Void
    ) {
        self.init(
            log_url: log_url,
            maximum_bytes: maximum_bytes,
            trash_item: trash_item,
            system_calls: .live())
    }

    // 功能：构造注入 syscall 的 logger，供确定性失败测试使用。
    // 参数：前三项与生产 initializer 相同；system_calls 为 syscall 集合。
    // 返回值：初始化后的 logger。
    init(
        log_url: URL,
        maximum_bytes: UInt64,
        trash_item: @escaping (URL) throws -> Void,
        system_calls: DaemonLoggerSystemCalls
    ) {
        self.log_url = log_url
        self.maximum_bytes = maximum_bytes
        self.trash_item = trash_item
        self.system_calls = system_calls
        rotation_queue = DispatchQueue(label: "gemini2api.daemon-log-rotation")
        rotation_queue.setSpecific(key: rotation_queue_key, value: 1)
    }

    // 功能：以 0700/0600 创建日志位置，并把 stdout/stderr 原子指向日志 fd。
    // 参数：无。
    // 返回值：无；目录、文件或 fd 操作失败时抛出分类错误。
    func redirect_standard_streams() throws {
        state_lock.lock()
        defer { state_lock.unlock() }
        try ensure_log_directory()
        let descriptor = try open_secure_log(log_url, exclusive: false)
        defer { _ = Darwin.close(descriptor) }

        let saved_stdout = Darwin.dup(STDOUT_FILENO)
        guard saved_stdout >= 0 else { throw DaemonLoggerError.system_call_failed }
        let saved_stderr = Darwin.dup(STDERR_FILENO)
        guard saved_stderr >= 0 else {
            _ = Darwin.close(saved_stdout)
            throw DaemonLoggerError.system_call_failed
        }
        defer {
            _ = Darwin.close(saved_stdout)
            _ = Darwin.close(saved_stderr)
        }

        guard system_calls.replace_descriptor(descriptor, STDOUT_FILENO) >= 0 else {
            throw DaemonLoggerError.system_call_failed
        }
        guard system_calls.replace_descriptor(descriptor, STDERR_FILENO) >= 0 else {
            let restored = restore_standard_streams(
                saved_stdout: saved_stdout,
                saved_stderr: saved_stderr,
                restore_stdout: true,
                restore_stderr: false)
            if !restored {
                throw DaemonLoggerError.descriptor_rollback_failed
            }
            throw DaemonLoggerError.system_call_failed
        }
    }

    // 功能：幂等启动每秒一次的大小轮转检查。
    // 参数：无。
    // 返回值：无。
    func start_rotation_monitor() {
        state_lock.lock()
        defer { state_lock.unlock() }
        guard rotation_timer == nil, !is_stopping, !is_stopped else { return }

        monitor_generation &+= 1
        let generation = monitor_generation
        let timer = DispatchSource.makeTimerSource(queue: rotation_queue)
        timer.schedule(
            deadline: .now() + ROTATION_INTERVAL_SECONDS,
            repeating: ROTATION_INTERVAL_SECONDS)
        timer.setEventHandler { [weak self] in
            self?.run_rotation_monitor(generation: generation)
        }
        rotation_timer = timer
        timer.resume()
    }

    // 功能：把内部事件及通过类型校验的白名单字段写入 stderr。
    // 参数：level 为级别；event 为内部事件；fields 为候选字段。
    // 返回值：无；未知事件和字段均不持久化。
    func write(_ level: DaemonLogLevel, event: String, fields: [String: String]) {
        state_lock.lock()
        defer { state_lock.unlock() }
        write_locked(level, event: event, fields: fields)
    }

    // 功能：达到阈值时先切换 fd，再交换路径并把旧 inode 交给回收器。
    // 参数：无。
    // 返回值：无；准备或交换失败时恢复旧 fd 并抛错；
    // Trash 失败不影响新日志。
    func rotate_if_needed() throws {
        var staging_to_recycle: URL?
        var old_log_to_trash: URL?
        var operation_error: Error?

        state_lock.lock()
        guard !is_stopping, !is_stopped else {
            state_lock.unlock()
            return
        }
        do {
            old_log_to_trash = try rotate_locked(
                staging_to_recycle: &staging_to_recycle)
        } catch {
            operation_error = error
        }
        state_lock.unlock()

        if let old_log_to_trash {
            do {
                try trash_item(old_log_to_trash)
            } catch {
                write(
                    .error,
                    event: "rotation_error",
                    fields: ["error_category": "trash_failed"])
            }
        } else if let staging_to_recycle {
            try? trash_item(staging_to_recycle)
        }
        if let operation_error { throw operation_error }
    }

    // 功能：在持锁状态下完成阈值检查、fd 切换和路径交换。
    // 参数：staging_to_recycle 返回失败时可在解锁后回收的 staging。
    // 返回值：成功轮转后的旧日志路径；无需轮转时返回 nil。
    private func rotate_locked(
        staging_to_recycle: inout URL?
    ) throws -> URL? {
        var current_status = stat()
        guard lstat(log_url.path, &current_status) == 0,
              current_status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              current_status.st_size >= 0 else {
            throw DaemonLoggerError.invalid_log_file
        }
        guard UInt64(current_status.st_size) >= maximum_bytes else { return nil }

        let staging_url = log_url.deletingLastPathComponent().appendingPathComponent(
            ".\(log_url.lastPathComponent).\(UUID().uuidString).staging")
        let staging_descriptor = try open_secure_log(staging_url, exclusive: true)
        staging_to_recycle = staging_url
        let saved_stdout = Darwin.dup(STDOUT_FILENO)
        guard saved_stdout >= 0 else {
            _ = Darwin.close(staging_descriptor)
            throw DaemonLoggerError.system_call_failed
        }
        let saved_stderr = Darwin.dup(STDERR_FILENO)
        guard saved_stderr >= 0 else {
            _ = Darwin.close(saved_stdout)
            _ = Darwin.close(staging_descriptor)
            throw DaemonLoggerError.system_call_failed
        }

        guard system_calls.replace_descriptor(
            staging_descriptor,
            STDOUT_FILENO) >= 0 else {
            close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
            throw DaemonLoggerError.system_call_failed
        }
        guard system_calls.replace_descriptor(
            staging_descriptor,
            STDERR_FILENO) >= 0 else {
            let restored = restore_standard_streams(
                saved_stdout: saved_stdout,
                saved_stderr: saved_stderr,
                restore_stdout: true,
                restore_stderr: false)
            if !restored {
                staging_to_recycle = nil
                write_locked(
                    .error,
                    event: "rotation_error",
                    fields: ["error_category": "descriptor_rollback_failed"])
            }
            close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
            if !restored { throw DaemonLoggerError.descriptor_rollback_failed }
            throw DaemonLoggerError.system_call_failed
        }

        let swap_result = system_calls.swap_paths(log_url.path, staging_url.path)
        guard swap_result == 0 else {
            let restored = restore_standard_streams(
                saved_stdout: saved_stdout,
                saved_stderr: saved_stderr,
                restore_stdout: true,
                restore_stderr: true)
            if !restored { staging_to_recycle = nil }
            close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
            write_locked(
                .error,
                event: "rotation_error",
                fields: [
                    "error_category": restored
                        ? "rename_swap_failed"
                        : "descriptor_rollback_failed",
                ])
            if !restored { throw DaemonLoggerError.descriptor_rollback_failed }
            throw DaemonLoggerError.system_call_failed
        }

        close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
        staging_to_recycle = nil
        return staging_url
    }

    // 功能：幂等停止轮转 timer，不改变 daemon 当前 stdio fd。
    // 参数：无。
    // 返回值：无。
    func stop() {
        state_lock.lock()
        is_stopping = true
        monitor_generation &+= 1
        let timer = rotation_timer
        rotation_timer = nil
        state_lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        if DispatchQueue.getSpecific(key: rotation_queue_key) == nil {
            monitor_group.wait()
            state_lock.lock()
            finish_stop_locked()
            state_lock.unlock()
        }
    }

    deinit {
        stop()
    }

    // 功能：仅为当前 generation 的 timer 执行一次受生命周期跟踪的轮转。
    // 参数：generation 为 timer 创建时的世代值。
    // 返回值：无；过期 handler 直接退出。
    private func run_rotation_monitor(generation: UInt64) {
        state_lock.lock()
        guard rotation_timer != nil,
              generation == monitor_generation,
              !is_stopping else {
            state_lock.unlock()
            return
        }
        monitor_group.enter()
        state_lock.unlock()
        defer {
            state_lock.lock()
            finish_stop_locked()
            state_lock.unlock()
            monitor_group.leave()
        }

        do {
            try rotate_if_needed()
        } catch {
            write(
                .error,
                event: "rotation_error",
                fields: ["error_category": "rotation_failed"])
        }
    }

    // 功能：在所有已进入 handler 完成后，把 stop 请求转为最终停止状态。
    // 参数：无；调用方必须持有 state_lock。
    // 返回值：无。
    private func finish_stop_locked() {
        guard is_stopping else { return }
        is_stopped = true
        is_stopping = false
    }

    // 功能：创建或收紧日志目录为 0700，并拒绝符号链接和非目录目标。
    // 参数：无。
    // 返回值：无；目标不安全时抛错。
    private func ensure_log_directory() throws {
        let directory = log_url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)

        var directory_status = stat()
        guard lstat(directory.path, &directory_status) == 0,
              directory_status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DaemonLoggerError.invalid_log_directory
        }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DaemonLoggerError.invalid_log_directory }
        defer { _ = Darwin.close(descriptor) }
        guard fchmod(descriptor, DAEMON_LOG_DIRECTORY_MODE) == 0 else {
            throw DaemonLoggerError.system_call_failed
        }
    }

    // 功能：安全打开普通日志文件并强制 0600。
    // 参数：url 为文件路径；exclusive 控制是否要求新建。
    // 返回值：打开的 fd；失败时抛错。
    private func open_secure_log(_ url: URL, exclusive: Bool) throws -> Int32 {
        var flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW
        if exclusive { flags |= O_EXCL }
        let descriptor = Darwin.open(url.path, flags, DAEMON_LOG_FILE_MODE)
        guard descriptor >= 0 else { throw DaemonLoggerError.system_call_failed }

        var file_status = stat()
        guard fstat(descriptor, &file_status) == 0,
              file_status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fchmod(descriptor, DAEMON_LOG_FILE_MODE) == 0 else {
            _ = Darwin.close(descriptor)
            throw DaemonLoggerError.invalid_log_file
        }
        return descriptor
    }

    // 功能：在持锁状态下输出白名单结构化记录。
    // 参数：level 为级别；event 为内部事件；fields 为候选字段。
    // 返回值：无。
    private func write_locked(
        _ level: DaemonLogLevel,
        event: String,
        fields: [String: String]
    ) {
        guard Self.allowed_events.contains(event) else { return }
        var components = [
            "timestamp=\(Int64(Date().timeIntervalSince1970))",
            "level=\(level.rawValue)",
            "event=\(event)",
        ]
        for name in Self.ordered_field_names {
            guard let value = fields[name], is_allowed_value(value, for: name) else { continue }
            components.append("\(name)=\(value)")
        }
        write_all_best_effort(Data((components.joined(separator: " ") + "\n").utf8))
    }

    // 功能：按字段语义验证值，避免换行或任意文本借白名单键落盘。
    // 参数：value 为候选值；name 为白名单字段名。
    // 返回值：值符合该字段限制时为 true。
    private func is_allowed_value(_ value: String, for name: String) -> Bool {
        switch name {
        case "stage":
            return Self.allowed_stages.contains(value)
        case "host":
            return is_allowed_host(value)
        case "port":
            guard let number = Int(value) else { return false }
            return (1...65_535).contains(number)
        case "pid":
            guard let number = Int32(value) else { return false }
            return number > 0
        case "http_status":
            guard let number = Int(value) else { return false }
            return (100...599).contains(number)
        case "retry_count":
            guard let number = Int(value) else { return false }
            return number >= 0
        case "error_category":
            return Self.allowed_error_categories.contains(value)
        default:
            return false
        }
    }

    // 功能：只允许 localhost 或可由 inet_pton 完整解析的 IP 地址。
    // 参数：value 为 host 候选值。
    // 返回值：值为受支持监听地址时返回 true。
    private func is_allowed_host(_ value: String) -> Bool {
        if value == "localhost" { return true }
        var ipv4_address = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4_address) }) == 1 {
            return true
        }
        var ipv6_address = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6_address) }) == 1
    }

    // 功能：完整写入 stderr；失败时停止且不递归记录原始错误。
    // 参数：data 为已通过白名单构造的数据。
    // 返回值：无。
    private func write_all_best_effort(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var remaining = buffer.count
            var address = buffer.baseAddress
            while remaining > 0 {
                let written = Darwin.write(STDERR_FILENO, address, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                address = address?.advanced(by: written)
            }
        }
    }

    // 功能：按切换状态逐一检查 stdout/stderr 回滚结果。
    // 参数：saved fd 为旧流；restore 标志表示对应流是否已切换。
    // 返回值：所有需要恢复的流均成功时返回 true。
    private func restore_standard_streams(
        saved_stdout: Int32,
        saved_stderr: Int32,
        restore_stdout: Bool,
        restore_stderr: Bool
    ) -> Bool {
        var succeeded = true
        if restore_stdout,
           system_calls.replace_descriptor(saved_stdout, STDOUT_FILENO) < 0 {
            succeeded = false
        }
        if restore_stderr,
           system_calls.replace_descriptor(saved_stderr, STDERR_FILENO) < 0 {
            succeeded = false
        }
        return succeeded
    }

    // 功能：关闭一次轮转使用的 staging 与旧标准流重复 fd。
    // 参数：三个 descriptor 为待关闭 fd。
    // 返回值：无。
    private func close_rotation_descriptors(
        _ staging_descriptor: Int32,
        _ saved_stdout: Int32,
        _ saved_stderr: Int32
    ) {
        _ = Darwin.close(staging_descriptor)
        _ = Darwin.close(saved_stdout)
        _ = Darwin.close(saved_stderr)
    }

}
