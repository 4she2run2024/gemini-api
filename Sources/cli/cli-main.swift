// 用途：提供 Gemini2API 独立 headless CLI 的生产入口和命令编排。
// 使用方法：CLI 构建包含本文件；测试定义 GEMINI2API_LIBRARY 排除
// production @main。

import Darwin
import Foundation

private let CLI_STATUS_ENCODER: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

final class CLIApplication {
    private let store: Store
    private let generator: TextGenerating
    private let controller_factory: (Store, TextGenerating) throws -> DaemonController

    // 功能：创建共享公开 parser、runtime 和 daemon controller 的 CLI 应用。
    // 参数：store 为配置；generator 为生成器；controller_factory 构造
    // daemon 编排器。
    // 返回值：初始化后的 CLIApplication。
    init(
        store: Store,
        generator: TextGenerating,
        controller_factory: @escaping (Store, TextGenerating) throws
            -> DaemonController
    ) {
        self.store = store
        self.generator = generator
        self.controller_factory = controller_factory
    }

    // 功能：完整解析参数后加载配置，并执行一次公开 CLI 命令。
    // 参数：arguments 不含 executable path。
    // 返回值：稳定 CLI 退出码。
    func run(arguments: [String]) -> CLIExitCode {
        let command: CLICommand
        do {
            command = try parse_cli_command(arguments)
        } catch {
            write_cli_error(cli_usage())
            return .usage
        }

        store.load()
        switch command {
        case .help:
            write_cli_output(cli_usage())
            return .success
        case .version:
            write_cli_output("Gemini2API \(GEMINI2API_VERSION)")
            return .success
        case .serve(let options):
            return run_serve(options)
        case .status(let json):
            return run_status(json: json)
        case .stop(let timeout):
            return run_stop(timeout: timeout)
        }
    }

    // 功能：应用 runtime overrides，并执行前台或 daemon serve。
    // 参数：options 为已由公开 parser 校验的 serve 选项。
    // 返回值：ready、usage、conflict 或 runtime 退出码。
    private func run_serve(_ options: ServeOptions) -> CLIExitCode {
        let runtime = GatewayRuntime(store: store, generator: generator)
        let endpoint: RuntimeEndpoint
        do {
            endpoint = try runtime.configure(RuntimeOverrides(
                host: options.host,
                port: options.port,
                model: options.model))
        } catch GatewayRuntimeError.invalid_host,
                GatewayRuntimeError.invalid_port,
                GatewayRuntimeError.invalid_model {
            write_cli_error("配置错误")
            return .usage
        } catch {
            write_cli_error("服务配置失败")
            return .runtime
        }

        if options.daemon {
            do {
                let controller = try controller_factory(store, generator)
                let exit_code = controller.serve_daemon(options: ServeOptions(
                    host: endpoint.host,
                    port: endpoint.port,
                    model: store.defaultModel,
                    daemon: true))
                write_daemon_start_result(exit_code)
                return exit_code
            } catch {
                write_cli_error("daemon 初始化失败")
                return .runtime
            }
        }

        runtime.install_termination_handlers()
        do {
            try runtime.start()
        } catch GatewayRuntimeError.listener_failed(let error) {
            let exit_code = daemon_listener_exit_code(error)
            write_cli_error(exit_code == .conflict ? "端口已被占用" : "listener 启动失败")
            return exit_code
        } catch {
            write_cli_error("listener 启动失败")
            return .runtime
        }
        write_cli_output(
            "Gemini2API 正在监听 http://\(endpoint.host):\(endpoint.port) "
                + "(PID \(getpid()))")
        runtime.wait_until_termination()
        runtime.stop()
        return .success
    }

    // 功能：输出文本或稳定 JSON 状态报告。
    // 参数：json 指示是否输出机器可读对象。
    // 返回值：DaemonController 给出的状态退出码。
    private func run_status(json: Bool) -> CLIExitCode {
        do {
            let controller = try controller_factory(store, generator)
            let (report, exit_code) = controller.status()
            if json {
                guard let data = try? CLI_STATUS_ENCODER.encode(report),
                      let value = String(data: data, encoding: .utf8) else {
                    write_cli_error("状态编码失败")
                    return .runtime
                }
                write_cli_output(value)
            } else {
                write_cli_output(render_status(report))
            }
            return exit_code
        } catch {
            write_cli_error("状态读取失败")
            return .runtime
        }
    }

    // 功能：安全请求停止托管 daemon，并按退出码选择 stdout 或 stderr。
    // 参数：timeout 为身份轮询最长秒数。
    // 返回值：DaemonController 给出的停止退出码。
    private func run_stop(timeout: TimeInterval) -> CLIExitCode {
        do {
            let exit_code = try controller_factory(store, generator).stop(timeout: timeout)
            switch exit_code {
            case .success:
                write_cli_output("daemon 已停止")
            case .stopped:
                write_cli_output("daemon 未运行")
            case .conflict:
                write_cli_error("daemon 身份不匹配")
            case .runtime:
                write_cli_error("daemon 停止超时或失败")
            case .usage:
                write_cli_error("参数错误")
            }
            return exit_code
        } catch {
            write_cli_error("daemon 初始化失败")
            return .runtime
        }
    }

