import Darwin
import Dispatch
import Foundation

// 用途：验证 Gemini2API 配置迁移、新配置优先级和失败日志脱敏。
// 使用方法：由 bash Tests/run-tests.sh [--auto] 编译并执行。

private enum ConfigMigrationTestError: Error {
    case recycle_failed
    case fixture_recycle_failed
}

@main
struct ConfigMigrationTests {
    // 功能：运行旧配置迁移、新配置优先和日志脱敏测试。
    // 参数：无。
    // 返回值：无；断言失败时终止进程。
    static func main() throws {
        let file_manager = FileManager.default
        let test_root = file_manager.temporaryDirectory
            .appendingPathComponent("gemini2api-config-tests-\(UUID().uuidString)")
        try file_manager.createDirectory(at: test_root, withIntermediateDirectories: true)
        var test_root_recycled = false
        defer {
            if !test_root_recycled {
                recycle_test_root_best_effort(test_root)
            }
        }

        do {
            try test_legacy_config_migration(test_root: test_root)
            try test_new_config_priority(test_root: test_root)
            try test_concurrent_new_config_wins(test_root: test_root)
            try test_recycle_failure_does_not_block_winner(test_root: test_root)
            try test_save_permissions(test_root: test_root)
            try test_regular_file_obstacle_preserved(test_root: test_root)
            try test_symlink_obstacle_preserved(test_root: test_root)
            try test_non_object_legacy_rejected(test_root: test_root)
            try test_migration_error_redaction(test_root: test_root)
            try test_repeated_load_resets_missing_fields(test_root: test_root)
            try test_invalid_new_config_preserves_state(test_root: test_root)
        } catch {
            let test_error = error
            try recycle_test_root(test_root)
            test_root_recycled = true
            throw test_error
        }

        try recycle_test_root(test_root)
        test_root_recycled = true

        print("ConfigMigrationTests passed")
    }

    // 功能：把完整测试 fixture 根目录移入系统废纸篓。
    // 参数：test_root 为待回收临时根目录。
    // 返回值：无；失败时先输出脱敏错误，
    // 再抛出不含真实路径的测试错误。
    private static func recycle_test_root(_ test_root: URL) throws {
        do {
            var trashed_path: NSURL?
            try FileManager.default.trashItem(
                at: test_root,
                resultingItemURL: &trashed_path)
        } catch {
            write_test_cleanup_error(error)
            throw ConfigMigrationTestError.fixture_recycle_failed
        }
    }

    // 功能：在 defer 兜底路径尽力回收测试 fixture 根目录。
    // 参数：test_root 为待回收临时根目录。
    // 返回值：无；失败时只输出脱敏错误。
    private static func recycle_test_root_best_effort(_ test_root: URL) {
        do {
            var trashed_path: NSURL?
            try FileManager.default.trashItem(
                at: test_root,
                resultingItemURL: &trashed_path)
        } catch {
            write_test_cleanup_error(error)
        }
    }

    // 功能：输出不含 fixture 内容或真实路径的测试回收错误。
    // 参数：error 为底层文件系统错误。
    // 返回值：无。
    private static func write_test_cleanup_error(_ error: Error) {
        let error_type = String(reflecting: type(of: error))
        let message = "测试 fixture 回收失败：error_type=\(error_type)，" +
            "路径类别=临时测试根到废纸篓\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    // 功能：验证旧配置会迁移到动态生成的新路径，且旧文件保持不变。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_legacy_config_migration(test_root: URL) throws {
        let file_manager = FileManager.default
        let root = test_root.appendingPathComponent("legacy-only", isDirectory: true)
        let legacy_path = root.appendingPathComponent(
            ".config/gemini-web2api/config.json")
        let legacy_data = Data(
            """
            {
              "port": 18081,
              "default_model": "gemini-3.8-flash",
              "api_keys": ["test-key"]
            }
            """.utf8)
        try write_fixture(legacy_data, to: legacy_path)
        try set_permissions(0o600, for: legacy_path)
        let original_legacy_mode = try posix_mode(of: legacy_path)

        let store = Store(config_root: root)
        store.load()
        let migrated_data = try Data(contentsOf: store.path)
        let preserved_legacy_data = try Data(contentsOf: legacy_path)
        let config_directory_mode = try posix_mode(
            of: store.path.deletingLastPathComponent())
        let migrated_mode = try posix_mode(of: store.path)
        let preserved_legacy_mode = try posix_mode(of: legacy_path)

        precondition(store.port == 18081)
        precondition(store.defaultModel == "gemini-3.8-flash")
        precondition(store.apiKeys == ["test-key"])
        precondition(store.path.path.hasSuffix(".config/gemini2api/config.json"))
        precondition(file_manager.fileExists(atPath: store.path.path))
        precondition(file_manager.fileExists(atPath: legacy_path.path))
        precondition(preserved_legacy_data == legacy_data)
        precondition(migrated_data == legacy_data)
        precondition(config_directory_mode == 0o700)
        precondition(migrated_mode == 0o600)
        precondition(preserved_legacy_mode == original_legacy_mode)
    }

