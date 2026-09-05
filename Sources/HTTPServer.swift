import Foundation
import Network

private let HTTP_SERVER_STOP_TIMEOUT_SECONDS: TimeInterval = 2

// 功能：表达旧 listener 未在有界期限内完成取消。
enum HTTPServerLifecycleError: Error {
    case stop_timed_out
}

// 功能：记录单代 listener 的 cancelled 终态，并允许多次有界等待。
private final class HTTPListenerCancellation {
    private let condition = NSCondition()
    private var cancelled = false

    // 功能：发布 cancelled 终态并唤醒全部等待者。
    // 参数：无。
    // 返回值：无；重复调用保持幂等。
    func complete() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    // 功能：在固定期限内等待 cancelled 终态。
    // 参数：timeout 为最长等待秒数。
    // 返回值：期限内已 cancelled 时为 true。
    func wait(timeout: TimeInterval) -> Bool {
        guard timeout >= 0, timeout.isFinite else { return false }
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled {
            guard condition.wait(until: deadline) else { break }
        }
        return cancelled
    }
}

// 功能：绑定 listener、generation 与单代取消状态。
private final class HTTPListenerRecord {
    let listener: NWListener
    let generation: UInt64
    let cancellation: HTTPListenerCancellation
    var is_stopping = false

    // 功能：创建不可跨代复用的 listener 记录。
    // 参数：listener 为真实监听器；generation 为代际 token；cancellation 为终态。
    // 返回值：初始化后的记录。
    init(
        listener: NWListener,
        generation: UInt64,
        cancellation: HTTPListenerCancellation
    ) {
        self.listener = listener
        self.generation = generation
        self.cancellation = cancellation
    }
}

