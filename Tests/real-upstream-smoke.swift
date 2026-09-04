// 用途：通过本地 Gemini2API Responses endpoint 验证真实 Gemini Web 上游。
// 使用方法：按 Task 10 编译命令构建后直接运行；
// 不输出凭据或原始上游响应。

import Foundation

private enum UpstreamSmokeError: Error, CustomStringConvertible {
    case invalid_response
    case readiness_timeout
    case request_failed(String)
    case status(Int)

    var description: String {
        switch self {
        case .invalid_response:
            return "invalid_response"
        case .readiness_timeout:
            return "readiness_timeout"
        case .request_failed(let category):
            return "request_failed:\(category)"
        case .status(let status):
            return "http_status:\(status)"
        }
    }
}

private struct SmokeHTTPResult {
    let status: Int
    let data: Data
}

private final class SmokeHTTPResultBox {
    var data = Data()
    var error: Error?
    var status = 0
}

@main
struct RealUpstreamSmoke {
    private static let readiness_attempts = 50
    private static let request_timeout_seconds = 210.0

    // 功能：启动随机端口服务并验证真实 Responses 文本输出非空。
    // 参数：无。
    // 返回值：验收通过时正常退出；失败时抛出脱敏错误。
    static func main() throws {
        let store = Store.shared
        store.load()
        store.host = "127.0.0.1"
        store.port = Int.random(in: 20_000...50_000)

        let server = HTTPServer(generator: Engine.shared, config: store)
        try server.start()
        defer { server.stop() }

        let base_url = URL(string: "http://127.0.0.1:\(store.port)")!
        try wait_until_ready(base_url)
        let result = try send_upstream_request(base_url, api_key: store.apiKeys.first)
        guard result.status == 200 else {
            throw UpstreamSmokeError.status(result.status)
        }
        let output_text = try decode_output_text(result.data)
        guard !output_text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UpstreamSmokeError.invalid_response
        }

        let exact_phrase_match = output_text.contains("Gemini2API upstream ok")
        print(
            "real-upstream-smoke PASS status=200 output_text_non_empty=true "
                + "exact_phrase_match=\(exact_phrase_match)")
    }

    // 功能：轮询根 endpoint，直到 HTTPServer 已可接受请求。
    // 参数：base_url 为随机 loopback 服务地址。
    // 返回值：服务就绪时返回；超时抛出脱敏错误。
    private static func wait_until_ready(_ base_url: URL) throws {
        for _ in 0..<readiness_attempts {
            if let result = try? perform_request(URLRequest(url: base_url)),
               result.status == 200 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw UpstreamSmokeError.readiness_timeout
    }

    // 功能：向本地 Responses endpoint 发出真实上游请求。
    // 参数：base_url 为服务根地址；api_key 为可选本地鉴权值。
    // 返回值：HTTP status 和响应数据。
    private static func send_upstream_request(
        _ base_url: URL,
        api_key: String?
    ) throws -> SmokeHTTPResult {
        let url = base_url.appendingPathComponent("v1/responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = request_timeout_seconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let api_key = api_key, !api_key.isEmpty {
            request.setValue("Bearer \(api_key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gemini-3.8-flash",
            "input": "Reply with exactly: Gemini2API upstream ok",
            "store": false,
        ])
        return try perform_request(request)
    }

    // 功能：同步执行一次临时 URLSession 请求。
    // 参数：request 为已完整构造的 URLRequest。
    // 返回值：HTTP status 和响应数据；网络错误仅保留 domain 与 code。
    private static func perform_request(_ request: URLRequest) throws -> SmokeHTTPResult {
        let box = SmokeHTTPResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request_timeout_seconds
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + request_timeout_seconds + 5) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw UpstreamSmokeError.request_failed("timeout")
        }
        session.finishTasksAndInvalidate()
        if let error = box.error as NSError? {
            throw UpstreamSmokeError.request_failed("\(error.domain):\(error.code)")
        }
        return SmokeHTTPResult(status: box.status, data: box.data)
    }

    // 功能：从首个 Responses message 的 output_text part 读取文本。
    // 参数：data 为本地 gateway 返回的 JSON 数据。
    // 返回值：首个 output_text 文本；结构不合法时抛出脱敏错误。
    private static func decode_output_text(_ data: Data) throws -> String {
        guard let response = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let output = response["output"] as? [[String: Any]],
              let message = output.first,
              let content = message["content"] as? [[String: Any]],
              let output_part = content.first(where: {
                  $0["type"] as? String == "output_text"
              }),
              let text = output_part["text"] as? String else {
            throw UpstreamSmokeError.invalid_response
        }
        return text
    }
}
