// 用途：验证 daemon 日志权限、stdio 重定向、字段白名单和可恢复轮转。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行；
// stdio 场景在子进程运行。

import Darwin
import Foundation

private enum DaemonLoggerTestError: Error {
    case expected_failure
    case invalid_arguments
    case recycle_failed
}

private enum SensitiveEngineError: Error, CustomStringConvertible {
    case upstream

    var description: String {
        "engine-upstream-secret-fixture"
    }
}

private let LOG_NAME = "gemini2api.log"
private let ARCHIVE_NAME = "archive"

private final class ScriptedSystemCalls {
    private let state_lock = NSLock()
    private let failing_replace_calls: Set<Int>
    private let force_swap_failure: Bool
    private var replace_count = 0

    // 功能：构造按调用序号失败的真实 syscall 包装器。
    // 参数：failing_replace_calls 为失败序号；force_swap_failure 控制交换失败。
    // 返回值：初始化后的包装器。
    init(failing_replace_calls: Set<Int>, force_swap_failure: Bool) {
        self.failing_replace_calls = failing_replace_calls
        self.force_swap_failure = force_swap_failure
    }

    // 功能：除指定序号外执行真实 dup2。
    // 参数：source 和 destination 为 fd。
    // 返回值：真实结果或注入的 -1。
    func replace_descriptor(_ source: Int32, _ destination: Int32) -> Int32 {
        state_lock.lock()
        replace_count += 1
        let current_count = replace_count
        state_lock.unlock()
        if failing_replace_calls.contains(current_count) {
            errno = EIO
            return -1
        }
        return Darwin.dup2(source, destination)
    }

    // 功能：执行真实 RENAME_SWAP 或注入稳定失败。
    // 参数：canonical_path 和 staging_path 为交换路径。
    // 返回值：真实结果或注入的 -1。
    func swap_paths(_ canonical_path: String, _ staging_path: String) -> Int32 {
        if force_swap_failure {
            errno = EIO
            return -1
        }
        return canonical_path.withCString { canonical_pointer in
            staging_path.withCString { staging_pointer in
                renamex_np(canonical_pointer, staging_pointer, UInt32(RENAME_SWAP))
            }
        }
    }
}

private final class CallbackCounter {
    private let state_lock = NSLock()
    private var count = 0

    // 功能：原子递增回调次数。
    // 参数：无。
    // 返回值：递增后的次数。
    func next() -> Int {
        state_lock.lock()
        defer { state_lock.unlock() }
        count += 1
        return count
    }
}

