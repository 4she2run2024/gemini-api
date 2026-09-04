// 用途：验证 daemon 状态路径、权限、原子发布、锁及进程身份安全边界。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import Darwin
import Foundation

private enum RuntimeStateTestError: Error {
    case expected_failure
    case permission_denied
}

private final class FakeProcessInspector: ProcessInspecting {
    private let result: (Int32) throws -> ProcessIdentity?

    // 功能：创建可控制进程查询分支的测试替身。
    // 参数：result 为收到 PID 后返回身份或抛错的闭包。
    // 返回值：初始化后的替身。
    init(result: @escaping (Int32) throws -> ProcessIdentity?) {
        self.result = result
    }

    // 功能：返回测试指定的进程身份结果。
    // 参数：pid 为待查询进程号。
    // 返回值：闭包指定的身份或 nil；也可抛出指定错误。
    func inspect(pid: Int32) throws -> ProcessIdentity? {
        try result(pid)
    }
}

private final class TestRecycler {
    private let recycler_directory: URL
    private(set) var received_urls: [URL] = []

    // 功能：创建把待回收文件移动至夹具回收区的测试回收器。
    // 参数：recycler_directory 为夹具内回收目录。
    // 返回值：初始化后的回收器。
    init(recycler_directory: URL) throws {
        self.recycler_directory = recycler_directory
        try FileManager.default.createDirectory(
            at: recycler_directory,
            withIntermediateDirectories: true)
    }