    // 功能：验证新旧配置同时存在时只读取新配置，不改写旧文件。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_new_config_priority(test_root: URL) throws {
        let root = test_root.appendingPathComponent("new-priority", isDirectory: true)
        let legacy_path = root.appendingPathComponent(
            ".config/gemini-web2api/config.json")
        let new_path = root.appendingPathComponent(".config/gemini2api/config.json")
        let legacy_data = Data("{\"port\":18081,\"api_keys\":[\"legacy-key\"]}".utf8)
        let new_data = Data("{\"port\":19090,\"api_keys\":[\"new-key\"]}".utf8)
        try write_fixture(legacy_data, to: legacy_path)
        try write_fixture(new_data, to: new_path)

        let store = Store(config_root: root)
        store.load()
        let preserved_legacy_data = try Data(contentsOf: legacy_path)
        let preserved_new_data = try Data(contentsOf: new_path)

        precondition(store.port == 19090)
        precondition(store.apiKeys == ["new-key"])
        precondition(preserved_legacy_data == legacy_data)
        precondition(preserved_new_data == new_data)
    }

    // 功能：验证迁移发布前出现的新配置会胜出，
    // 且 staging 文件被移入废纸篓。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件或并发操作失败时抛出错误。
    private static func test_concurrent_new_config_wins(test_root: URL) throws {
        let file_manager = FileManager.default
        let root = test_root.appendingPathComponent("concurrent-save", isDirectory: true)
        let legacy_path = root.appendingPathComponent(
            ".config/gemini-web2api/config.json")
        let legacy_data = Data("{\"port\":18081,\"api_keys\":[\"legacy-key\"]}".utf8)
        try write_fixture(legacy_data, to: legacy_path)

        let reached_barrier = DispatchSemaphore(value: 0)
        let release_migration = DispatchSemaphore(value: 0)
        let migration_finished = DispatchSemaphore(value: 0)
        let migrating_store = Store(
            config_root: root,
            migration_publish_barrier: {
                reached_barrier.signal()
                precondition(release_migration.wait(timeout: .now() + 5) == .success)
            })
        DispatchQueue.global().async {
            migrating_store.load()
            migration_finished.signal()
        }

        precondition(reached_barrier.wait(timeout: .now() + 5) == .success)
        let saving_store = Store(config_root: root)
        saving_store.port = 19090
        saving_store.apiKeys = ["new-key"]
        saving_store.save()
        release_migration.signal()
        precondition(migration_finished.wait(timeout: .now() + 5) == .success)

        let config_entries = try file_manager.contentsOfDirectory(
            at: migrating_store.path.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        let preserved_legacy_data = try Data(contentsOf: legacy_path)
        precondition(migrating_store.port == 19090)
        precondition(migrating_store.apiKeys == ["new-key"])
        precondition(config_entries.map { $0.lastPathComponent } == ["config.json"])
        precondition(preserved_legacy_data == legacy_data)
    }

    // 功能：验证竞争失败后的 staging 回收错误只告警，
    // 不阻止同次 load 读取已胜出的新配置。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件或并发操作失败时抛出错误。
    private static func test_recycle_failure_does_not_block_winner(
        test_root: URL
    ) throws {
        let file_manager = FileManager.default
        let root = test_root.appendingPathComponent(
            "recycle-failure-race",
            isDirectory: true)
        let legacy_path = root.appendingPathComponent(
            ".config/gemini-web2api/config.json")
        let legacy_data = Data("{\"port\":18081,\"api_keys\":[\"legacy-key\"]}".utf8)
        try write_fixture(legacy_data, to: legacy_path)

        let reached_barrier = DispatchSemaphore(value: 0)
        let release_migration = DispatchSemaphore(value: 0)
        let migration_finished = DispatchSemaphore(value: 0)
        let migrating_store = Store(
            config_root: root,
            migration_publish_barrier: {
                reached_barrier.signal()
                precondition(release_migration.wait(timeout: .now() + 5) == .success)
            },
            staging_recycler: { _ in
                throw ConfigMigrationTestError.recycle_failed
            })

        let error_output = capture_stderr {
            DispatchQueue.global().async {
                migrating_store.load()
                migration_finished.signal()
            }
            precondition(reached_barrier.wait(timeout: .now() + 5) == .success)
            let saving_store = Store(config_root: root)
            saving_store.port = 19090
            saving_store.apiKeys = ["new-key"]
            saving_store.save()
            release_migration.signal()
            precondition(migration_finished.wait(timeout: .now() + 5) == .success)
        }

        let disk_store = Store(config_root: root)
        disk_store.load()
        let config_entries = try file_manager.contentsOfDirectory(
            at: migrating_store.path.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        precondition(disk_store.port == 19090)
        precondition(migrating_store.port == 19090)
        precondition(migrating_store.apiKeys == ["new-key"])
        precondition(config_entries.contains { $0.pathExtension == "tmp" })
        precondition(error_output.contains("staging 回收失败"))
        precondition(!error_output.contains("配置迁移失败"))
        precondition(!error_output.contains("legacy-key"))
        precondition(!error_output.contains(root.path))
    }

    // 功能：验证首次和后续保存都生成 0600 文件，
    // 并把配置目录限制为 0700。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_save_permissions(test_root: URL) throws {
        let root = test_root.appendingPathComponent("save-permissions", isDirectory: true)
        let store = Store(config_root: root)
        store.port = 19091
        store.apiKeys = ["save-key"]
        store.save()
        let config_directory_mode = try posix_mode(
            of: store.path.deletingLastPathComponent())
        let initial_config_mode = try posix_mode(of: store.path)

        precondition(config_directory_mode == 0o700)
        precondition(initial_config_mode == 0o600)
        try set_permissions(0o644, for: store.path)

        store.port = 19092
        store.save()
        let saved_data = try Data(contentsOf: store.path)
        let saved_object = try JSONSerialization.jsonObject(with: saved_data)
            as? [String: Any]
        let updated_config_mode = try posix_mode(of: store.path)
        precondition(saved_object?["port"] as? Int == 19092)
        precondition(updated_config_mode == 0o600)
    }

    // 功能：验证配置目录位置为普通文件时，
    // migration 和 save 都不修改该文件。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_regular_file_obstacle_preserved(test_root: URL) throws {
        for operation in ["migration", "save"] {
            let root = test_root.appendingPathComponent(
                "regular-obstacle-\(operation)",
                isDirectory: true)
            let obstacle = root.appendingPathComponent(".config/gemini2api")
            let obstacle_data = Data("not-a-directory".utf8)
            try write_fixture(obstacle_data, to: obstacle)
            try set_permissions(0o640, for: obstacle)
            let original_mode = try posix_mode(of: obstacle)

            let store = Store(config_root: root)
            if operation == "migration" {
                try write_fixture(Data("{\"port\":18081}".utf8), to: store.legacy_path)
                let error_output = capture_stderr {
                    store.load()
                }
                precondition(error_output.contains("配置迁移失败"))
            } else {
                store.port = 19090
                store.save()
            }

            let preserved_data = try Data(contentsOf: obstacle)
            let preserved_mode = try posix_mode(of: obstacle)
            precondition(preserved_data == obstacle_data)
            precondition(preserved_mode == original_mode)
        }
    }

    // 功能：验证配置目录位置为符号链接时，
    // migration 和 save 都拒绝跟随链接。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_symlink_obstacle_preserved(test_root: URL) throws {
        let file_manager = FileManager.default
        for operation in ["migration", "save"] {
            let root = test_root.appendingPathComponent(
                "symlink-obstacle-\(operation)",
                isDirectory: true)
            let config_parent = root.appendingPathComponent(".config", isDirectory: true)
            let target_directory = root.appendingPathComponent(
                "link-target",
                isDirectory: true)
            let marker_path = target_directory.appendingPathComponent("marker.txt")
            let marker_data = Data("preserve-target".utf8)
            try file_manager.createDirectory(
                at: config_parent,
                withIntermediateDirectories: true)
            try write_fixture(marker_data, to: marker_path)
            try set_permissions(0o750, for: target_directory)
            try set_permissions(0o640, for: marker_path)

            let obstacle = config_parent.appendingPathComponent("gemini2api")
            try file_manager.createSymbolicLink(
                at: obstacle,
                withDestinationURL: target_directory)
            let original_link_target = try file_manager.destinationOfSymbolicLink(
                atPath: obstacle.path)
            let original_link_mode = try lstat_mode(of: obstacle)
            let original_target_mode = try posix_mode(of: target_directory)
            let original_marker_mode = try posix_mode(of: marker_path)

            let store = Store(config_root: root)
            if operation == "migration" {
                try write_fixture(Data("{\"port\":18081}".utf8), to: store.legacy_path)
                let error_output = capture_stderr {
                    store.load()
                }
                precondition(error_output.contains("配置迁移失败"))
            } else {
                store.port = 19090
                store.save()
            }

            let preserved_link_target = try file_manager.destinationOfSymbolicLink(
                atPath: obstacle.path)
            let preserved_marker_data = try Data(contentsOf: marker_path)
            let preserved_link_mode = try lstat_mode(of: obstacle)
            let preserved_target_mode = try posix_mode(of: target_directory)
            let preserved_marker_mode = try posix_mode(of: marker_path)
            precondition(preserved_link_target == original_link_target)
            precondition(preserved_link_mode == original_link_mode)
            precondition(preserved_target_mode == original_target_mode)
            precondition(preserved_marker_mode == original_marker_mode)
            precondition(preserved_marker_data == marker_data)
            precondition(!file_manager.fileExists(
                atPath: target_directory.appendingPathComponent("config.json").path))
        }
    }

    // 功能：验证数组根和标量根的旧 JSON 不会被迁移为新配置。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_non_object_legacy_rejected(test_root: URL) throws {
        let file_manager = FileManager.default
        let fixtures = [
            (name: "array", data: Data("[1,2,3]".utf8)),
            (name: "scalar", data: Data("42".utf8)),
        ]

        for fixture in fixtures {
            let root = test_root.appendingPathComponent(
                "non-object-\(fixture.name)",
                isDirectory: true)
            let legacy_path = root.appendingPathComponent(
                ".config/gemini-web2api/config.json")
            try write_fixture(fixture.data, to: legacy_path)
            let store = Store(config_root: root)

            let error_output = capture_stderr {
                store.load()
            }

            precondition(store.port == 8081)
            precondition(!file_manager.fileExists(atPath: store.path.path))
            precondition(error_output.contains("配置迁移失败"))
            precondition(!error_output.contains(String(decoding: fixture.data, as: UTF8.self)))
        }
    }

    // 功能：验证迁移失败不会写新配置，标准错误也不会泄漏旧 JSON 内容。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_migration_error_redaction(test_root: URL) throws {
        let file_manager = FileManager.default
        let root = test_root.appendingPathComponent("invalid-legacy", isDirectory: true)
        let legacy_path = root.appendingPathComponent(
            ".config/gemini-web2api/config.json")
        let secret = "migration-log-secret"
        let invalid_data = Data("{\"api_keys\":[\"\(secret)\"]".utf8)
        try write_fixture(invalid_data, to: legacy_path)

        let store = Store(config_root: root)
        let error_output = capture_stderr {
            store.load()
        }

        precondition(store.port == 8081)
        precondition(!file_manager.fileExists(atPath: store.path.path))
        precondition(error_output.contains("配置迁移失败"))
        precondition(error_output.contains("旧配置到新配置"))
        precondition(!error_output.contains(secret))
        precondition(!error_output.contains(String(decoding: invalid_data, as: UTF8.self)))
    }

    // 功能：验证成功重复加载时，第二份配置缺失的字段恢复声明默认值。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_repeated_load_resets_missing_fields(test_root: URL) throws {
        let root = test_root.appendingPathComponent("repeated-load", isDirectory: true)
        let path = root.appendingPathComponent(".config/gemini2api/config.json")
        let first_data = Data(
            """
            {
              "port": 20001,
              "host": "127.0.0.1",
              "retry_attempts": 9,
              "retry_delay_sec": 1.25,
              "request_timeout_sec": 2.5,
              "gemini_bl": "custom-bl",
              "auth_user": "7",
              "xsrf_token": "custom-xsrf",
              "default_model": "custom-model",
              "log_requests": false,
              "cookie_file": "custom-cookie",
              "proxy": "custom-proxy",
              "api_keys": ["legacy-key"],
              "launch_at_login": true
            }
            """.utf8)
        try write_fixture(first_data, to: path)
        let store = Store(config_root: root)
        store.load()
        precondition(store.apiKeys == ["legacy-key"])

        try write_fixture(Data("{\"port\":19090}".utf8), to: path)
        store.load()

        precondition(store.port == 19090)
        precondition(store.host == "0.0.0.0")
        precondition(store.retryAttempts == 3)
        precondition(store.retryDelaySec == 2.0)
        precondition(store.requestTimeoutSec == 180.0)
        precondition(store.geminiBl == "boq_assistant-bard-web-server_20260716.08_p0")
        precondition(store.authUser == nil)
        precondition(store.xsrfToken == nil)
        precondition(store.defaultModel == "gemini-3.6-flash")
        precondition(store.logRequests)
        precondition(store.cookieFile == nil)
        precondition(store.proxy == nil)
        precondition(store.apiKeys.isEmpty)
        precondition(!store.launchAtLogin)
    }

    // 功能：验证新配置无法解析为对象时，
    // 不重置或部分覆盖现有内存状态。
    // 参数：test_root 为本次测试的临时根目录。
    // 返回值：无；文件操作失败时抛出错误。
    private static func test_invalid_new_config_preserves_state(test_root: URL) throws {
        let root = test_root.appendingPathComponent("invalid-new", isDirectory: true)
        let path = root.appendingPathComponent(".config/gemini2api/config.json")
        try write_fixture(Data("[1,2,3]".utf8), to: path)
        let store = Store(config_root: root)
        store.port = 21001
        store.host = "127.0.0.1"
        store.retryAttempts = 8
        store.defaultModel = "runtime-model"
        store.authUser = "runtime-user"
        store.apiKeys = ["runtime-key"]
        store.launchAtLogin = true

        store.load()

        precondition(store.port == 21001)
        precondition(store.host == "127.0.0.1")
        precondition(store.retryAttempts == 8)
        precondition(store.defaultModel == "runtime-model")
        precondition(store.authUser == "runtime-user")
        precondition(store.apiKeys == ["runtime-key"])
        precondition(store.launchAtLogin)
    }

    // 功能：创建父目录并写入测试 fixture。
    // 参数：data 为内容，path 为目标文件路径。
    // 返回值：无；目录或文件写入失败时抛出错误。
    private static func write_fixture(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: path)
    }

    // 功能：读取文件或目录的 POSIX 权限位。
    // 参数：path 为待检查路径。
    // 返回值：仅包含低九位的 POSIX mode。
    private static func posix_mode(of path: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw POSIXError(.EIO)
        }
        return permissions.intValue & 0o777
    }

    // 功能：以不跟随符号链接的方式读取路径 POSIX mode。
    // 参数：path 为待检查路径。
    // 返回值：仅包含低九位的 POSIX mode。
    private static func lstat_mode(of path: URL) throws -> Int {
        var status = stat()
        guard lstat(path.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(status.st_mode) & 0o777
    }

    // 功能：为测试 fixture 设置明确的 POSIX 权限。
    // 参数：permissions 为低九位 mode，path 为目标路径。
    // 返回值：无；chmod 失败时抛出 POSIX 错误。
    private static func set_permissions(_ permissions: Int, for path: URL) throws {
        guard chmod(path.path, mode_t(permissions)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // 功能：捕获操作写入标准错误的内容。
    // 参数：operation 为待执行操作。
    // 返回值：UTF-8 解码后的标准错误文本。
    private static func capture_stderr(_ operation: () -> Void) -> String {
        let pipe = Pipe()
        let saved_stderr = dup(STDERR_FILENO)
        precondition(saved_stderr >= 0)
        fflush(stderr)
        precondition(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0)

        operation()

        fflush(stderr)
        precondition(dup2(saved_stderr, STDERR_FILENO) >= 0)
        close(saved_stderr)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