// 用途：提供 OpenAI、Anthropic 与 Gemini 兼容的极简 HTTP/1.1 路由和写出层。
// 使用方法：以生成器和配置初始化 HTTPServer，再调用 start 启动监听。
final class HTTPServer {
    static let shared = HTTPServer(generator: Engine.shared, config: Store.shared)
    private var listener_record: HTTPListenerRecord?
    private var listener_generation: UInt64 = 0
    private let listener_operation_lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "gemini.http", attributes: .concurrent)
    private let callback_queue_key = DispatchSpecificKey<UInt8>()
    private let running_lock = NSLock()
    private var running_value = false
    var running: Bool {
        running_lock.lock()
        defer { running_lock.unlock() }
        return running_value
    }
    var stateDidChange: ((Bool) -> Void)?
    var state_did_fail: ((Error) -> Void)?
    let generator: TextGenerating
    let cfg: Store

    init(generator: TextGenerating, config: Store) {
        self.generator = generator
        self.cfg = config
        queue.setSpecific(key: callback_queue_key, value: 1)
    }

    func start() throws {
        listener_operation_lock.lock()
        defer { listener_operation_lock.unlock() }
        guard stop_active_listener(timeout: HTTP_SERVER_STOP_TIMEOUT_SECONDS) else {
            throw HTTPServerLifecycleError.stop_timed_out
        }
        let params = NWParameters.tcp
        let port = NWEndpoint.Port(rawValue: UInt16(cfg.port))!
        let l: NWListener
        if cfg.host == "0.0.0.0" || cfg.host.isEmpty {
            l = try NWListener(using: params, on: port)  // 所有网卡（局域网可访问）
        } else {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(cfg.host),
                port: port)
            l = try NWListener(using: params)
        }
        listener_generation &+= 1
        let generation = listener_generation
        let cancellation = HTTPListenerCancellation()
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn, generation: generation)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { cancellation.complete() }
            self?.handle_listener_state(state, generation: generation)
        }
        listener_record = HTTPListenerRecord(
            listener: l,
            generation: generation,
            cancellation: cancellation)
        l.start(queue: queue)
    }

    // 功能：请求当前 listener 停止，并有界等待真实 cancelled 终态。
    // 参数：timeout 为最长等待秒数。
    // 返回值：完整停止时为 true；callback queue 内或超时时为 false。
    @discardableResult
    func stop(timeout: TimeInterval = HTTP_SERVER_STOP_TIMEOUT_SECONDS) -> Bool {
        listener_operation_lock.lock()
        defer { listener_operation_lock.unlock() }
        return stop_active_listener(timeout: timeout)
    }

    // 功能：在串行 lifecycle 临界区停止当前代 listener。
    // 参数：timeout 为最长等待秒数。
    // 返回值：已观察 cancelled 时为 true，否则为 false。
    private func stop_active_listener(timeout: TimeInterval) -> Bool {
        guard let record = listener_record else { return true }
        if !record.is_stopping {
            record.is_stopping = true
            record.listener.cancel()
        }
        if DispatchQueue.getSpecific(key: callback_queue_key) != nil {
            updateRunning(false)
            return false
        }

        let cancelled = record.cancellation.wait(timeout: timeout)
        if cancelled, listener_record?.generation == record.generation {
            listener_record = nil
        }
        updateRunning(false)
        return cancelled
    }

    // 功能：仅让当前 generation 的 state callback 更新状态或报告失败。
    // 参数：state 为 Network 状态；generation 为 callback 所属代际 token。
    // 返回值：无；旧代 callback 被忽略。
    private func handle_listener_state(
        _ state: NWListener.State,
        generation: UInt64
    ) {
        listener_operation_lock.lock()
        defer { listener_operation_lock.unlock() }
        guard let record = listener_record,
              record.generation == generation else { return }
        switch state {
        case .ready:
            if !record.is_stopping { updateRunning(true) }
        case .failed(let error):
            guard !record.is_stopping else { return }
            state_did_fail?(error)
            if listener_record?.generation == generation {
                record.is_stopping = true
                record.listener.cancel()
                updateRunning(false)
            }
        case .cancelled:
            listener_record = nil
            updateRunning(false)
        default:
            break
        }
    }

    private func updateRunning(_ value: Bool) {
        running_lock.lock()
        running_value = value
        running_lock.unlock()
        stateDidChange?(value)
    }

    // MARK: 连接读取

    private func accept(_ conn: NWConnection, generation: UInt64) {
        listener_operation_lock.lock()
        let accepts_connection = listener_record?.generation == generation
            && listener_record?.is_stopping == false
        listener_operation_lock.unlock()
        guard accepts_connection else {
            conn.cancel()
            return
        }
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
        conn.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1 << 16
        ) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { st.buffer.append(d) }

            if !st.headersDone, let r = st.buffer.range(of: Data("\r\n\r\n".utf8)) {
                st.headersDone = true
                st.headerEnd = r.upperBound
                st.headerText = String(
                    decoding: st.buffer[st.buffer.startIndex..<r.lowerBound],
                    as: UTF8.self)
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
            if kv.count == 2 {
                headers[kv[0].lowercased()] = kv[1]
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        if method == "OPTIONS" {
            var response = "HTTP/1.1 204 No Content\r\n"
            response += "Access-Control-Allow-Origin: *\r\n"
            response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            response += "Access-Control-Allow-Headers: *\r\n"
            response += "Content-Length: 0\r\n"
            response += "Connection: close\r\n\r\n"
            sendRaw(conn, response, close: true)
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
            let data = MODELS.map {
                [
                    "id": $0.id,
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "google",
                    "description": $0.desc,
                ] as [String: Any]
            }
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
            if method == "POST", is_gemini_action_target(path) {
                do {
                    let gemini_route = try parse_gemini_route(path)
                    handle_gemini(conn, body: body, route: gemini_route)
                } catch let error as GatewayProtocolError {
                    sendJSON(conn, gemini_error(error), status: error.http_status)
                } catch {
                    sendJSON(
                        conn,
                        gemini_error(status: 400, message: "invalid Gemini path"),
                        status: 400)
                }
                return
            }
            sendJSON(conn, not_found_error(path: path), status: 404)
        }
    }

    private func pathOnly(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    // 功能：识别模型参数可能非法、但 action 形态完整的 Gemini 路径。
    // 参数：path 为包含可选 query 的原始 request target。
    // 返回值：仅在模型仍是单个原始 segment 且 action 已知时为 true。
    private func is_gemini_action_target(_ path: String) -> Bool {
        let endpoint = pathOnly(path)
        let prefix = "/v1beta/models/"
        guard endpoint.hasPrefix(prefix) else { return false }
        let remainder = String(endpoint.dropFirst(prefix.count))
        let actions = [":generateContent", ":streamGenerateContent"]
        for action in actions where remainder.hasSuffix(action) {
            let model = remainder.dropLast(action.count)
            return !model.contains("/")
        }
        return false
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
        conn.send(
            content: Data(s.utf8),
            completion: .contentProcessed { _ in
                if close { conn.cancel() }
            })
    }

    func startSSE(_ conn: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    // 功能：在线程间同步客户端断开状态。
    // 使用方法：Network callback 调用 mark，生成线程调用 is_set。
    final class ClientGone {
        private let lock = NSLock()
        private var value = false

        // 功能：把连接标记为已断开。
        // 参数：无。
        // 返回值：无。
        func mark() {
            lock.lock()
            value = true
            lock.unlock()
        }

        // 功能：读取连接是否已断开。
        // 参数：无。
        // 返回值：已断开时为 true。
        func is_set() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func sseSend(_ conn: NWConnection, _ s: String, gone: ClientGone? = nil) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { err in
            if err != nil { gone?.mark() }
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
