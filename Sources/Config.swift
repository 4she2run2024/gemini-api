import Darwin
import Foundation

// 用途：管理 Gemini2API 配置，并从旧版应用配置执行一次性迁移。
// 使用方法：应用启动时调用 load()，设置更新后调用 save()。
// 配置错误只表达结构类别，避免携带敏感 JSON。
private enum StoreError: Error {
    case invalid_config_root
    case invalid_config_directory
}

final class Store {
    static let shared = Store()

    var port = 8081
    var host = "0.0.0.0"
    var retryAttempts = 3
    var retryDelaySec = 2.0
    var requestTimeoutSec = 180.0
    var geminiBl = "boq_assistant-bard-web-server_20260716.08_p0"
    var authUser: String? = nil
    var xsrfToken: String? = nil
    var defaultModel = "gemini-3.6-flash"
    var logRequests = true
    var cookieFile: String? = nil
    var proxy: String? = nil
    var apiKeys: [String] = []
    var launchAtLogin = false

    let path: URL
    let legacy_path: URL
    private let migration_publish_barrier: (() -> Void)?
    private let staging_recycler: (URL) throws -> Void

    // 功能：根据可注入的根目录生成新旧配置路径。
    // 参数：config_root 为用户目录；migration_publish_barrier 为发布前同步点；
    // staging_recycler 为 staging 废纸篓回收器。后两项可由测试注入。
    // 返回值：初始化后的配置存储对象。
    init(
        config_root: URL = FileManager.default.homeDirectoryForCurrentUser,
        migration_publish_barrier: (() -> Void)? = nil,
        staging_recycler: ((URL) throws -> Void)? = nil
    ) {
        path = config_root.appendingPathComponent(".config/gemini2api/config.json")
        legacy_path = config_root.appendingPathComponent(
            ".config/gemini-web2api/config.json")
        self.migration_publish_barrier = migration_publish_barrier
        self.staging_recycler = staging_recycler ?? { staging_path in
            var trashed_path: NSURL?
            try FileManager.default.trashItem(
                at: staging_path,
                resultingItemURL: &trashed_path)
        }
    }

    // 功能：优先读取新配置；必要时先迁移旧配置。
    // 参数：无。
    // 返回值：无；迁移或读取失败时保留当前默认值。
    func load() {
        do {
            try migrate_legacy_config()
        } catch {
            write_safe_error(
                "配置迁移失败",
                error: error,
                path_category: "旧配置到新配置")
            return
        }
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let d = object as? [String: Any] else { return }
        reset_config_values()
        if let v = d["port"] as? Int { port = v }
        if let v = d["host"] as? String { host = v }
        if let v = d["retry_attempts"] as? Int { retryAttempts = v }
        if let v = d["retry_delay_sec"] as? NSNumber { retryDelaySec = v.doubleValue }
        if let v = d["request_timeout_sec"] as? NSNumber { requestTimeoutSec = v.doubleValue }
        if let v = d["gemini_bl"] as? String { geminiBl = v }
        authUser = str(d["auth_user"])
        xsrfToken = str(d["xsrf_token"])
        if let v = d["default_model"] as? String { defaultModel = v }
        if let v = d["log_requests"] as? Bool { logRequests = v }
        cookieFile = d["cookie_file"] as? String
        proxy = d["proxy"] as? String
        if let v = d["api_keys"] as? [String] { apiKeys = v }
        if let v = d["launch_at_login"] as? Bool { launchAtLogin = v }
    }

    // 功能：在成功解析新配置对象后恢复所有可配置字段的声明默认值。
    // 参数：无。
    // 返回值：无。
    private func reset_config_values() {
        port = 8081
        host = "0.0.0.0"
        retryAttempts = 3
        retryDelaySec = 2.0
        requestTimeoutSec = 180.0
        geminiBl = "boq_assistant-bard-web-server_20260716.08_p0"
        authUser = nil
        xsrfToken = nil
        defaultModel = "gemini-3.6-flash"
        logRequests = true
        cookieFile = nil
        proxy = nil
        apiKeys = []
        launchAtLogin = false
    }

    // 功能：仅在新配置缺失且旧配置存在时，校验并原子复制旧配置。
    // 参数：无。
    // 返回值：无；读取、校验、建目录或写入失败时抛出原始错误。
    func migrate_legacy_config() throws {
        let file_manager = FileManager.default
        guard !file_manager.fileExists(atPath: path.path),
              file_manager.fileExists(atPath: legacy_path.path) else { return }

        let legacy_data = try Data(contentsOf: legacy_path)
        let legacy_object = try JSONSerialization.jsonObject(with: legacy_data)
        guard legacy_object is [String: Any] else {
            throw StoreError.invalid_config_root
        }
        try prepare_config_directory()
        let staging_path = try write_secure_staging_file(legacy_data)
        migration_publish_barrier?()
        let publish_result = staging_path.path.withCString { source_path in
            path.path.withCString { destination_path in
                renamex_np(source_path, destination_path, UInt32(RENAME_EXCL))
            }
        }
        guard publish_result != 0 else { return }

        let publish_errno = errno
        recycle_staging_file_best_effort(staging_path)
        if publish_errno == EEXIST { return }
        throw make_posix_error(publish_errno)
    }

