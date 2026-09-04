// 用途：安全管理 daemon 运行路径、状态文件、排他锁和 Darwin 进程身份。
// 使用方法：构造 RuntimePaths 和 RuntimeStateStore 后执行加载、发布与身份
// 核验。

import Darwin
import Foundation

private let STATE_FILE_NAME = "daemon.json"
private let LOCK_FILE_NAME = "daemon.lock"
private let LOG_FILE_NAME = "gemini2api.log"
private let MANAGED_DIRECTORY_MODE: mode_t = 0o700
private let MANAGED_FILE_MODE: mode_t = 0o600
private let MAXIMUM_STATE_BYTES: Int = 1_048_576
private let PROCESS_PATH_BUFFER_SIZE = Int(MAXPATHLEN) * 4

@_silgen_name("flock")
private func system_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

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
    // 功能：查询指定 PID 的可执行路径和启动时间。
    // 参数：pid 为待查询进程号。
    // 返回值：进程存在时返回身份，不存在时返回 nil；不确定时抛错。
    func inspect(pid: Int32) throws -> ProcessIdentity?
}

enum IdentityResult: Equatable {
    case match
    case missing
    case mismatch
    case uncertain
}

private enum RuntimeStateError: Error {
    case invalid_path
    case invalid_state
    case lock_unavailable
    case process_inspection_uncertain
    case system_call_failed
}

final class DaemonLock {
    private let state_lock = NSLock()
    private var descriptor: Int32

    // 功能：接管已取得排他 flock 的文件描述符。
    // 参数：descriptor 为锁文件描述符。
    // 返回值：初始化后的锁句柄。
    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    // 功能：幂等释放 flock 并关闭描述符，保留锁文件本身。
    // 参数：无。
    // 返回值：无。
    func unlock() {
        state_lock.lock()
        defer { state_lock.unlock() }
        guard descriptor >= 0 else { return }
        _ = system_flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    // 功能：fork 成功后仅关闭 parent 的 descriptor，不解除 child 继承的 flock。
    // 参数：无。
    // 返回值：无；重复调用保持幂等。
    func relinquish_after_fork_in_parent() {
        state_lock.lock()
        defer { state_lock.unlock() }
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        unlock()
    }
}

struct RuntimePaths {
    let application_directory: URL
    let runtime_directory: URL
    let state_path: URL
    let lock_path: URL
    let logs_directory: URL
    let log_path: URL

    // 功能：从可注入的系统目录根派生全部受管路径。
    // 参数：application_support_directory 为 Application Support 根；
    // logs_directory 为 Library/Logs 根。
    // 返回值：初始化后的路径集合。
    init(application_support_directory: URL, logs_directory: URL) {
        application_directory = application_support_directory
            .appendingPathComponent("Gemini2API", isDirectory: true)
        runtime_directory = application_directory
            .appendingPathComponent("runtime", isDirectory: true)
        state_path = runtime_directory.appendingPathComponent(STATE_FILE_NAME)
        lock_path = runtime_directory.appendingPathComponent(LOCK_FILE_NAME)
        self.logs_directory = logs_directory
            .appendingPathComponent("Gemini2API", isDirectory: true)
        log_path = self.logs_directory.appendingPathComponent(LOG_FILE_NAME)
    }

    // 功能：仅通过 FileManager 用户域 API 解析当前用户生产路径。
    // 参数：file_manager 为可注入的文件管理器。
    // 返回值：当前用户的运行状态和日志路径。
    static func current_user(
        file_manager: FileManager = .default
    ) throws -> RuntimePaths {
        let application_support_directory = try file_manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let library_directory = try file_manager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let logs_directory = library_directory.appendingPathComponent(
            "Logs",
            isDirectory: true)
        return RuntimePaths(
            application_support_directory: application_support_directory,
            logs_directory: logs_directory)
    }
}

struct DarwinProcessInspector: ProcessInspecting {
    // 功能：用 kill 探测和 libproc 读取实际进程身份。
    // 参数：pid 为待查询进程号，必须大于 1。
    // 返回值：进程存在时返回路径及 Unix 微秒启动时间；
    // 不存在时返回 nil。
    func inspect(pid: Int32) throws -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        errno = 0
        if Darwin.kill(pid, 0) != 0 {
            if errno == ESRCH { return nil }
            if errno == EPERM {
                throw RuntimeStateError.process_inspection_uncertain
            }
            throw RuntimeStateError.system_call_failed
        }

