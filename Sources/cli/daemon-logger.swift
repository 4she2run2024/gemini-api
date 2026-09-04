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
    case invalid_log_directory
    case invalid_log_file
    case system_call_failed
}

final class DaemonLogger {
    private static let allowed_events: Set<String> = [
        "daemon_starting", "daemon_ready", "request_completed", "request_retry",
        "daemon_error", "rotation_error", "daemon_stopping",
    ]
    private static let allowed_stages: Set<String> = [
        "startup", "listening", "request", "retry", "rotation", "shutdown",
    ]
    private static let ordered_field_names = [
        "stage", "host", "port", "pid", "http_status", "error_category", "retry_count",
    ]

    private let log_url: URL
    private let maximum_bytes: UInt64
    private let trash_item: (URL) throws -> Void
    private let state_lock = NSLock()
    private var rotation_timer: DispatchSourceTimer?

    // 功能：构造使用动态日志路径、大小阈值和可恢复回收器的
    // daemon logger。
    // 参数：log_url 为 RuntimePaths.log_path；maximum_bytes 为轮转阈值；
    // trash_item 把旧日志移入废纸篓。
    // 返回值：初始化后的 logger。
    init(
        log_url: URL,
        maximum_bytes: UInt64 = 5 * 1024 * 1024,
        trash_item: @escaping (URL) throws -> Void
    ) {
        self.log_url = log_url
        self.maximum_bytes = maximum_bytes
        self.trash_item = trash_item
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

        guard Darwin.dup2(descriptor, STDOUT_FILENO) >= 0 else {
            throw DaemonLoggerError.system_call_failed
        }
        guard Darwin.dup2(descriptor, STDERR_FILENO) >= 0 else {
            _ = Darwin.dup2(saved_stdout, STDOUT_FILENO)
            throw DaemonLoggerError.system_call_failed
        }
    }

    // 功能：幂等启动每秒一次的大小轮转检查。
    // 参数：无。
    // 返回值：无。
    func start_rotation_monitor() {
        state_lock.lock()
        defer { state_lock.unlock() }
        guard rotation_timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "gemini2api.daemon-log-rotation"))
        timer.schedule(
            deadline: .now() + ROTATION_INTERVAL_SECONDS,
            repeating: ROTATION_INTERVAL_SECONDS)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try self.rotate_if_needed()
            } catch {
                self.write(
                    .error,
                    event: "rotation_error",
                    fields: ["error_category": self.error_category(error)])
            }
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
        state_lock.lock()
        defer { state_lock.unlock() }

        var current_status = stat()
        guard lstat(log_url.path, &current_status) == 0,
              current_status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              current_status.st_size >= 0 else {
            throw DaemonLoggerError.invalid_log_file
        }
        guard UInt64(current_status.st_size) >= maximum_bytes else { return }

        let staging_url = log_url.deletingLastPathComponent().appendingPathComponent(
            ".\(log_url.lastPathComponent).\(UUID().uuidString).staging")
        let staging_descriptor = try open_secure_log(staging_url, exclusive: true)
        let saved_stdout = Darwin.dup(STDOUT_FILENO)
        guard saved_stdout >= 0 else {
            _ = Darwin.close(staging_descriptor)
            recycle_best_effort(staging_url)
            throw DaemonLoggerError.system_call_failed
        }
        let saved_stderr = Darwin.dup(STDERR_FILENO)
        guard saved_stderr >= 0 else {
            _ = Darwin.close(saved_stdout)
            _ = Darwin.close(staging_descriptor)
            recycle_best_effort(staging_url)
            throw DaemonLoggerError.system_call_failed
        }

        guard Darwin.dup2(staging_descriptor, STDOUT_FILENO) >= 0 else {
            close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
            recycle_best_effort(staging_url)
            throw DaemonLoggerError.system_call_failed
        }
        guard Darwin.dup2(staging_descriptor, STDERR_FILENO) >= 0 else {
            restore_standard_streams(saved_stdout: saved_stdout, saved_stderr: saved_stderr)
            close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
            recycle_best_effort(staging_url)
            throw DaemonLoggerError.system_call_failed
        }

        let swap_result = log_url.path.withCString { canonical_path in
            staging_url.path.withCString { staging_path in
                renamex_np(canonical_path, staging_path, UInt32(RENAME_SWAP))
            }
        }
        guard swap_result == 0 else {
            restore_standard_streams(saved_stdout: saved_stdout, saved_stderr: saved_stderr)
            close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
            recycle_best_effort(staging_url)
            write_locked(
                .error,
                event: "rotation_error",
                fields: ["error_category": "rename_swap_failed"])
            throw DaemonLoggerError.system_call_failed
        }

        close_rotation_descriptors(staging_descriptor, saved_stdout, saved_stderr)
        do {
            try trash_item(staging_url)
        } catch {
            write_locked(
                .error,
                event: "rotation_error",
                fields: ["error_category": error_category(error)])
        }
    }

    // 功能：幂等停止轮转 timer，不改变 daemon 当前 stdio fd。
    // 参数：无。
    // 返回值：无。
    func stop() {
        state_lock.lock()
        let timer = rotation_timer
        rotation_timer = nil
        state_lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    deinit {
        stop()
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
            return !value.isEmpty && value.count <= 255 && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                    + "0123456789.:-[]").contains($0)
            }
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
            return !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "_.:-")).contains($0)
            }
        default:
            return false
        }
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

    // 功能：用保存的旧 fd 同时恢复 stdout/stderr。
    // 参数：saved_stdout 和 saved_stderr 为切换前的重复 fd。
    // 返回值：无。
    private func restore_standard_streams(saved_stdout: Int32, saved_stderr: Int32) {
        _ = Darwin.dup2(saved_stdout, STDOUT_FILENO)
        _ = Darwin.dup2(saved_stderr, STDERR_FILENO)
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

    // 功能：尽力回收尚未交换的 staging，不永久删除。
    // 参数：url 为 staging 路径。
    // 返回值：无；回收失败时保留原文件。
    private func recycle_best_effort(_ url: URL) {
        try? trash_item(url)
    }

    // 功能：把 Error 映射为不含描述和路径的稳定类型类别。
    // 参数：error 为原错误。
    // 返回值：仅含类型标识字符的类别。
    private func error_category(_ error: Error) -> String {
        let reflected = String(describing: type(of: error))
        let filtered = reflected.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "_.:-")).contains($0)
        }
        let category = String(String.UnicodeScalarView(filtered))
        return String(category.prefix(100))
    }
}