    // 功能：记录并移动待回收项目，不永久删除测试文件。
    // 参数：url 为待回收项目。
    // 返回值：无；移动失败时抛出文件系统错误。
    func recycle(_ url: URL) throws {
        received_urls.append(url)
        let destination = recycler_directory.appendingPathComponent(
            "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

@main
struct RuntimeStateTests {
    // 功能：运行状态、锁及进程身份全部行为测试。
    // 参数：无。
    // 返回值：全部断言通过时正常退出，否则抛错或终止测试进程。
    static func main() throws {
        let test_root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini2api-state-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: test_root,
            withIntermediateDirectories: true)
        defer { recycle_test_root_best_effort(test_root) }

        try test_current_user_path_suffixes()
        try test_permissions_and_json_round_trip(test_root: test_root)
        try test_atomic_publish_and_recycling(test_root: test_root)
        try test_exclusive_lock_is_retained(test_root: test_root)
        try test_parent_relinquish_preserves_duplicated_lock(test_root: test_root)
        try test_adopt_accepts_case_equivalent_canonical_path(
            test_root: test_root)
        try test_adopt_rejects_unrelated_regular_file(test_root: test_root)
        try test_adopt_rejects_independent_contended_lock(test_root: test_root)
        try test_symlink_and_non_directory_targets_are_rejected(test_root: test_root)
        try test_identity_classification(test_root: test_root)
        try test_darwin_current_process_identity(test_root: test_root)
        print("RuntimeStateTests passed")
    }

    // 功能：验证生产路径由系统用户目录生成且尾部符合固定契约。
    // 参数：无。
    // 返回值：无；路径不符时终止测试。
    private static func test_current_user_path_suffixes() throws {
        let paths = try RuntimePaths.current_user()
        precondition(paths.state_path.pathComponents.suffix(4) == [
            "Application Support", "Gemini2API", "runtime", "daemon.json",
        ])
        precondition(paths.lock_path.pathComponents.suffix(4) == [
            "Application Support", "Gemini2API", "runtime", "daemon.lock",
        ])
        precondition(paths.log_path.pathComponents.suffix(3) == [
            "Logs", "Gemini2API", "gemini2api.log",
        ])
    }

    // 功能：验证目录和文件权限，并以手写 JSON 字段检查完整 round-trip。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；权限或 JSON 契约不符时终止测试。
    private static func test_permissions_and_json_round_trip(
        test_root: URL
    ) throws {
        let fixture = try make_fixture(test_root: test_root, name: "permissions")
        let lock = try fixture.store.acquire_lock()
        lock.unlock()
        let state = make_state()
        try fixture.store.publish(state)

        precondition(file_mode(fixture.paths.application_directory) == 0o700)
        precondition(file_mode(fixture.paths.runtime_directory) == 0o700)
        precondition(file_mode(fixture.paths.logs_directory) == 0o700)
        precondition(file_mode(fixture.paths.state_path) == 0o600)
        precondition(file_mode(fixture.paths.lock_path) == 0o600)

        let bytes = try Data(contentsOf: fixture.paths.state_path)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let expected_keys: Set<String> = [
            "pid", "executable_path", "process_started_at", "instance_id",
            "host", "port", "version",
        ]
        let actual_keys = Set(object?.keys.map { $0 } ?? [])
        precondition(actual_keys == expected_keys)
        let loaded_state = try fixture.store.load()
        precondition(loaded_state == state)

        let literal = """
        {"pid":42,"executable_path":"/fixture/gemini2api",\
        "process_started_at":1788520000123456,"instance_id":"fixture-id",\
        "host":"127.0.0.1","port":8081,"version":"0.2.0"}
        """
        let decoded = try JSONDecoder().decode(
            DaemonState.self,
            from: Data(literal.utf8))
        precondition(decoded == state)
    }

    // 功能：验证失败发布保留旧状态，遗留和失败 staging 均进入回收器。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；原子性或回收行为不符时终止测试。
    private static func test_atomic_publish_and_recycling(
        test_root: URL
    ) throws {
        let fixture = try make_fixture(test_root: test_root, name: "atomic")
        let old_state = make_state()
        try fixture.store.publish(old_state)

        let abandoned_staging = fixture.paths.runtime_directory
            .appendingPathComponent("daemon.json.abandoned.staging")
        try Data("abandoned".utf8).write(to: abandoned_staging)
        try fixture.store.publish(old_state)
        precondition(fixture.recycler.received_urls.contains(abandoned_staging))

        precondition(chflags(fixture.paths.state_path.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(fixture.paths.state_path.path, 0) }
        do {
            let replacement = make_state(pid: 43, instance_id: "replacement")
            try fixture.store.publish(replacement)
            throw RuntimeStateTestError.expected_failure
        } catch RuntimeStateTestError.expected_failure {
            throw RuntimeStateTestError.expected_failure
        } catch {
            let preserved_state = try fixture.store.load()
            precondition(preserved_state == old_state)
        }

        let failed_staging = fixture.recycler.received_urls.filter {
            $0.lastPathComponent.hasSuffix(".staging") && $0 != abandoned_staging
        }
        precondition(failed_staging.count == 1)
        precondition(failed_staging[0].deletingLastPathComponent()
            == fixture.paths.runtime_directory)
        let remaining_staging = try staging_names(in: fixture.paths.runtime_directory)
        precondition(remaining_staging.isEmpty)

        precondition(chflags(fixture.paths.state_path.path, 0) == 0)
        try fixture.store.recycle_stale_state()
        precondition(fixture.recycler.received_urls.contains(fixture.paths.state_path))
        precondition(!FileManager.default.fileExists(atPath: fixture.paths.state_path.path))
    }

    // 功能：验证两个 contender 不得同时持锁，解锁后可重取并保留锁文件。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；排他锁或保留语义不符时终止测试。
    private static func test_exclusive_lock_is_retained(test_root: URL) throws {
        let fixture = try make_fixture(test_root: test_root, name: "lock")
        let first_lock = try fixture.store.acquire_lock()
        do {
            _ = try fixture.store.acquire_lock()
            throw RuntimeStateTestError.expected_failure
        } catch RuntimeStateTestError.expected_failure {
            throw RuntimeStateTestError.expected_failure
        } catch {
            precondition(FileManager.default.fileExists(atPath: fixture.paths.lock_path.path))
        }
        first_lock.unlock()
        let second_lock = try fixture.store.acquire_lock()
        second_lock.unlock()
        precondition(FileManager.default.fileExists(atPath: fixture.paths.lock_path.path))
    }

    // 功能：验证 spawn 前复制的 descriptor 保留同一 flock，
    // parent relinquish 不会显式解锁 child 所需的 open-file-description。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；复制 fd 持锁时可重取或接管者 unlock 后仍忙时终止测试。
    private static func test_parent_relinquish_preserves_duplicated_lock(
        test_root: URL
    ) throws {
        let fixture = try make_fixture(test_root: test_root, name: "spawn-lock")
        let inherited_lock = try fixture.store.acquire_lock()
        let duplicated_descriptor = try inherited_lock.duplicate_for_spawn(
            minimum_descriptor: 64)
        precondition(duplicated_descriptor >= 64)
        let adopted_lock = try DaemonLock.adopt_after_spawn(
            descriptor: duplicated_descriptor,
            canonical_lock_path: fixture.paths.lock_path)

        inherited_lock.relinquish_after_spawn_in_parent()
        try expect_throw { _ = try fixture.store.acquire_lock() }

        adopted_lock.unlock()
        let replacement_lock = try fixture.store.acquire_lock()
        replacement_lock.unlock()
    }

    // 功能：验证 case-insensitive volume 上不同大小写表示的
    // canonical lock 可接管。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；同 inode 的合法 inherited flock
    // 被路径字符串差异拒绝时抛错。
    private static func test_adopt_accepts_case_equivalent_canonical_path(
        test_root: URL
    ) throws {
        let fixture_name = "Case-Equivalent-Adopt"
        let fixture = try make_fixture(test_root: test_root, name: fixture_name)
        let inherited_lock = try fixture.store.acquire_lock()
        var duplicated_descriptor = try inherited_lock.duplicate_for_spawn(
            minimum_descriptor: 64)
        let alternate_root = test_root.appendingPathComponent(
            fixture_name.lowercased())
        let alternate_paths = RuntimePaths(
            application_support_directory: alternate_root.appendingPathComponent(
                "Application Support"),
            logs_directory: alternate_root.appendingPathComponent("Logs"))
        var canonical_info = stat()
        var alternate_info = stat()
        guard lstat(fixture.paths.lock_path.path, &canonical_info) == 0,
              lstat(alternate_paths.lock_path.path, &alternate_info) == 0 else {
            _ = Darwin.close(duplicated_descriptor)
            inherited_lock.unlock()
            return
        }
        precondition(canonical_info.st_dev == alternate_info.st_dev)
        precondition(canonical_info.st_ino == alternate_info.st_ino)
        precondition(fixture.paths.lock_path.standardizedFileURL
            != alternate_paths.lock_path.standardizedFileURL)

        let adopted_lock: DaemonLock
        do {
            adopted_lock = try DaemonLock.adopt_after_spawn(
                descriptor: duplicated_descriptor,
                canonical_lock_path: alternate_paths.lock_path)
            duplicated_descriptor = -1
        } catch {
            _ = Darwin.close(duplicated_descriptor)
            inherited_lock.unlock()
            throw error
        }
        inherited_lock.relinquish_after_spawn_in_parent()
        try expect_throw { _ = try fixture.store.acquire_lock() }
        adopted_lock.unlock()
        let replacement_lock = try fixture.store.acquire_lock()
        replacement_lock.unlock()
    }

    // 功能：验证 production 接管边界拒绝任意普通文件 descriptor。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；任意文件被当作 daemon lock 接管时终止测试。
    private static func test_adopt_rejects_unrelated_regular_file(
        test_root: URL
    ) throws {
        let fixture = try make_fixture(test_root: test_root, name: "unrelated-adopt")
        let canonical_lock = try fixture.store.acquire_lock()
        canonical_lock.unlock()
        let unrelated_path = test_root.appendingPathComponent("unrelated-file")
        try Data().write(to: unrelated_path)
        var descriptor = Darwin.open(unrelated_path.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RuntimeStateTestError.expected_failure }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }
        do {
            let adopted_lock = try DaemonLock.adopt_after_spawn(
                descriptor: descriptor,
                canonical_lock_path: fixture.paths.lock_path)
            descriptor = -1
            adopted_lock.unlock()
            throw RuntimeStateTestError.expected_failure
        } catch RuntimeStateTestError.expected_failure {
            throw RuntimeStateTestError.expected_failure
        } catch {
            return
        }
    }

    // 功能：验证 canonical lock 被其他 open description 持有时拒绝接管。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；未持有 flock 的独立 descriptor 被接管时终止测试。
    private static func test_adopt_rejects_independent_contended_lock(
        test_root: URL
    ) throws {
        let fixture = try make_fixture(test_root: test_root, name: "held-adopt")
        let owning_lock = try fixture.store.acquire_lock()
        defer { owning_lock.unlock() }
        var descriptor = Darwin.open(
            fixture.paths.lock_path.path,
            O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RuntimeStateTestError.expected_failure }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }
        do {
            let adopted_lock = try DaemonLock.adopt_after_spawn(
                descriptor: descriptor,
                canonical_lock_path: fixture.paths.lock_path)
            descriptor = -1
            adopted_lock.unlock()
            throw RuntimeStateTestError.expected_failure
        } catch RuntimeStateTestError.expected_failure {
            throw RuntimeStateTestError.expected_failure
        } catch {
            return
        }
    }

    // 功能：验证受管目录、状态文件的 symlink 及非目录目标均被拒绝。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；危险目标被接受时终止测试。
    private static func test_symlink_and_non_directory_targets_are_rejected(
        test_root: URL
    ) throws {
        let symlink_root = test_root.appendingPathComponent("symlink")
        let application_support = symlink_root.appendingPathComponent("Application Support")
        let logs = symlink_root.appendingPathComponent("Logs")
        let outside = symlink_root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: application_support,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let application_target = application_support.appendingPathComponent("Gemini2API")
        try FileManager.default.createSymbolicLink(at: application_target,
                                                   withDestinationURL: outside)
        let paths = RuntimePaths(application_support_directory: application_support,
                                 logs_directory: logs)
        let inspector = FakeProcessInspector { _ in nil }
        let store = RuntimeStateStore(paths: paths, process_inspector: inspector) { _ in }
        try expect_throw { _ = try store.acquire_lock() }
        let outside_names = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        precondition(outside_names.isEmpty)

        let non_directory_root = test_root.appendingPathComponent("non-directory")
        let non_directory_support = non_directory_root
            .appendingPathComponent("Application Support")
        let non_directory_logs = non_directory_root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: non_directory_support,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: non_directory_logs,
                                                withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(
            to: non_directory_logs.appendingPathComponent("Gemini2API"))
        let non_directory_paths = RuntimePaths(
            application_support_directory: non_directory_support,
            logs_directory: non_directory_logs)
        let non_directory_store = RuntimeStateStore(
            paths: non_directory_paths,
            process_inspector: inspector) { _ in }
        try expect_throw { _ = try non_directory_store.acquire_lock() }

        let state_fixture = try make_fixture(test_root: test_root, name: "state-symlink")
        let state_lock = try state_fixture.store.acquire_lock()
        state_lock.unlock()
        let sentinel = test_root.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: state_fixture.paths.state_path,
            withDestinationURL: sentinel)
        try expect_throw { _ = try state_fixture.store.load() }
        let sentinel_data = try Data(contentsOf: sentinel)
        precondition(String(decoding: sentinel_data, as: UTF8.self) == "sentinel")
    }