    // 功能：把 daemon start 的稳定退出码映射为脱敏消息。
    // 参数：exit_code 为 controller 返回值。
    // 返回值：无。
    private func write_daemon_start_result(_ exit_code: CLIExitCode) {
        switch exit_code {
        case .success:
            write_cli_output("daemon 已启动")
        case .conflict:
            write_cli_error("daemon 启动失败：实例或端口冲突")
        case .runtime:
            write_cli_error("daemon 启动失败")
        case .usage:
            write_cli_error("参数错误")
        case .stopped:
            write_cli_error("daemon 未运行")
        }
    }

    // 功能：生成适合终端阅读且不包含凭据的状态文本。
    // 参数：report 为 controller 的稳定状态对象。
    // 返回值：多行中文状态文本。
    private func render_status(_ report: StatusReport) -> String {
        let healthy: String
        switch report.healthy {
        case true:
            healthy = "是"
        case false:
            healthy = "否"
        case nil:
            healthy = "未知"
        }
        var lines = [
            "状态：\(report.state.rawValue)",
            "托管：\(report.managed ? "是" : "否")",
            "健康：\(healthy)",
        ]
        if let pid = report.pid { lines.append("PID：\(pid)") }
        if let host = report.host, let port = report.port {
            lines.append("地址：http://\(host):\(port)")
        }
        if let version = report.version { lines.append("版本：\(version)") }
        return lines.joined(separator: "\n")
    }
}

// 功能：把普通结果原样写入 stdout，并统一补一个换行。
// 参数：message 为不含凭据的用户可见文本或 JSON。
// 返回值：无。
func write_cli_output(_ message: String) {
    FileHandle.standardOutput.write(Data("\(message)\n".utf8))
}

// 功能：把 usage 或失败结果原样写入 stderr，并统一补一个换行。
// 参数：message 为不含原始错误或凭据的用户可见文本。
// 返回值：无。
func write_cli_error(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

// 功能：创建 production 与测试共用 wiring 的 DaemonController。
// 参数：store 已加载；paths 为注入路径；child_environment 仅供测试
// 白名单模式；trash_item 为受管状态的可恢复回收器。
// 返回值：配置完成的 controller。
func make_cli_daemon_controller(
    store: Store,
    paths: RuntimePaths,
    child_environment: [String: String] = [:],
    trash_item: @escaping (URL) throws -> Void = recycle_cli_item
) -> DaemonController {
    let process_inspector = DarwinProcessInspector()
    let state_store = RuntimeStateStore(
        paths: paths,
        process_inspector: process_inspector,
        trash_item: trash_item)
    return DaemonController(
        store: store,
        state_store: state_store,
        health_checker: URLSessionHealthChecker(),
        process_inspector: process_inspector,
        signal_sender: { pid, signal_number in Darwin.kill(pid, signal_number) },
        child_environment: child_environment)
}

// 功能：在 exec 后以 production 相同依赖边界构造并运行 daemon child。
// 参数：invocation、已加载 store、generator、paths、inspector、回收器与
// 可选 logger。
// 返回值：不返回；DaemonChildRunner 负责固定退出码。
func run_cli_daemon_child(
    invocation: DaemonChildInvocation,
    store: Store,
    generator: TextGenerating,
    paths: RuntimePaths,
    process_inspector: ProcessInspecting,
    trash_item: @escaping (URL) throws -> Void = recycle_cli_item,
    logger_factory: (() throws -> DaemonLogger)? = nil
) -> Never {
    let state_store = RuntimeStateStore(
        paths: paths,
        process_inspector: process_inspector,
        trash_item: trash_item)
    let make_logger = logger_factory ?? {
        DaemonLogger(log_url: paths.log_path, trash_item: trash_item)
    }
    let runner = DaemonChildRunner(
        store: store,
        generator: generator,
        runtime_factory: { child_store, child_generator in
            GatewayRuntime(store: child_store, generator: child_generator)
        },
        state_store: state_store,
        logger_factory: make_logger,
        process_inspector: process_inspector)
    runner.run(invocation)
}

// 功能：把 production CLI 的状态和日志文件移入当前用户废纸篓。
// 参数：url 为已由 RuntimePaths 生成并校验的受管路径。
// 返回值：无；失败时抛出原始文件系统错误供调用方分类。
private func recycle_cli_item(_ url: URL) throws {
    var recycled_url: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &recycled_url)
}

#if !GEMINI2API_LIBRARY
@main
struct Gemini2APICLI {
    // 功能：先检查隐藏 exec child invocation，再进入公开 CLI parser。
    // 参数：无；读取 CommandLine.arguments。
    // 返回值：通过 Darwin.exit 或 child runner 结束进程。
    static func main() {
        switch DaemonChildInvocation.parse(arguments: CommandLine.arguments) {
        case .invocation(let invocation):
            Store.shared.load()
            guard let paths = try? RuntimePaths.current_user() else {
                Darwin.exit(CLIExitCode.runtime.rawValue)
            }
            run_cli_daemon_child(
                invocation: invocation,
                store: Store.shared,
                generator: Engine.shared,
                paths: paths,
                process_inspector: DarwinProcessInspector())
        case .invalid:
            write_cli_error(cli_usage())
            Darwin.exit(CLIExitCode.usage.rawValue)
        case .not_internal:
            break
        }

        let application = CLIApplication(
            store: Store.shared,
            generator: Engine.shared,
            controller_factory: { store, _ in
                let paths = try RuntimePaths.current_user()
                return make_cli_daemon_controller(store: store, paths: paths)
            })
        let exit_code = application.run(
            arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(exit_code.rawValue)
    }
}
#endif
