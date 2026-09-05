// 用途：为菜单栏应用和 headless CLI 提供共享 Gateway listener 生命周期。
// 使用方法：加载 Store 后 configure 本次覆盖，再启动并等待终止。

import Darwin
import Dispatch
import Foundation
import Network

struct RuntimeOverrides: Equatable {
    let host: String?
    let port: Int?
    let model: String?
}

struct RuntimeEndpoint: Equatable {
    let host: String
    let port: Int
}

enum GatewayRuntimeError: Error {
    case invalid_host
    case invalid_port
    case invalid_model
    case readiness_timeout
    case listener_failed(Error)
}

enum GatewayRuntimeTerminationReason: Equatable {
    case stopped
    case listener_failed
}

private final class RuntimeStartResult {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    // 功能：只保存并发布第一个 listener 启动结果。
    // 参数：value 为 ready 或 failure 结果。
    // 返回值：无；后续结果被忽略。
    func complete(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        lock.unlock()
        semaphore.signal()
    }

    // 功能：在指定时间内等待 listener 的第一个启动结果。
    // 参数：timeout 为最长等待秒数。
    // 返回值：ready 或 failure；超时返回 nil。
    func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

final class GatewayRuntime {
    private let store: Store
    private let server: HTTPServer
    private let termination_lock = NSLock()
    private let termination_semaphore = DispatchSemaphore(value: 0)
    private var stored_termination_reason: GatewayRuntimeTerminationReason?
    private var signal_sources: [DispatchSourceSignal] = []

    // 功能：使用注入配置和生成器创建独立 HTTPServer。
    // 参数：store 为本次配置；generator 为文本生成器；server 可供测试注入。
    // 返回值：初始化后的共享 runtime。
    init(
        store: Store,
        generator: TextGenerating,
        server: HTTPServer? = nil
    ) {
        self.store = store
        self.server = server ?? HTTPServer(generator: generator, config: store)
    }

    // 功能：验证并原子应用本次内存覆盖，不写回配置文件。
    // 参数：overrides 为可选 host、port 和 model 覆盖。
    // 返回值：最终监听 endpoint；无效覆盖时抛出配置错误。
    func configure(_ overrides: RuntimeOverrides) throws -> RuntimeEndpoint {
        let host = overrides.host ?? store.host
        let port = overrides.port ?? store.port
        let model = overrides.model ?? store.defaultModel
        guard valid_runtime_host(host) else {
            throw GatewayRuntimeError.invalid_host
        }
        guard (1...65_535).contains(port) else {
            throw GatewayRuntimeError.invalid_port
        }
        guard valid_runtime_model(model) else {
            throw GatewayRuntimeError.invalid_model
        }

        store.host = host
        store.port = port
        store.defaultModel = model
        return RuntimeEndpoint(host: host, port: port)
    }

    // 功能：启动 listener，并只在 ready 后返回；failure 或超时则抛错。
    // 参数：readiness_timeout 为最长等待秒数。
    // 返回值：无。
    func start(readiness_timeout: TimeInterval = 10) throws {
        let start_result = RuntimeStartResult()
        server.stateDidChange = { running in
            if running { start_result.complete(.success(())) }
        }
        server.state_did_fail = { [weak self] error in
            start_result.complete(.failure(error))
            self?.complete_termination(.listener_failed)
        }

        do {
            try server.start()
        } catch {
            complete_termination(.listener_failed)
            throw GatewayRuntimeError.listener_failed(error)
        }
        guard readiness_timeout > 0,
              let result = start_result.wait(timeout: readiness_timeout) else {
            server.stop()
            complete_termination(.listener_failed)
            throw GatewayRuntimeError.readiness_timeout
        }
        do {
            try result.get()
        } catch {
            server.stop()
            complete_termination(.listener_failed)
            throw GatewayRuntimeError.listener_failed(error)
        }
    }

    // 功能：安装由 Dispatch 安全处理的 SIGINT 和 SIGTERM 终止事件。
    // 参数：无。
    // 返回值：无；重复调用不会重复安装。
    func install_termination_handlers() {
        guard signal_sources.isEmpty else { return }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal_sources = [SIGINT, SIGTERM].map { signal_number in
            let source = DispatchSource.makeSignalSource(
                signal: signal_number,
                queue: DispatchQueue.global())
            source.setEventHandler { [weak self] in
                self?.stop()
            }
            source.resume()
            return source
        }
    }

    // 功能：阻塞当前调用者，直到 stop、signal 或 listener failure。
    // 参数：无。
    // 返回值：首个正常停止或 listener failure 原因。
    func wait_until_termination() -> GatewayRuntimeTerminationReason {
        termination_semaphore.wait()
        return termination_reason!
    }

    // 功能：读取已保存的首个终止原因。
    // 参数：无。
    // 返回值：尚未终止时为 nil，否则为不可覆盖的首个原因。
    var termination_reason: GatewayRuntimeTerminationReason? {
        termination_lock.lock()
        defer { termination_lock.unlock() }
        return stored_termination_reason
    }

    // 功能：停止 listener 并只发布一次终止事件。
    // 参数：无。
    // 返回值：无。
    func stop() {
        let did_stop = server.stop()
        complete_termination(did_stop ? .stopped : .listener_failed)
    }

    // 功能：锁保护地发布一次终止事件。
    // 参数：reason 为正常停止或 listener failure。
    // 返回值：无；重复调用被忽略。
    private func complete_termination(_ reason: GatewayRuntimeTerminationReason) {
        termination_lock.lock()
        guard stored_termination_reason == nil else {
            termination_lock.unlock()
            return
        }
        stored_termination_reason = reason
        termination_lock.unlock()
        termination_semaphore.signal()
    }

    // 功能：校验 host 非空且不含空白或控制字符，并构造 Network host。
    // 参数：host 为最终监听地址。
    // 返回值：可交给 NWEndpoint.Host 时返回 true。
    private func valid_runtime_host(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        _ = NWEndpoint.Host(host)
        return true
    }

    // 功能：依据共享 MODELS 和 think 范围校验最终模型。
    // 参数：model 为最终模型标识。
    // 返回值：基础模型存在且可选 think 为 0...4 时返回 true。
    private func valid_runtime_model(_ model: String) -> Bool {
        let components = model.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard MODELS.contains(where: { $0.id == components[0] }) else {
            return false
        }
        guard components.count == 2 else { return true }
        let suffix = String(components[1])
        guard suffix.hasPrefix("think="),
              let think = Int(suffix.dropFirst("think=".count)) else {
            return false
        }
        return (0...4).contains(think)
    }
}