    // 功能：验证缺失、不确定及各项身份差异分类，特别覆盖 PID 重用。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；任一危险身份被接受时终止测试。
    private static func test_identity_classification(test_root: URL) throws {
        let paths = make_paths(test_root: test_root, name: "identity")
        let state = make_state()

        precondition(make_store(paths: paths) { _ in nil }
            .identity_matches(state) == .missing)
        precondition(make_store(paths: paths) { _ in
            throw RuntimeStateTestError.permission_denied
        }.identity_matches(state) == .uncertain)
        precondition(make_store(paths: paths) { _ in
            ProcessIdentity(executable_path: "/fixture/other", process_started_at:
                1_788_520_000_123_456)
        }.identity_matches(state) == .mismatch)
        precondition(make_store(paths: paths) { _ in
            ProcessIdentity(executable_path: "/fixture/gemini2api",
                            process_started_at: 1_788_520_000_123_457)
        }.identity_matches(state) == .mismatch)
        precondition(make_store(paths: paths) { _ in
            ProcessIdentity(executable_path: "/fixture/gemini2api",
                            process_started_at: 1_788_520_000_123_456)
        }.identity_matches(make_state(version: "9.9.9")) == .mismatch)
        precondition(make_store(paths: paths) { _ in
            ProcessIdentity(executable_path: "/fixture/gemini2api",
                            process_started_at: 1_788_520_000_123_456)
        }.identity_matches(make_state(pid: 1)) == .mismatch)
        precondition(make_store(paths: paths) { _ in
            ProcessIdentity(executable_path: "/fixture/gemini2api",
                            process_started_at: 1_788_520_000_123_456)
        }.identity_matches(state) == .match)
    }