        var path_buffer = [CChar](
            repeating: 0,
            count: PROCESS_PATH_BUFFER_SIZE)
        errno = 0
        let path_length = proc_pidpath(
            pid,
            &path_buffer,
            UInt32(path_buffer.count))
        guard path_length > 0 else {
            if errno == ESRCH { return nil }
            throw RuntimeStateError.process_inspection_uncertain
        }

        var process_info = proc_bsdinfo()
        errno = 0
        let expected_size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actual_size = withUnsafeMutablePointer(to: &process_info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expected_size)
        }
        guard actual_size == expected_size else {
            if errno == ESRCH { return nil }
            throw RuntimeStateError.process_inspection_uncertain
        }

        let seconds = Int64(process_info.pbi_start_tvsec)
        let microseconds = Int64(process_info.pbi_start_tvusec)
        let (scaled_seconds, overflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000)
        guard !overflow else { throw RuntimeStateError.process_inspection_uncertain }
        let (started_at, addition_overflow) = scaled_seconds.addingReportingOverflow(
            microseconds)
        guard !addition_overflow, started_at > 0 else {
            throw RuntimeStateError.process_inspection_uncertain
        }
        return ProcessIdentity(
            executable_path: String(cString: path_buffer),
            process_started_at: started_at)
    }
}

final class RuntimeStateStore {
    private let paths: RuntimePaths
    private let process_inspector: ProcessInspecting
    private let trash_item: (URL) throws -> Void

    // 功能：创建使用注入路径、进程查询器和废纸篓适配器的状态存储。
    // 参数：paths 为受管路径；process_inspector 查询身份；trash_item 回收文件。
    // 返回值：初始化后的状态存储。
    init(
        paths: RuntimePaths,
        process_inspector: ProcessInspecting,
        trash_item: @escaping (URL) throws -> Void
    ) {
        self.paths = paths
        self.process_inspector = process_inspector
        self.trash_item = trash_item
    }

