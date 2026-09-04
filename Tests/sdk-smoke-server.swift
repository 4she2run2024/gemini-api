// 用途：为三个官方 SDK smoke test 提供本地确定性 Gemini2API 服务。
// 使用方法：设置 GEMINI2API_SMOKE_PORT 后运行；收到 TERM 时停止服务。

import Darwin
import Foundation

private final class SDKSmokeGenerator: TextGenerating {
    private let text_output = "Gemini2API SDK ok"

    // 功能：为文本请求返回固定文本，为活动工具请求返回合法 Read 调用。
    // 参数：request 为共享管线生成请求。
    // 返回值：固定文本或结构化 tool_call block。
    func generate(_ request: GenerationRequest) throws -> String {
        if request.prompt.contains("# Local Tool Protocol") {
            return """
            ```tool_call
            {"name":"Read","arguments":{"file_path":"README.md"}}
            ```
            """
        }
        return text_output
    }

    // 功能：把固定文本分成两个增量，供各协议流式编码器处理。
    // 参数：request 为生成请求；isCancelled 判断客户端取消；
    // onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        for delta in ["Gemini2API ", "SDK ok"] where !isCancelled() {
            onDelta(delta)
        }
    }
}

@main
struct SDKSmokeServer {
    // 功能：读取端口、启动本地服务，并在收到 TERM 后完整停止。
    // 参数：无。
    // 返回值：服务生命周期正常结束时返回。
    static func main() throws {
        guard let raw_port = ProcessInfo.processInfo.environment["GEMINI2API_SMOKE_PORT"],
              let port = Int(raw_port),
              (1...65_535).contains(port) else {
            throw NSError(
                domain: "SDKSmokeServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "GEMINI2API_SMOKE_PORT 无效"])
        }

        let store = Store()
        store.host = "127.0.0.1"
        store.port = port
        let server = HTTPServer(generator: SDKSmokeGenerator(), config: store)
        let stop_semaphore = DispatchSemaphore(value: 0)
        signal(SIGTERM, SIG_IGN)
        let term_source = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: DispatchQueue.global())
        term_source.setEventHandler {
            stop_semaphore.signal()
        }
        term_source.resume()

        try server.start()
        try wait_until_ready(server)
        write_stdout("READY port=\(port)\n")
        stop_semaphore.wait()
        server.stop()
        term_source.cancel()
    }

    // 功能：等待 Network listener 进入 ready 状态。
    // 参数：server 为已经开始启动的 HTTPServer。
    // 返回值：就绪时返回；超时抛出错误。
    private static func wait_until_ready(_ server: HTTPServer) throws {
        for _ in 0..<100 {
            if server.running { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "SDKSmokeServer",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "本地服务启动超时"])
    }

    // 功能：立即写出不含敏感信息的 readiness 状态。
    // 参数：text 为待写入标准输出的字符串。
    // 返回值：无。
    private static func write_stdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