@main
struct DaemonLoggerTests {
    // 功能：运行父进程断言，或按参数进入隔离的 stdio helper。
    // 参数：从 CommandLine 读取 helper 模式和夹具根目录。
    // 返回值：全部断言通过时正常退出。
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            try run_helper_from_arguments()
            return
        }

        let test_root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini2api-logger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: test_root,
            withIntermediateDirectories: true)
        defer { recycle_test_root_best_effort(test_root) }

        try test_permissions_stdio_and_secret_filter(test_root: test_root)
        try test_below_threshold_does_not_rotate(test_root: test_root)
        try test_rotation_switches_fds_before_recycling(test_root: test_root)
        try test_recycle_failure_keeps_current_log_writable(test_root: test_root)
        try test_trash_callback_can_reenter_logger(test_root: test_root)
        try test_partial_dup2_rollback_preserves_each_stream(test_root: test_root)
        try test_rotation_monitor_start_and_stop_are_idempotent(test_root: test_root)
        try test_stop_waits_for_in_flight_monitor(test_root: test_root)
        try test_timer_reentrant_stop_blocks_followup_rotation(test_root: test_root)
        try test_engine_retry_log_excludes_error_description()
        try assert_secret_fixtures_absent_in_files(test_root: test_root)
        print("DaemonLoggerTests passed")
    }

    // 功能：验证新目录和日志模式、stdio fd 效果及所有敏感夹具均未落盘。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；任何契约不符时终止测试。
    private static func test_permissions_stdio_and_secret_filter(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("permissions")
        try run_helper(mode: "permissions", root: root)
        let log_directory = root.appendingPathComponent("logs")
        let log_url = log_directory.appendingPathComponent(LOG_NAME)
        let contents = try String(contentsOf: log_url, encoding: .utf8)

        precondition(file_mode(log_directory) == 0o700)
        precondition(file_mode(log_url) == 0o600)
        precondition(contents.contains("stdout-marker"))
        precondition(contents.contains("stderr-marker"))
        precondition(contents.contains("event=daemon_ready"))
        precondition(contents.contains("host=127.0.0.1"))
        precondition(contents.contains("port=8081"))
        precondition(contents.contains("pid=42"))
        precondition(contents.contains("http_status=200"))
        precondition(contents.contains("error_category=none"))
        precondition(contents.contains("retry_count=0"))
        for secret in secret_fixtures() {
            precondition(!contents.contains(secret))
        }
    }

    // 功能：验证文件低于阈值时不调用回收器且继续追加原文件。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；发生轮转或内容错误时终止测试。
    private static func test_below_threshold_does_not_rotate(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("below-threshold")
        try run_helper(mode: "below-threshold", root: root)
        let contents = try String(contentsOf: log_url(root), encoding: .utf8)
        let archives = try archived_files(root)
        precondition(contents == "ooooooon")
        precondition(archives.isEmpty)
    }

    // 功能：验证达到阈值后 fd 已指向新文件，再把旧 inode 交给回收器。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；顺序、内容或回收次数不符时终止测试。
    private static func test_rotation_switches_fds_before_recycling(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("rotation-order")
        try run_helper(mode: "rotation-order", root: root)
        let current = try String(contentsOf: log_url(root), encoding: .utf8)
        let archives = try archived_files(root)
        precondition(archives.count == 1)
        let old = try String(contentsOf: archives[0], encoding: .utf8)
        precondition(old == "oooooooo")
        precondition(current == "during-trash\nafter-trash\n")
        precondition(file_mode(log_url(root)) == 0o600)
        precondition(file_mode(archives[0]) == 0o600)
    }

    // 功能：验证废纸篓回调失败不回滚新 fd，当前 canonical 日志仍可写。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；写入中断或旧 inode 丢失时终止测试。
    private static func test_recycle_failure_keeps_current_log_writable(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("recycle-failure")
        try run_helper(mode: "recycle-failure", root: root)
        let current = try String(contentsOf: log_url(root), encoding: .utf8)
        let siblings = try log_siblings(root)
        precondition(current.contains("during-failed-trash\n"))
        precondition(current.contains("after-failed-trash\n"))
        precondition(current.contains("event=rotation_error"))
        precondition(!current.contains(root.path))
        precondition(siblings.count == 1)
        let old_data = try Data(contentsOf: siblings[0])
        precondition(old_data == Data(repeating: 0x6f, count: 8))
    }

    // 功能：验证 Trash 回调可重入 write、stop 和 rotate，不被 logger 锁阻塞。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；helper 超时或归档失败时终止测试。
    private static func test_trash_callback_can_reenter_logger(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("reentrant-trash")
        try run_helper(mode: "reentrant-trash", root: root, timeout_seconds: 2)
        let current = try String(contentsOf: log_url(root), encoding: .utf8)
        let archives = try archived_files(root)
        precondition(current.contains("event=daemon_ready"))
        precondition(archives.count == 1)
    }

    // 功能：验证 stdout/stderr 各自回滚失败时仍有可写路径且不回收该路径。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；fd 失效、路径被回收或错误不稳定时终止测试。
    private static func test_partial_dup2_rollback_preserves_each_stream(
        test_root: URL
    ) throws {
        for mode in ["rollback-stdout", "rollback-stderr"] {
            let root = test_root.appendingPathComponent(mode)
            try run_helper(mode: mode, root: root)
            let current = try String(contentsOf: log_url(root), encoding: .utf8)
            let siblings = try log_siblings(root)
            let archives = try archived_files(root)
            precondition(siblings.count == 1)
            precondition(archives.isEmpty)
            let staging = try String(contentsOf: siblings[0], encoding: .utf8)
            let combined = current + staging
            precondition(combined.contains("stdout-viable\n"))
            precondition(combined.contains("stderr-viable\n"))
            precondition(combined.contains("error_category=descriptor_rollback_failed"))
            precondition(!combined.contains(root.path))
        }
    }

    // 功能：验证 monitor 重复启动不会泄漏 timer，
    // 且重复 stop 安全并真正停止检查。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；stop 后仍轮转或回收次数异常时终止测试。
    private static func test_rotation_monitor_start_and_stop_are_idempotent(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("timer")
        try run_helper(mode: "timer", root: root)
        let archives = try archived_files(root)
        let current_data = try Data(contentsOf: log_url(root))
        precondition(archives.count == 1)
        precondition(current_data.count == 8)
    }

    // 功能：验证 stop 等待已进入的 timer handler，返回后不再发生轮转。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；stop 提前返回或返回后仍轮转时终止测试。
    private static func test_stop_waits_for_in_flight_monitor(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("stop-barrier")
        try run_helper(mode: "stop-barrier", root: root)
        let archives = try archived_files(root)
        let current_data = try Data(contentsOf: log_url(root))
        precondition(archives.count == 1)
        precondition(current_data.count == 8)
    }

    // 功能：验证 timer 回调内 stop 返回后，
    // 同一回调不能再发起第二次轮转。
    // 参数：test_root 为隔离测试根。
    // 返回值：无；归档超过一次或新日志被再次切换时终止测试。
    private static func test_timer_reentrant_stop_blocks_followup_rotation(
        test_root: URL
    ) throws {
        let root = test_root.appendingPathComponent("timer-reentrant-stop")
        try run_helper(mode: "timer-reentrant-stop", root: root)
        let archives = try archived_files(root)
        let current_data = try Data(contentsOf: log_url(root))
        precondition(archives.count == 1)
        precondition(current_data == Data(repeating: 0x6e, count: 8))
    }

    // 功能：验证 Engine retry stderr 只记录计数和错误类型，不写原错误描述。
    // 参数：无。
    // 返回值：无；敏感错误描述落盘时终止测试。
    private static func test_engine_retry_log_excludes_error_description() throws {
        let output = try capture_stderr {
            Engine.shared.log_retry(
                attempt: 1,
                total: 3,
                error: SensitiveEngineError.upstream)
        }
        precondition(output.contains("retry=1/3"))
        precondition(output.contains("error_type="))
        precondition(!output.contains("engine-upstream-secret-fixture"))
    }

    // 功能：启动当前测试二进制的 helper 子进程，隔离 stdio fd 修改。
    // 参数：mode 为 helper 场景；root 为该场景夹具根。
    // 返回值：子进程退出零时返回，否则终止测试。
    private static func run_helper(
        mode: String,
        root: URL,
        timeout_seconds: Double = 10
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--daemon-logger-helper", mode, root.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        let wait_result = completed.wait(timeout: .now() + timeout_seconds)
        if wait_result == .timedOut {
            process.terminate()
            process.waitUntilExit()
            preconditionFailure("helper timeout: \(mode)")
        }
        precondition(process.terminationStatus == 0)
    }

    // 功能：解析 helper 参数并执行对应真实文件和 fd 场景。
    // 参数：使用完整 CommandLine 参数。
    // 返回值：无；参数无效时抛错。
    private static func run_helper_from_arguments() throws {
        guard CommandLine.arguments.count == 4,
              CommandLine.arguments[1] == "--daemon-logger-helper" else {
            throw DaemonLoggerTestError.invalid_arguments
        }
        let mode = CommandLine.arguments[2]
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let log_url = root.appendingPathComponent("logs/\(LOG_NAME)")
        let archive_directory = root.appendingPathComponent(ARCHIVE_NAME)
        try FileManager.default.createDirectory(
            at: archive_directory,
            withIntermediateDirectories: true)

        switch mode {
        case "permissions":
            try run_permissions_helper(log_url: log_url)
        case "below-threshold":
            try seed_log(log_url, count: 7)
            let logger = make_logger(log_url: log_url, maximum_bytes: 8,
                                     archive_directory: archive_directory)
            try logger.redirect_standard_streams()
            try logger.rotate_if_needed()
            try write_fd(STDOUT_FILENO, text: "n")
            logger.stop()
        case "rotation-order":
            try seed_log(log_url, count: 8)
            let logger = DaemonLogger(log_url: log_url, maximum_bytes: 8) { old_url in
                try write_fd(STDOUT_FILENO, text: "during-trash\n")
                try archive(old_url, in: archive_directory)
            }
            try logger.redirect_standard_streams()
            try logger.rotate_if_needed()
            try write_fd(STDOUT_FILENO, text: "after-trash\n")
            logger.stop()
        case "recycle-failure":
            try seed_log(log_url, count: 8)
            let logger = DaemonLogger(log_url: log_url, maximum_bytes: 8) { _ in
                try write_fd(STDOUT_FILENO, text: "during-failed-trash\n")
                throw DaemonLoggerTestError.recycle_failed
            }
            try logger.redirect_standard_streams()
            try logger.rotate_if_needed()
            try write_fd(STDERR_FILENO, text: "after-failed-trash\n")
            logger.stop()
        case "reentrant-trash":
            try seed_log(log_url, count: 8)
            var logger: DaemonLogger!
            logger = DaemonLogger(log_url: log_url, maximum_bytes: 8) { old_url in
                try logger.rotate_if_needed()
                logger.write(.info, event: "daemon_ready", fields: [:])
                logger.stop()
                try archive(old_url, in: archive_directory)
            }
            try logger.redirect_standard_streams()
            try logger.rotate_if_needed()
        case "rollback-stdout":
            try run_rollback_helper(
                log_url: log_url,
                archive_directory: archive_directory,
                failing_replace_calls: [4, 5],
                force_swap_failure: false)
        case "rollback-stderr":
            try run_rollback_helper(
                log_url: log_url,
                archive_directory: archive_directory,
                failing_replace_calls: [6],
                force_swap_failure: true)
        case "timer":
            try seed_log(log_url, count: 8)
            let logger = make_logger(log_url: log_url, maximum_bytes: 8,
                                     archive_directory: archive_directory)
            try logger.redirect_standard_streams()
            logger.start_rotation_monitor()
            logger.start_rotation_monitor()
            try wait_for_archive(in: archive_directory)
            logger.stop()
            logger.stop()
            try write_fd(STDOUT_FILENO, bytes: Data(repeating: 0x6e, count: 8))
            Thread.sleep(forTimeInterval: 1.4)
        case "stop-barrier":
            try run_stop_barrier_helper(
                log_url: log_url,
                archive_directory: archive_directory)
        case "timer-reentrant-stop":
            try run_timer_reentrant_stop_helper(
                log_url: log_url,
                archive_directory: archive_directory)
        default:
            throw DaemonLoggerTestError.invalid_arguments
        }
    }

    // 功能：写入允许字段与敏感拒绝字段，供父进程检查持久化边界。
    // 参数：log_url 为隔离日志路径。
    // 返回值：无；重定向或 fd 写入失败时抛错。
    private static func run_permissions_helper(log_url: URL) throws {
        let logger = DaemonLogger(log_url: log_url, maximum_bytes: 4_096) { _ in }
        try logger.redirect_standard_streams()
        try write_fd(STDOUT_FILENO, text: "stdout-marker\n")
        try write_fd(STDERR_FILENO, text: "stderr-marker\n")
        logger.write(.info, event: "daemon_ready", fields: [
            "stage": "listening", "host": "127.0.0.1", "port": "8081",
            "pid": "42", "http_status": "200", "error_category": "none",
            "retry_count": "0", "Cookie": "cookie-secret-fixture",
            "Authorization": "authorization-secret-fixture",
            "x-api-key": "api-key-secret-fixture",
            "x-goog-api-key": "goog-api-key-secret-fixture",
            "key": "key-secret-fixture", "request_body": "request-body-secret-fixture",
            "upstream_body": "upstream-body-secret-fixture",
        ])
        logger.write(.error, event: "unknown-event", fields: [
            "error_category": "unknown-event-secret-fixture",
        ])
        let allowed_events = [
            "daemon_starting", "daemon_ready", "request_completed", "request_retry",
            "daemon_error", "rotation_error", "daemon_stopping",
        ]
        let accepted_fields = [
            "stage", "host", "port", "pid", "http_status", "error_category",
            "retry_count",
        ]
        for event in allowed_events {
            for field in accepted_fields {
                for secret in secret_fixtures() {
                    logger.write(.error, event: event, fields: [field: secret])
                }
            }
        }
        for secret in secret_fixtures() {
            logger.write(.error, event: secret, fields: ["error_category": "none"])
        }
        logger.stop()
    }

    // 功能：注入 fd/交换失败并验证 rotate 抛错后两个标准流仍可写。
    // 参数：log_url 为日志；archive_directory 为归档区；其余参数控制失败点。
    // 返回值：无；rotate 未抛错或 fd 写入失败时抛错。
    private static func run_rollback_helper(
        log_url: URL,
        archive_directory: URL,
        failing_replace_calls: Set<Int>,
        force_swap_failure: Bool
    ) throws {
        try seed_log(log_url, count: 8)
        let script = ScriptedSystemCalls(
            failing_replace_calls: failing_replace_calls,
            force_swap_failure: force_swap_failure)
        let system_calls = DaemonLoggerSystemCalls(
            replace_descriptor: script.replace_descriptor,
            swap_paths: script.swap_paths)
        let logger = DaemonLogger(
            log_url: log_url,
            maximum_bytes: 8,
            trash_item: { old_url in try archive(old_url, in: archive_directory) },
            system_calls: system_calls)
        try logger.redirect_standard_streams()
        do {
            try logger.rotate_if_needed()
            throw DaemonLoggerTestError.expected_failure
        } catch DaemonLoggerTestError.expected_failure {
            throw DaemonLoggerTestError.expected_failure
        } catch {
            try write_fd(STDOUT_FILENO, text: "stdout-viable\n")
            try write_fd(STDERR_FILENO, text: "stderr-viable\n")
        }
        logger.stop()
    }

    // 功能：阻塞 timer 的 Trash 回调并验证 stop 是完整 handler 生命周期屏障。
    // 参数：log_url 为日志；archive_directory 为归档区。
    // 返回值：无；同步超时或 stop 后再次轮转时终止 helper。
    private static func run_stop_barrier_helper(
        log_url: URL,
        archive_directory: URL
    ) throws {
        try seed_log(log_url, count: 8)
        let trash_entered = DispatchSemaphore(value: 0)
        let release_trash = DispatchSemaphore(value: 0)
        let logger = DaemonLogger(log_url: log_url, maximum_bytes: 8) { old_url in
            trash_entered.signal()
            precondition(release_trash.wait(timeout: .now() + 5) == .success)
            try archive(old_url, in: archive_directory)
        }
        try logger.redirect_standard_streams()
        logger.start_rotation_monitor()
        precondition(trash_entered.wait(timeout: .now() + 3) == .success)

        let stop_returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            logger.stop()
            stop_returned.signal()
        }
        precondition(stop_returned.wait(timeout: .now() + 0.2) == .timedOut)
        release_trash.signal()
        precondition(stop_returned.wait(timeout: .now() + 3) == .success)

        try write_fd(STDOUT_FILENO, bytes: Data(repeating: 0x6e, count: 8))
        Thread.sleep(forTimeInterval: 1.4)
    }

    // 功能：在真实 timer Trash 回调内 stop 后尝试立即再次轮转。
    // 参数：log_url 为日志；archive_directory 为归档区。
    // 返回值：无；同步超时时终止 helper。
    private static func run_timer_reentrant_stop_helper(
        log_url: URL,
        archive_directory: URL
    ) throws {
        try seed_log(log_url, count: 8)
        let callback_counter = CallbackCounter()
        let callback_completed = DispatchSemaphore(value: 0)
        var logger: DaemonLogger!
        logger = DaemonLogger(log_url: log_url, maximum_bytes: 8) { old_url in
            let callback_count = callback_counter.next()
            if callback_count == 1 {
                logger.stop()
                try write_fd(
                    STDOUT_FILENO,
                    bytes: Data(repeating: 0x6e, count: 8))
                try logger.rotate_if_needed()
            }
            try archive(old_url, in: archive_directory)
            if callback_count == 1 { callback_completed.signal() }
        }
        try logger.redirect_standard_streams()
        logger.start_rotation_monitor()
        precondition(callback_completed.wait(timeout: .now() + 5) == .success)
        logger.stop()
    }

    // 功能：构造把旧日志移动至夹具归档区的 logger。
    // 参数：log_url 为日志路径；maximum_bytes 为阈值；
    // archive_directory 为归档区。
    // 返回值：配置完成的 logger。
    private static func make_logger(
        log_url: URL,
        maximum_bytes: UInt64,
        archive_directory: URL
    ) -> DaemonLogger {
        DaemonLogger(log_url: log_url, maximum_bytes: maximum_bytes) { old_url in
            try archive(old_url, in: archive_directory)
        }
    }

    // 功能：创建指定字节数的旧日志夹具。
    // 参数：url 为 canonical 日志；count 为字节数。
    // 返回值：无；创建失败时抛错。
    private static func seed_log(_ url: URL, count: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x6f, count: count).write(to: url)
    }

    // 功能：把旧日志移动至夹具归档区，模拟可恢复 Trash 行为。
    // 参数：url 为旧日志；directory 为归档区。
    // 返回值：无；移动失败时抛错。
    private static func archive(_ url: URL, in directory: URL) throws {
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    // 功能：限时等待 timer 完成一次真实归档，
    // 避免依赖固定首次触发时刻。
    // 参数：directory 为夹具归档区。
    // 返回值：发现归档时返回；超时则终止 helper。
    private static func wait_for_archive(in directory: URL) throws {
        for _ in 0..<50 {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if !names.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        preconditionFailure("timer 未触发归档")
    }

    // 功能：将 UTF-8 文本完整写入指定 fd。
    // 参数：descriptor 为 fd；text 为文本。
    // 返回值：无；写入失败时抛错。
    private static func write_fd(_ descriptor: Int32, text: String) throws {
        try write_fd(descriptor, bytes: Data(text.utf8))
    }

    // 功能：将数据完整写入指定 fd。
    // 参数：descriptor 为 fd；bytes 为数据。
    // 返回值：无；写入失败时抛错。
    private static func write_fd(_ descriptor: Int32, bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            var remaining = buffer.count
            var address = buffer.baseAddress
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                remaining -= written
                address = address?.advanced(by: written)
            }
        }
    }

    // 功能：临时捕获 stderr，并在闭包结束后恢复 runner 的原 fd。
    // 参数：operation 为待检查操作。
    // 返回值：捕获到的 UTF-8 文本。
    private static func capture_stderr(_ operation: () -> Void) throws -> String {
        let pipe = Pipe()
        let saved_stderr = Darwin.dup(STDERR_FILENO)
        precondition(saved_stderr >= 0)
        fflush(stderr)
        precondition(Darwin.dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0)
        operation()
        fflush(stderr)
        precondition(Darwin.dup2(saved_stderr, STDERR_FILENO) >= 0)
        _ = Darwin.close(saved_stderr)
        try pipe.fileHandleForWriting.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // 功能：列出夹具归档区中的旧日志。
    // 参数：root 为场景根。
    // 返回值：归档文件 URL 列表。
    private static func archived_files(_ root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent(ARCHIVE_NAME)
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
    }

    // 功能：列出日志目录中 canonical 以外的轮转残留文件。
    // 参数：root 为场景根。
    // 返回值：非 canonical 文件 URL 列表。
    private static func log_siblings(_ root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("logs")
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent != LOG_NAME }
    }

    // 功能：返回必须从持久化日志排除的敏感夹具值。
    // 参数：无。
    // 返回值：敏感字符串数组。
    private static func secret_fixtures() -> [String] {
        [
            "cookie-secret-fixture", "authorization-secret-fixture",
            "api-key-secret-fixture", "goog-api-key-secret-fixture",
            "key-secret-fixture", "request-body-secret-fixture",
            "upstream-body-secret-fixture", "unknown-event-secret-fixture",
        ]
    }

    // 功能：递归扫描全部测试日志和归档，确认敏感夹具未持久化。
    // 参数：test_root 为全部场景的共同根。
    // 返回值：无；发现敏感值时终止测试。
    private static func assert_secret_fixtures_absent_in_files(
        test_root: URL
    ) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: test_root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            preconditionFailure("无法枚举日志夹具")
        }
        for case let file_url as URL in enumerator {
            let values = try file_url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let contents = String(decoding: try Data(contentsOf: file_url), as: UTF8.self)
            for secret in secret_fixtures() {
                precondition(!contents.contains(secret))
            }
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
            FileHandle.standardError.write(Data("logger fixture 回收失败\n".utf8))
        }
    }

    // 功能：返回场景 canonical 日志路径。
    // 参数：root 为场景根。
    // 返回值：日志文件 URL。
    private static func log_url(_ root: URL) -> URL {
        root.appendingPathComponent("logs/\(LOG_NAME)")
    }
}