    // 功能：安全创建并非阻塞取得固定保留的 daemon 排他锁。
    // 参数：无。
    // 返回值：持锁句柄；已有 contender 时抛错。
    func acquire_lock() throws -> DaemonLock {
        try ensure_layout()
        let descriptor = try open_regular_file(
            paths.lock_path,
            flags: O_RDWR | O_CREAT,
            mode: MANAGED_FILE_MODE,
            enforce_mode: true)
        guard system_flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw RuntimeStateError.lock_unavailable
        }
        return DaemonLock(descriptor: descriptor)
    }

    // 功能：经 O_NOFOLLOW 安全读取并解码 daemon 状态。
    // 参数：无。
    // 返回值：状态文件不存在时返回 nil，否则返回完整状态。
    func load() throws -> DaemonState? {
        try ensure_layout()
        guard path_exists_without_following(paths.state_path) else { return nil }
        let descriptor = try open_regular_file(
            paths.state_path,
            flags: O_RDONLY,
            mode: MANAGED_FILE_MODE,
            enforce_mode: false)
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size >= 0,
              info.st_size <= MAXIMUM_STATE_BYTES,
              info.st_mode & 0o777 == MANAGED_FILE_MODE else {
            throw RuntimeStateError.invalid_state
        }
        let data = try read_all(descriptor: descriptor)
        do {
            return try JSONDecoder().decode(DaemonState.self, from: data)
        } catch {
            throw RuntimeStateError.invalid_state
        }
    }

    // 功能：用同目录 0600 staging 和 rename 原子发布完整 daemon 状态。
    // 参数：state 为待发布状态。
    // 返回值：无；任一步失败时保留旧状态并把 staging 交给回收器。
    func publish(_ state: DaemonState) throws {
        try ensure_layout()
        try recycle_abandoned_staging()
        try validate_optional_regular_target(paths.state_path)
        let data = try JSONEncoder.sorted_state_encoder.encode(state)
        let staging_path = paths.runtime_directory.appendingPathComponent(
            "\(STATE_FILE_NAME).\(UUID().uuidString).staging")
        var staging_created = false
        do {
            let descriptor = try open_regular_file(
                staging_path,
                flags: O_WRONLY | O_CREAT | O_EXCL,
                mode: MANAGED_FILE_MODE,
                enforce_mode: true)
            staging_created = true
            do {
                try write_all(data, descriptor: descriptor)
                guard fsync(descriptor) == 0 else {
                    throw RuntimeStateError.system_call_failed
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            guard Darwin.close(descriptor) == 0 else {
                throw RuntimeStateError.system_call_failed
            }
            guard Darwin.rename(staging_path.path, paths.state_path.path) == 0 else {
                throw RuntimeStateError.system_call_failed
            }
            staging_created = false
            sync_directory_best_effort(paths.runtime_directory)
        } catch {
            if staging_created && path_exists_without_following(staging_path) {
                try? trash_item(staging_path)
            }
            throw error
        }
    }

    // 功能：把确认失效的状态文件交给注入回收器，不永久删除。
    // 参数：无。
    // 返回值：状态不存在时无操作，回收失败时抛错。
    func recycle_stale_state() throws {
        try ensure_layout()
        guard path_exists_without_following(paths.state_path) else { return }
        try validate_regular_target(paths.state_path)
        try trash_item(paths.state_path)
        try sync_directory(paths.runtime_directory)
    }

    // 功能：严格比较 PID、版本、实际路径和微秒启动时间。
    // 参数：state 为已加载的 daemon 状态。
    // 返回值：匹配、缺失、差异或不确定四态之一。
    func identity_matches(_ state: DaemonState) -> IdentityResult {
        guard state.pid > 1,
              !state.executable_path.isEmpty,
              state.process_started_at > 0,
              !state.instance_id.isEmpty,
              !state.host.isEmpty,
              (1...65_535).contains(state.port),
              state.version == GEMINI2API_VERSION else {
            return .mismatch
        }
        do {
            guard let identity = try process_inspector.inspect(pid: state.pid) else {
                return .missing
            }
            guard identity.executable_path == state.executable_path,
                  identity.process_started_at == state.process_started_at else {
                return .mismatch
            }
            return .match
        } catch {
            return .uncertain
        }
    }

    // 功能：创建并收紧受管应用、runtime 和日志目录。
    // 参数：无。
    // 返回值：无；symlink 或非目录目标会抛错。
    private func ensure_layout() throws {
        try ensure_base_directory(paths.application_directory.deletingLastPathComponent())
        try ensure_base_directory(paths.logs_directory.deletingLastPathComponent())
        try ensure_managed_directory(paths.application_directory)
        try ensure_managed_directory(paths.runtime_directory)
        try ensure_managed_directory(paths.logs_directory)
    }

    // 功能：回收上次崩溃遗留的同名 staging 项目。
    // 参数：无。
    // 返回值：无；枚举或回收失败时抛错。
    private func recycle_abandoned_staging() throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: paths.runtime_directory.path)
        for name in names where name.hasPrefix("\(STATE_FILE_NAME).")
            && name.hasSuffix(".staging") {
            let staging_path = paths.runtime_directory.appendingPathComponent(name)
            try trash_item(staging_path)
        }
    }
}

private extension JSONEncoder {
    // 功能：提供字段排序的状态编码器，产生稳定且可审计的 JSON。
    // 参数：无。
    // 返回值：启用 sortedKeys 的编码器。
    static var sorted_state_encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// 功能：用 FileManager 创建缺失的系统目录根并拒绝 symlink 或非目录。
// 参数：url 为系统 API 给出的目录根。
// 返回值：无；目标不安全时抛错。
private func ensure_base_directory(_ url: URL) throws {
    if !path_exists_without_following(url) {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: MANAGED_DIRECTORY_MODE)])
    }
    try validate_directory_target(url)
}