    // 功能：用真实 Darwin API 验证当前测试进程的路径和微秒启动时间。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；真实进程无法识别或不能匹配时终止测试。
    private static func test_darwin_current_process_identity(test_root: URL) throws {
        let inspector = DarwinProcessInspector()
        let pid = getpid()
        guard let identity = try inspector.inspect(pid: pid) else {
            throw RuntimeStateTestError.expected_failure
        }
        precondition(identity.executable_path.hasPrefix("/"))
        precondition(identity.process_started_at > 1_000_000_000_000_000)
        let impossible_identity = try inspector.inspect(pid: Int32.max)
        precondition(impossible_identity == nil)

        let paths = make_paths(test_root: test_root, name: "darwin")
        let store = RuntimeStateStore(paths: paths, process_inspector: inspector) { _ in }
        let state = DaemonState(
            pid: pid,
            executable_path: identity.executable_path,
            process_started_at: identity.process_started_at,
            instance_id: "current-process",
            host: "127.0.0.1",
            port: 8081,
            version: "0.2.0")
        precondition(store.identity_matches(state) == .match)
    }

    // 功能：构造固定字段状态，期望值不依赖生产辅助函数。
    // 参数：可覆盖 pid、instance_id 和 version 以测试差异分支。
    // 返回值：完整 DaemonState。
    private static func make_state(
        pid: Int32 = 42,
        instance_id: String = "fixture-id",
        version: String = "0.2.0"
    ) -> DaemonState {
        DaemonState(
            pid: pid,
            executable_path: "/fixture/gemini2api",
            process_started_at: 1_788_520_000_123_456,
            instance_id: instance_id,
            host: "127.0.0.1",
            port: 8081,
            version: version)
    }

