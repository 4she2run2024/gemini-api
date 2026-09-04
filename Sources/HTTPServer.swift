import Foundation
import Network

// 用途：提供 OpenAI、Anthropic 与 Gemini 兼容的极简 HTTP/1.1 路由和写出层。
// 使用方法：以生成器和配置初始化 HTTPServer，再调用 start 启动监听。
final class HTTPServer {
    static let shared = HTTPServer(generator: Engine.shared, config: Store.shared)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "gemini.http", attributes: .concurrent)
    private(set) var running = false
    var stateDidChange: ((Bool) -> Void)?
    let generator: TextGenerating
    let cfg: Store

    init(generator: TextGenerating, config: Store) {
        self.generator = generator
        self.cfg = config
    }

    func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: UInt16(cfg.port))!
        let l: NWListener
        if cfg.host == "0.0.0.0" || cfg.host.isEmpty {
            l = try NWListener(using: params, on: port)  // 所有网卡（局域网可访问）
        } else {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(cfg.host), port: port)
            l = try NWListener(using: params)
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.updateRunning(true)
            case .failed, .cancelled: self?.updateRunning(false)
            default: break
            }
        }
        updateRunning(false)
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        updateRunning(false)
    }

    private func updateRunning(_ value: Bool) {
        running = value
        stateDidChange?(value)
    }

    // MARK: 连接读取

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let state = ConnState()
        readMore(conn, state)
    }

    private final class ConnState {
        var buffer = Data()
        var headersDone = false
        var headerEnd = 0
        var contentLength = 0
        var headerText = ""
    }

    private func readMore(_ conn: NWConnection, _ st: ConnState) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { st.buffer.append(d) }

            if !st.headersDone, let r = st.buffer.range(of: Data("\r\n\r\n".utf8)) {
                st.headersDone = true
                st.headerEnd = r.upperBound
                st.headerText = String(decoding: st.buffer[st.buffer.startIndex..<r.lowerBound], as: UTF8.self)
                st.contentLength = self.contentLength(st.headerText)
            }

            if st.headersDone && st.buffer.count >= st.headerEnd + st.contentLength {
                let body = Data(st.buffer[st.headerEnd..<(st.headerEnd + st.contentLength)])
                self.route(conn, header: st.headerText, body: body)
                return
            }

            if err != nil || isComplete { conn.cancel(); return }
            self.readMore(conn, st)
        }
    }

    private func contentLength(_ header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    // MARK: 路由

    private func route(_ conn: NWConnection, header: String, body: Data) {
        let lines = header.components(separatedBy: "\r\n")
        let reqLine = lines.first ?? ""
        let comps = reqLine.split(separator: " ")
        let method = comps.count > 0 ? String(comps[0]) : ""
        let path = comps.count > 1 ? String(comps[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
        }

        if method == "OPTIONS" {
            sendRaw(conn, "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            return
        }

        if path.hasPrefix("/v1") && !authorized(headers, path: path) {
            sendJSON(
                conn,
                authentication_error(path: path),
                status: 401)
            return
        }

        switch (method, pathOnly(path)) {
        case ("GET", "/v1/models"):
            let data = MODELS.map { ["id": $0.id, "object": "model", "created": 1700000000, "owned_by": "google", "description": $0.desc] as [String: Any] }
            sendJSON(conn, ["object": "list", "data": data])
        case ("GET", "/"):
            sendJSON(conn, ["status": "ok", "models": MODELS.map { $0.id }])
        case ("POST", "/v1/chat/completions"):
            handleOpenAIChat(conn, body: body)
        case ("POST", "/v1/responses"):
            handle_responses(conn, body: body)
        case ("POST", "/v1/messages"):
            handleAnthropicMessages(conn, body: body)
        case ("POST", "/v1/messages/count_tokens"):
            handleAnthropicTokenCount(conn, body: body)
        default:
            if method == "POST", let gemini_route = try? parse_gemini_route(path) {
                handle_gemini(conn, body: body, route: gemini_route)
                return
            }
            sendJSON(conn, not_found_error(path: path), status: 404)
        }
    }

    private func pathOnly(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    private func authorized(_ headers: [String: String], path: String) -> Bool {
        let keys = cfg.apiKeys
        if keys.isEmpty { return true }
        if let auth = headers["authorization"],
           auth.hasPrefix("Bearer "),
           keys.contains(String(auth.dropFirst(7))) {
            return true
        }
        for h in ["x-api-key", "x-goog-api-key"] {
            if let v = headers[h], keys.contains(v) { return true }
        }
        if let query_key = decoded_query_key(path), keys.contains(query_key) {
            return true
        }
        return false
    }

    // 功能：按 request path 选择 401 的协议 envelope。
    // 参数：path 为原始 request target。
    // 返回值：不回显任何凭据的错误 JSON 对象。
    private func authentication_error(path: String) -> [String: Any] {
        switch error_protocol(path) {
        case .openai:
            return openai_error(
                status: 401,
                message: "invalid api key",
                code: "invalid_api_key")
        case .anthropic:
            return [
                "type": "error",
                "error": [
                    "type": "authentication_error",
                    "message": "invalid api key",
                ],
            ]
        case .gemini:
            return gemini_error(status: 401, message: "invalid api key")
        case .generic:
            return ["error": ["message": "invalid api key"]]
        }
    }

    // 功能：按 request path 选择 404 的协议 envelope。
    // 参数：path 为原始 request target。
    // 返回值：OpenAI、Anthropic、Gemini 或通用错误对象。
    private func not_found_error(path: String) -> [String: Any] {
        switch error_protocol(path) {
        case .openai:
            return openai_error(
                status: 404,
                message: "not found",
                code: "not_found")
        case .anthropic:
            return [
                "type": "error",
                "error": [
                    "type": "not_found_error",
                    "message": "not found",
                ],
            ]
        case .gemini:
            return gemini_error(status: 404, message: "not found")
        case .generic:
            return ["error": "not found"]
        }
    }

    // MARK: 写响应

    func sendJSON(_ conn: NWConnection, _ obj: Any, status: Int = 200) {
        let body = Data(jsonString(obj).utf8)
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendRaw(_ conn: NWConnection, _ s: String, close: Bool) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in if close { conn.cancel() } })
    }

    func startSSE(_ conn: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    // ponytail: on 标记无锁读写，Bool 竞争无害，仅用于尽早停止上游
    final class ClientGone { var on = false }

    func sseSend(_ conn: NWConnection, _ s: String, gone: ClientGone? = nil) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { err in
            if err != nil { gone?.on = true }
        })
    }

    func sseFinish(_ conn: NWConnection, _ s: String) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}

