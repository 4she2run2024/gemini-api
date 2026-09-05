// 用途：验证共享 GatewayRuntime 的配置、监听就绪、失败与信号生命周期。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

import CryptoKit
import Darwin
import Foundation

private final class RuntimeFakeGenerator: TextGenerating {
    // 功能：返回固定文本，避免 runtime 测试访问真实上游。
    // 参数：request 为 HTTP 路由生成的请求。
    // 返回值：固定响应文本。
    func generate(_ request: GenerationRequest) throws -> String {
        "runtime test"
    }

    // 功能：返回固定流式增量，避免 runtime 测试访问真实上游。
    // 参数：request 为生成请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if !isCancelled() { onDelta("runtime test") }
    }
}

private enum RuntimeTestError: Error {
    case child_failed
    case invalid_arguments
    case listener_not_ready
    case listener_stop_failed
    case listener_still_running
    case process_timeout
    case socket_failed
}

private struct ReservedPort {
    let descriptor: Int32
    let port: Int
}

@main
struct GatewayRuntimeTests {
    private static let CHILD_TIMEOUT_SECONDS = 5.0
    private static let LISTENER_STOP_ATTEMPTS = 100

    // 功能：运行父进程行为测试，或作为隔离 signal helper 运行。
    // 参数：无；helper 参数从 CommandLine 读取。
    // 返回值：验收通过时正常退出，失败时抛出错误。
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--signal-helper" {
            try run_signal_helper()
            return
        }

        let test_root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini2api-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: test_root,
            withIntermediateDirectories: true)
        defer { recycle_test_root_best_effort(test_root) }

        try test_configure_start_and_stop_preserve_config(test_root: test_root)
        try test_invalid_overrides_are_rejected(test_root: test_root)
        try test_occupied_port_reports_listener_failure(test_root: test_root)
        try test_overlapping_listener_bind_is_exclusive(test_root: test_root)
        try test_app_style_same_port_restart(test_root: test_root)
        try test_listener_callback_stop_is_bounded(test_root: test_root)
        try test_post_ready_listener_failure_is_retained(test_root: test_root)
        try test_signal_stops_listener(signal_number: SIGINT, test_root: test_root)
        try test_signal_stops_listener(signal_number: SIGTERM, test_root: test_root)
        print("GatewayRuntimeTests passed")
    }

    // 功能：验证覆盖只修改内存、start 等待 ready，
    // 且完整生命周期不写配置。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；行为不符时终止测试。
    private static func test_configure_start_and_stop_preserve_config(
        test_root: URL
    ) throws {
        let config_root = test_root.appendingPathComponent("config-preservation")
        let store = try make_loaded_store(config_root: config_root)
        let original_bytes = try Data(contentsOf: store.path)
        let original_hash = SHA256.hash(data: original_bytes)
        let port = try available_loopback_port()
        let runtime = GatewayRuntime(store: store, generator: RuntimeFakeGenerator())

        let endpoint = try runtime.configure(RuntimeOverrides(
            host: "127.0.0.1",
            port: port,
            model: "gemini-3.8-flash@think=2"))
        precondition(endpoint == RuntimeEndpoint(host: "127.0.0.1", port: port))
        precondition(store.host == "127.0.0.1")
        precondition(store.port == port)
        precondition(store.defaultModel == "gemini-3.8-flash@think=2")
        try assert_config_unchanged(store, bytes: original_bytes, hash: original_hash)

        try runtime.start(readiness_timeout: 3)
        let response = try request_root(port: port)
        precondition(response.contains("HTTP/1.1 200"))
        try assert_config_unchanged(store, bytes: original_bytes, hash: original_hash)
        runtime.stop()
        try wait_until_listener_stops(port: port)
        try assert_config_unchanged(store, bytes: original_bytes, hash: original_hash)
    }

    // 功能：验证 host、port、model 无效时 configure 原子拒绝且不修改内存。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；任一无效覆盖被接受时终止测试。
    private static func test_invalid_overrides_are_rejected(test_root: URL) throws {
        let store = try make_loaded_store(
            config_root: test_root.appendingPathComponent("validation"))
        let runtime = GatewayRuntime(store: store, generator: RuntimeFakeGenerator())
        let initial_values = (store.host, store.port, store.defaultModel)
        let invalid_overrides = [
            RuntimeOverrides(host: "", port: nil, model: nil),
            RuntimeOverrides(host: "   ", port: nil, model: nil),
            RuntimeOverrides(host: nil, port: 0, model: nil),
            RuntimeOverrides(host: nil, port: 65_536, model: nil),
            RuntimeOverrides(host: nil, port: nil, model: "unknown-model"),
            RuntimeOverrides(
                host: nil,
                port: nil,
                model: "gemini-3.8-flash@think=5"),
        ]

        for overrides in invalid_overrides {
            do {
                _ = try runtime.configure(overrides)
                preconditionFailure("configure 应拒绝无效覆盖")
            } catch {
                precondition(store.host == initial_values.0)
                precondition(store.port == initial_values.1)
                precondition(store.defaultModel == initial_values.2)
            }
        }
    }

    // 功能：验证端口被占用时 start 返回 listener failure，而不是等待超时。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；未收到 listener failure 时终止测试。
    private static func test_occupied_port_reports_listener_failure(
        test_root: URL
    ) throws {
        let reserved_port = try reserve_loopback_port()
        defer { _ = Darwin.close(reserved_port.descriptor) }
        let store = try make_loaded_store(
            config_root: test_root.appendingPathComponent("occupied-port"))
        let runtime = GatewayRuntime(store: store, generator: RuntimeFakeGenerator())
        _ = try runtime.configure(RuntimeOverrides(
            host: "127.0.0.1",
            port: reserved_port.port,
            model: nil))

        do {
            try runtime.start(readiness_timeout: 3)
            preconditionFailure("被占用端口不应启动成功")
        } catch GatewayRuntimeError.listener_failed {
            runtime.stop()
        }
    }

    // 功能：验证 wildcard、loopback 及同 host 的重叠 listener 均严格互斥。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；第二个 listener ready 时终止测试。
    private static func test_overlapping_listener_bind_is_exclusive(
        test_root: URL
    ) throws {
        let host_pairs = [
            ("0.0.0.0", "127.0.0.1"),
            ("127.0.0.1", "0.0.0.0"),
            ("127.0.0.1", "127.0.0.1"),
        ]
        for (index, pair) in host_pairs.enumerated() {
            let port = try available_loopback_port()
            let first_store = try make_loaded_store(
                config_root: test_root.appendingPathComponent("overlap-first-\(index)"))
            let second_store = try make_loaded_store(
                config_root: test_root.appendingPathComponent("overlap-second-\(index)"))
            let first_runtime = GatewayRuntime(
                store: first_store,
                generator: RuntimeFakeGenerator())
            let second_runtime = GatewayRuntime(
                store: second_store,
                generator: RuntimeFakeGenerator())
            _ = try first_runtime.configure(RuntimeOverrides(
                host: pair.0,
                port: port,
                model: nil))
            _ = try second_runtime.configure(RuntimeOverrides(
                host: pair.1,
                port: port,
                model: nil))
            try first_runtime.start(readiness_timeout: 3)
            defer { first_runtime.stop() }

            do {
                try second_runtime.start(readiness_timeout: 3)
                second_runtime.stop()
                preconditionFailure("重叠 listener 不得同时 ready")
            } catch GatewayRuntimeError.listener_failed {
                second_runtime.stop()
            }
        }
    }

    // 功能：验证 App 保存设置时可等待旧 listener 停止后重复绑定同一地址。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；任一轮未恢复 ready 或根路由不可用时抛错。
    private static func test_app_style_same_port_restart(test_root: URL) throws {
        let store = try make_loaded_store(
            config_root: test_root.appendingPathComponent("app-same-port-restart"))
        store.host = "127.0.0.1"
        store.port = try available_loopback_port()
        let server = HTTPServer(generator: RuntimeFakeGenerator(), config: store)
        try server.start()
        defer { _ = server.stop() }
        try wait_until_server_ready(server)

        for _ in 0..<3 {
            guard server.stop() else { throw RuntimeTestError.listener_stop_failed }
            try server.start()
            try wait_until_server_ready(server)
            let response = try request_root(port: store.port)
            precondition(response.contains("HTTP/1.1 200"))
        }
    }

    // 功能：验证 listener callback 内调用 stop 会有界失败，不等待自身取消。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；callback 阻塞或停止结果不可观察时抛错。
    private static func test_listener_callback_stop_is_bounded(
        test_root: URL
    ) throws {
        let store = try make_loaded_store(
            config_root: test_root.appendingPathComponent("callback-stop"))
        store.host = "127.0.0.1"
        store.port = try available_loopback_port()
        let server = HTTPServer(generator: RuntimeFakeGenerator(), config: store)
        let result_lock = NSLock()
        let callback_finished = DispatchSemaphore(value: 0)
        var did_request_stop = false
        var stop_result: Bool?
        var stop_duration: TimeInterval = 1
        server.stateDidChange = { running in
            result_lock.lock()
            let should_stop = running && !did_request_stop
            if should_stop { did_request_stop = true }
            result_lock.unlock()
            guard should_stop else { return }
            let started_at = Date()
            let result = server.stop(timeout: 0.1)
            result_lock.lock()
            stop_result = result
            stop_duration = Date().timeIntervalSince(started_at)
            result_lock.unlock()
            callback_finished.signal()
        }

        try server.start()
        guard callback_finished.wait(timeout: .now() + 1) == .success else {
            throw RuntimeTestError.listener_stop_failed
        }
        result_lock.lock()
        let observed_result = stop_result
        let observed_duration = stop_duration
        result_lock.unlock()
        precondition(observed_result == false)
        precondition(observed_duration < 0.5)
        guard server.stop(timeout: 2) else {
            throw RuntimeTestError.listener_stop_failed
        }
    }

    // 功能：注入 ready 后 listener failure，并验证终止原因不会被 stop 覆盖。
    // 参数：test_root 为隔离测试总目录。
    // 返回值：无；failure 被误报为正常停止时终止测试。
    private static func test_post_ready_listener_failure_is_retained(
        test_root: URL
    ) throws {
        let store = try make_loaded_store(
            config_root: test_root.appendingPathComponent("post-ready-failure"))
        let server = HTTPServer(generator: RuntimeFakeGenerator(), config: store)
        let runtime = GatewayRuntime(
            store: store,
            generator: RuntimeFakeGenerator(),
            server: server)
        _ = try runtime.configure(RuntimeOverrides(
            host: "127.0.0.1",
            port: try available_loopback_port(),
            model: nil))
        try runtime.start(readiness_timeout: 3)
        server.state_did_fail?(POSIXError(.ECONNABORTED))
        precondition(runtime.wait_until_termination() == .listener_failed)
        runtime.stop()
        precondition(runtime.termination_reason == .listener_failed)
    }

    // 功能：在 helper 子进程中发送指定信号，
    // 验证等待被唤醒且 listener 已停止。
    // 参数：signal_number 为 SIGINT 或 SIGTERM；test_root 为隔离测试总目录。
    // 返回值：无；helper 超时或失败时抛出错误。
    private static func test_signal_stops_listener(
        signal_number: Int32,
        test_root: URL
    ) throws {
        let helper_root = test_root
            .appendingPathComponent("signal-\(signal_number)-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = executable_url()
        process.arguments = [
            "--signal-helper",
            String(signal_number),
            helper_root.path,
        ]
        let output_pipe = Pipe()
        process.standardOutput = output_pipe
        process.standardError = output_pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()

        let ready_line = try read_line(output_pipe.fileHandleForReading)
        precondition(ready_line.hasPrefix("READY "))
        guard kill(process.processIdentifier, signal_number) == 0 else {
            throw RuntimeTestError.child_failed
        }
        guard completed.wait(timeout: .now() + CHILD_TIMEOUT_SECONDS) == .success else {
            _ = kill(process.processIdentifier, SIGKILL)
            throw RuntimeTestError.process_timeout
        }
        let trailing_output = output_pipe.fileHandleForReading.readDataToEndOfFile()
        let output = ready_line + String(decoding: trailing_output, as: UTF8.self)
        guard process.terminationStatus == 0, output.contains("STOPPED") else {
            throw RuntimeTestError.child_failed
        }
    }

    // 功能：安装信号 handler、启动服务并验证信号后 listener 确实停止。
    // 参数：信号编号和隔离配置根来自 CommandLine。
    // 返回值：无；生命周期异常时抛出错误。
    private static func run_signal_helper() throws {
        guard CommandLine.arguments.count == 4,
              let signal_number = Int32(CommandLine.arguments[2]),
              signal_number == SIGINT || signal_number == SIGTERM else {
            throw RuntimeTestError.invalid_arguments
        }
        let config_root = URL(fileURLWithPath: CommandLine.arguments[3])
        let store = try make_loaded_store(config_root: config_root)
        let port = try available_loopback_port()
        let runtime = GatewayRuntime(store: store, generator: RuntimeFakeGenerator())
        _ = try runtime.configure(RuntimeOverrides(
            host: "127.0.0.1",
            port: port,
            model: nil))
        runtime.install_termination_handlers()
        try runtime.start(readiness_timeout: 3)
        write_stdout("READY \(port)\n")
        precondition(runtime.wait_until_termination() == .stopped)
        try wait_until_listener_stops(port: port)
        write_stdout("STOPPED\n")
    }

    // 功能：创建并加载含固定字段的隔离配置。
    // 参数：config_root 为独立用户配置根。
    // 返回值：已从磁盘加载的 Store。
    private static func make_loaded_store(config_root: URL) throws -> Store {
        let store = Store(config_root: config_root)
        try FileManager.default.createDirectory(
            at: store.path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fixture = """
        {
          "host": "0.0.0.0",
          "port": 8081,
          "default_model": "gemini-3.6-flash",
          "api_keys": ["runtime-test-key"]
        }
        """
        try Data(fixture.utf8).write(to: store.path)
        store.load()
        return store
    }

    // 功能：断言配置 bytes 与 SHA-256 均保持不变。
    // 参数：store 定位配置；bytes、hash 为生命周期前快照。
    // 返回值：无；配置发生变化时终止测试。
    private static func assert_config_unchanged(
        _ store: Store,
        bytes: Data,
        hash: SHA256.Digest
    ) throws {
        let current_bytes = try Data(contentsOf: store.path)
        precondition(current_bytes == bytes)
        precondition(SHA256.hash(data: current_bytes) == hash)
    }

    // 功能：短暂绑定系统分配的 loopback 端口后释放。
    // 参数：无。
    // 返回值：当前可用的随机 loopback 端口。
    private static func available_loopback_port() throws -> Int {
        let reserved_port = try reserve_loopback_port()
        guard Darwin.close(reserved_port.descriptor) == 0 else {
            throw RuntimeTestError.socket_failed
        }
        return reserved_port.port
    }

    // 功能：绑定并监听由系统随机分配的 loopback 端口。
    // 参数：无。
    // 返回值：保持占用的 descriptor 和端口。
    private static func reserve_loopback_port() throws -> ReservedPort {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeTestError.socket_failed }
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
            throw RuntimeTestError.socket_failed
        }
        var bound_address = sockaddr_in()
        var bound_length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name_result = withUnsafeMutablePointer(to: &bound_address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &bound_length)
            }
        }
        guard name_result == 0 else {
            _ = Darwin.close(descriptor)
            throw RuntimeTestError.socket_failed
        }
        return ReservedPort(
            descriptor: descriptor,
            port: Int(in_port_t(bigEndian: bound_address.sin_port)))
    }

    // 功能：通过真实 TCP socket 请求根 endpoint。
    // 参数：port 为 loopback listener 端口。
    // 返回值：完整 HTTP 响应文本。
    private static func request_root(port: Int) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeTestError.socket_failed }
        defer { _ = Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connect_result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connect_result == 0 else { throw RuntimeTestError.socket_failed }
        let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
        try write_all(descriptor: descriptor, data: request)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw RuntimeTestError.socket_failed }
            response.append(buffer, count: count)
        }
        return String(decoding: response, as: UTF8.self)
    }

    // 功能：把全部 request bytes 写入 socket。
    // 参数：descriptor 为 socket；data 为待发送 bytes。
    // 返回值：无；写入失败时抛出错误。
    private static func write_all(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: sent),
                    buffer.count - sent)
                guard count > 0 else { throw RuntimeTestError.socket_failed }
                sent += count
            }
        }
    }

    // 功能：轮询确认指定 loopback 端口已拒绝新连接。
    // 参数：port 为原 listener 端口。
    // 返回值：listener 停止时返回；持续可连接时抛出错误。
    private static func wait_until_listener_stops(port: Int) throws {
        for _ in 0..<LISTENER_STOP_ATTEMPTS {
            if !can_connect(port: port) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw RuntimeTestError.listener_still_running
    }

    // 功能：有界等待真实 HTTPServer 进入 ready。
    // 参数：server 为 App 风格直接管理的共享 listener。
    // 返回值：ready 时返回；期限内未 ready 时抛错。
    private static func wait_until_server_ready(_ server: HTTPServer) throws {
        for _ in 0..<100 {
            if server.running { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw RuntimeTestError.listener_not_ready
    }

    // 功能：探测 loopback 端口当前是否接受 TCP 连接。
    // 参数：port 为待探测端口。
    // 返回值：连接成功返回 true，否则返回 false。
    private static func can_connect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // 功能：逐 byte 读取 helper 的单行 readiness 输出。
    // 参数：file_handle 为 helper stdout pipe 读取端。
    // 返回值：包含换行符的 UTF-8 文本。
    private static func read_line(_ file_handle: FileHandle) throws -> String {
        var data = Data()
        while !data.contains(0x0A) {
            let byte = file_handle.readData(ofLength: 1)
            guard !byte.isEmpty else { throw RuntimeTestError.child_failed }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // 功能：动态解析当前测试二进制路径，供 helper 子进程复用。
    // 参数：无。
    // 返回值：当前 executable 的文件 URL。
    private static func executable_url() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }

    // 功能：立即写出 helper 生命周期状态。
    // 参数：text 为待写入标准输出的文本。
    // 返回值：无。
    private static func write_stdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    // 功能：尽力把测试总目录移入废纸篓。
    // 参数：test_root 为测试总目录。
    // 返回值：无；失败时输出固定错误，不泄露路径。
    private static func recycle_test_root_best_effort(_ test_root: URL) {
        do {
            var trashed_path: NSURL?
            try FileManager.default.trashItem(
                at: test_root,
                resultingItemURL: &trashed_path)
        } catch {
            FileHandle.standardError.write(Data("runtime fixture 回收失败\n".utf8))
        }
    }
}