    // 功能：构造测试路径，不读取或拼接当前用户名。
    // 参数：test_root 为隔离根；name 区分测试场景。
    // 返回值：注入测试根的 RuntimePaths。
    private static func make_paths(test_root: URL, name: String) -> RuntimePaths {
        let root = test_root.appendingPathComponent(name)
        return RuntimePaths(
            application_support_directory: root.appendingPathComponent("Application Support"),
            logs_directory: root.appendingPathComponent("Logs"))
    }

    // 功能：构造带真实夹具回收器的状态存储。
    // 参数：test_root 为隔离根；name 区分测试场景。
    // 返回值：路径、存储和回收器元组。
    private static func make_fixture(
        test_root: URL,
        name: String
    ) throws -> (paths: RuntimePaths, store: RuntimeStateStore, recycler: TestRecycler) {
        let paths = make_paths(test_root: test_root, name: name)
        let recycler = try TestRecycler(
            recycler_directory: test_root.appendingPathComponent("recycler-\(name)"))
        let inspector = FakeProcessInspector { _ in nil }
        let store = RuntimeStateStore(
            paths: paths,
            process_inspector: inspector,
            trash_item: recycler.recycle)
        return (paths, store, recycler)
    }

    // 功能：构造使用指定 fake 查询分支的状态存储。
    // 参数：paths 为测试路径；result 为进程查询行为。
    // 返回值：配置好的 RuntimeStateStore。
    private static func make_store(
        paths: RuntimePaths,
        result: @escaping (Int32) throws -> ProcessIdentity?
    ) -> RuntimeStateStore {
        RuntimeStateStore(
            paths: paths,
            process_inspector: FakeProcessInspector(result: result)) { _ in }
    }

    // 功能：断言闭包抛错。
    // 参数：operation 为预期失败的操作。
    // 返回值：无；操作成功时抛出测试错误。
    private static func expect_throw(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw RuntimeStateTestError.expected_failure
        } catch RuntimeStateTestError.expected_failure {
            throw RuntimeStateTestError.expected_failure
        } catch {
            return
        }
    }

    // 功能：读取文件类型位以外的 POSIX 权限。
    // 参数：url 为待检查路径。
    // 返回值：权限低 12 位。
    private static func file_mode(_ url: URL) -> mode_t {
        var info = stat()
        precondition(lstat(url.path, &info) == 0)
        return info.st_mode & 0o7777
    }

    // 功能：列出 runtime 目录残留的 staging 文件名。
    // 参数：directory 为 runtime 目录。
    // 返回值：所有 staging 文件名。
    private static func staging_names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".staging")
        }
    }

    // 功能：尽力把测试总目录移入当前用户废纸篓。
    // 参数：test_root 为测试总目录。
    // 返回值：无；失败时输出固定错误。
    private static func recycle_test_root_best_effort(_ test_root: URL) {
        do {
            var trashed_path: NSURL?
            try FileManager.default.trashItem(
                at: test_root,
                resultingItemURL: &trashed_path)
        } catch {
            FileHandle.standardError.write(Data("state fixture 回收失败\n".utf8))
        }
    }
}