// 功能：把统一协议错误编码为 OpenAI error object。
// 参数：error 为统一协议错误。
// 返回值：包含 message、type 和 code 的错误 envelope。
func openai_error(_ error: GatewayProtocolError) -> [String: Any] {
    return openai_error(
        status: error.http_status,
        message: gateway_client_error_message(error),
        code: error.code)
}

// 功能：把统一错误转换为可安全返回客户端的固定消息。
// 参数：error 为统一协议错误。
// 返回值：请求错误保留说明；上游和工具协议错误不包含原始内容。
func gateway_client_error_message(_ error: GatewayProtocolError) -> String {
    switch error {
    case .invalid_request, .unsupported:
        return error.description
    case .upstream:
        return "upstream error"
    case .tool_protocol:
        return "upstream tool protocol error"
    }
}

// 功能：把显式 HTTP 状态和安全消息编码为 OpenAI error object。
// 参数：status 为 HTTP 状态；message 为安全消息；code 为机器错误码。
// 返回值：OpenAI 错误 envelope。
private func openai_error(
    status: Int,
    message: String,
    code: String
) -> [String: Any] {
    let type = status == 401 ? "authentication_error" : "invalid_request_error"
    return [
        "error": [
            "message": message,
            "type": type,
            "code": code,
        ],
    ]
}

// 功能：从原始 request target 解码第一个 key query 参数。
// 参数：path 为可能含 query 的 request target。
// 返回值：正确 percent-decoding 后的 key；缺失或畸形时为 nil。
private func decoded_query_key(_ path: String) -> String? {
    let target_parts = path.split(
        separator: "?",
        maxSplits: 1,
        omittingEmptySubsequences: false)
    guard target_parts.count == 2 else { return nil }
    for pair in target_parts[1].split(
        separator: "&",
        omittingEmptySubsequences: false) {
        let fields = pair.split(
            separator: "=",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard fields.count == 2,
              let name = String(fields[0]).removingPercentEncoding,
              name == "key",
              let value = String(fields[1]).removingPercentEncoding else {
            continue
        }
        return value
    }
    return nil
}

private enum HTTPErrorProtocol {
    case openai
    case anthropic
    case gemini
    case generic
}

// 功能：根据严格 endpoint path 判定错误协议。
// 参数：path 为原始 request target。
// 返回值：可确定的协议；未知 endpoint 返回 generic。
private func error_protocol(_ path: String) -> HTTPErrorProtocol {
    let endpoint = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    if endpoint.hasPrefix("/v1beta/models/") { return .gemini }
    if endpoint == "/v1/messages" || endpoint == "/v1/messages/count_tokens" {
        return .anthropic
    }
    if endpoint == "/v1/chat/completions"
        || endpoint == "/v1/responses"
        || endpoint == "/v1/models" {
        return .openai
    }
    return .generic
}