// 功能：用 mkdir 创建受管目录，再经 O_NOFOLLOW 和 fchmod 收紧为 0700。
// 参数：url 为受管目录。
// 返回值：无；symlink 或非目录目标会抛错。
private func ensure_managed_directory(_ url: URL) throws {
    if !path_exists_without_following(url) {
        guard Darwin.mkdir(url.path, MANAGED_DIRECTORY_MODE) == 0 else {
            throw RuntimeStateError.system_call_failed
        }
    }
    try validate_directory_target(url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw RuntimeStateError.invalid_path }
    defer { _ = Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
          info.st_mode & S_IFMT == S_IFDIR,
          fchmod(descriptor, MANAGED_DIRECTORY_MODE) == 0 else {
        throw RuntimeStateError.invalid_path
    }
}

// 功能：以 O_NOFOLLOW 打开普通文件并按需要收紧权限。
// 参数：url 为文件；flags 为 open flags；mode 为创建权限；
// enforce_mode 控制 fchmod。
// 返回值：安全打开的文件描述符。
private func open_regular_file(
    _ url: URL,
    flags: Int32,
    mode: mode_t,
    enforce_mode: Bool
) throws -> Int32 {
    try validate_optional_regular_target(url)
    let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw RuntimeStateError.system_call_failed }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
          info.st_mode & S_IFMT == S_IFREG else {
        _ = Darwin.close(descriptor)
        throw RuntimeStateError.invalid_path
    }
    if enforce_mode && fchmod(descriptor, mode) != 0 {
        _ = Darwin.close(descriptor)
        throw RuntimeStateError.system_call_failed
    }
    return descriptor
}

// 功能：用 lstat 验证目录目标，不跟随 symlink。
// 参数：url 为待验证目录。
// 返回值：无；非真实目录时抛错。
private func validate_directory_target(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
          info.st_mode & S_IFMT == S_IFDIR else {
        throw RuntimeStateError.invalid_path
    }
}

// 功能：验证存在的目标是普通文件。
// 参数：url 为待验证文件。
// 返回值：无；symlink、目录或其他类型时抛错。
private func validate_regular_target(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
          info.st_mode & S_IFMT == S_IFREG else {
        throw RuntimeStateError.invalid_path
    }
}

// 功能：验证可选目标不存在或为普通文件。
// 参数：url 为待验证文件。
// 返回值：无；存在但不是普通文件时抛错。
private func validate_optional_regular_target(_ url: URL) throws {
    if path_exists_without_following(url) {
        try validate_regular_target(url)
    }
}

// 功能：用 lstat 判断路径本身是否存在，不跟随 symlink。
// 参数：url 为待检查路径。
// 返回值：路径或 symlink 本身存在时为 true，仅 ENOENT 时为 false。
private func path_exists_without_following(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    return errno != ENOENT
}

// 功能：完整写入 Data，处理 EINTR 和短写。
// 参数：data 为待写数据；descriptor 为已打开文件。
// 返回值：无；写入失败时抛错。
private func write_all(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { raw_buffer in
        guard let base_address = raw_buffer.baseAddress else { return }
        var offset = 0
        while offset < raw_buffer.count {
            let count = Darwin.write(
                descriptor,
                base_address.advanced(by: offset),
                raw_buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RuntimeStateError.system_call_failed }
            offset += count
        }
    }
}

// 功能：从当前文件位置完整读取受限大小的数据。
// 参数：descriptor 为已打开状态文件。
// 返回值：读取到的 Data。
private func read_all(descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw RuntimeStateError.system_call_failed }
        if count == 0 { return result }
        result.append(buffer, count: count)
        guard result.count <= MAXIMUM_STATE_BYTES else {
            throw RuntimeStateError.invalid_state
        }
    }
}

// 功能：fsync 受管目录，确保持久化 rename 或回收后的目录项变化。
// 参数：directory 为受管目录。
// 返回值：无；打开或同步失败时抛错。
private func sync_directory(_ directory: URL) throws {
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RuntimeStateError.system_call_failed }
    defer { _ = Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw RuntimeStateError.system_call_failed }
}

// 功能：发布完成后尽力持久化目录项，不把已提交状态误报为失败。
// 参数：directory 为受管目录。
// 返回值：无；同步错误由后续状态读取核验处理。
private func sync_directory_best_effort(_ directory: URL) {
    try? sync_directory(directory)
}