    // 功能：把当前配置写入 Gemini2API 的新配置路径。
    // 参数：无。
    // 返回值：无；序列化或写入失败时不修改已有配置。
    func save() {
        let d: [String: Any] = [
            "port": port, "host": host,
            "retry_attempts": retryAttempts, "retry_delay_sec": retryDelaySec,
            "request_timeout_sec": requestTimeoutSec, "gemini_bl": geminiBl,
            "auth_user": authUser ?? NSNull(), "xsrf_token": xsrfToken ?? NSNull(),
            "default_model": defaultModel, "log_requests": logRequests,
            "cookie_file": cookieFile ?? NSNull(), "proxy": proxy ?? NSNull(),
            "api_keys": apiKeys, "launch_at_login": launchAtLogin,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: d,
            options: [.prettyPrinted]) else { return }
        try? save_secure_config(data)
    }

    // 功能：把 auth_user 的字符串或数字值统一转换为非空字符串。
    // 参数：v 为 JSON 字段值。
    // 返回值：有效字符串；不支持或为空时返回 nil。
    private func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    // 功能：创建或收紧新配置目录，使其权限固定为 0700。
    // 参数：无。
    // 返回值：无；父目录创建、mkdir 或 chmod 失败时抛出错误。
    private func prepare_config_directory() throws {
        let config_directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: config_directory.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if mkdir(config_directory.path, mode_t(S_IRWXU)) != 0,
           errno != EEXIST {
            throw make_posix_error(errno)
        }

        var directory_status = stat()
        guard lstat(config_directory.path, &directory_status) == 0 else {
            throw make_posix_error(errno)
        }
        let file_type = directory_status.st_mode & mode_t(S_IFMT)
        guard file_type == mode_t(S_IFDIR) else {
            throw StoreError.invalid_config_directory
        }

        let directory_descriptor = open(
            config_directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory_descriptor >= 0 else { throw make_posix_error(errno) }
        defer { _ = close(directory_descriptor) }
        guard fchmod(directory_descriptor, mode_t(S_IRWXU)) == 0 else {
            throw make_posix_error(errno)
        }
    }

    // 功能：通过同目录 0600 staging 文件原子保存当前配置。
    // 参数：data 为序列化后的配置内容。
    // 返回值：无；写入、发布或 staging 回收失败时抛出错误。
    private func save_secure_config(_ data: Data) throws {
        try prepare_config_directory()
        let staging_path = try write_secure_staging_file(data)
        let publish_result = staging_path.path.withCString { source_path in
            path.path.withCString { destination_path in
                Darwin.rename(source_path, destination_path)
            }
        }
        guard publish_result != 0 else { return }

        let publish_errno = errno
        recycle_staging_file_best_effort(staging_path)
        throw make_posix_error(publish_errno)
    }

    // 功能：在新配置目录中创建并完整写入权限为 0600 的 staging 文件。
    // 参数：data 为待发布的配置字节。
    // 返回值：已同步并关闭的 staging 文件路径。
    private func write_secure_staging_file(_ data: Data) throws -> URL {
        let staging_path = path.deletingLastPathComponent()
            .appendingPathComponent(".config-\(UUID().uuidString).tmp")
        let descriptor = open(
            staging_path.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw make_posix_error(errno) }

        do {
            guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw make_posix_error(errno)
            }
            try data.withUnsafeBytes { buffer in
                var bytes_remaining = buffer.count
                var address = buffer.baseAddress
                while bytes_remaining > 0 {
                    let written = Darwin.write(descriptor, address, bytes_remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw make_posix_error(errno)
                    }
                    bytes_remaining -= written
                    address = address?.advanced(by: written)
                }
            }
            guard fsync(descriptor) == 0 else { throw make_posix_error(errno) }
            _ = close(descriptor)
            return staging_path
        } catch {
            _ = close(descriptor)
            recycle_staging_file_best_effort(staging_path)
            throw error
        }
    }

    // 功能：尽力把未发布的 staging 文件移入系统废纸篓。
    // 参数：staging_path 为待回收文件路径。
    // 返回值：无；回收失败时只输出脱敏告警，不覆盖原操作结果。
    private func recycle_staging_file_best_effort(_ staging_path: URL) {
        do {
            try staging_recycler(staging_path)
        } catch {
            write_safe_error(
                "配置 staging 回收失败",
                error: error,
                path_category: "新配置临时文件到废纸篓")
        }
    }

    // 功能：向标准错误输出不含配置内容或真实路径的安全错误。
    // 参数：title 为错误类别，error 为原错误，path_category 为抽象路径类别。
    // 返回值：无。
    private func write_safe_error(
        _ title: String,
        error: Error,
        path_category: String
    ) {
        let error_type = String(reflecting: type(of: error))
        let message = "\(title)：error_type=\(error_type)，" +
            "路径类别=\(path_category)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    // 功能：把 errno 转换为稳定的 POSIXError。
    // 参数：code 为 POSIX errno。
    // 返回值：对应错误；未知 errno 使用 EIO。
    private func make_posix_error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
