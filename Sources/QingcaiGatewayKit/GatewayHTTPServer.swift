import Foundation
import Network
import QingcaiCore

public final class GatewayHTTPServer {
    private let gateway: FinanceGateway
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.qingcai.gateway.http")
    public init(gateway: FinanceGateway, token: String) throws {
        guard token.utf8.count >= 32 else { throw GatewayFailure(500, "weak_token", "网关访问密钥至少需要 32 字节。") }
        self.gateway = gateway; self.token = token
    }
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let request = HTTPConnection(connection: connection, gateway: self.gateway, token: self.token, queue: self.queue)
            request.start()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = GatewayContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed:
                    guard once.claim() else { return }
                    continuation.resume(throwing: GatewayFailure(503, "listen_failed", "本机网关端口无法启动。"))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    public func stop() { listener?.cancel(); listener = nil }
}

private final class GatewayContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !resumed else { return false }; resumed = true; return true }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let gateway: FinanceGateway
    private let token: String
    private let queue: DispatchQueue
    private var data = Data()
    private var processing = false
    private var timeout: DispatchWorkItem?
    init(connection: NWConnection, gateway: FinanceGateway, token: String, queue: DispatchQueue) {
        self.connection = connection; self.gateway = gateway; self.token = token; self.queue = queue
    }
    func start() {
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.connection.cancel() }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, complete, error in
            guard !processing else { return }
            if let chunk { data.append(chunk) }
            guard data.count <= 1_064_960 else { processing = true; fail(GatewayFailure(413, "too_large", "请求内容超出限制。")); return }
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                do {
                    guard range.lowerBound <= 16384, let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { throw GatewayFailure(400, "headers", "请求头无效。") }
                    let (method, path, headers) = try parse(header)
                    guard headers["transfer-encoding"] == nil else { throw GatewayFailure(400, "encoding", "不支持分块请求。") }
                    let length: Int
                    if let raw = headers["content-length"] {
                        guard raw.range(of: "^[0-9]+$", options: .regularExpression) != nil, let n = Int(raw), n <= 1_048_576 else { throw GatewayFailure(413, "content_length", "请求长度无效。") }; length = n
                    } else { guard method == "GET" else { throw GatewayFailure(411, "content_length", "POST 请求需要 Content-Length。") }; length = 0 }
                    let bodySize = data.count - range.upperBound
                    if bodySize < length { if complete { throw GatewayFailure(400, "incomplete", "请求内容不完整。") }; receive(); return }
                    guard bodySize == length else { throw GatewayFailure(400, "pipeline", "每个连接仅支持一个完整请求。") }
                    processing = true; timeout?.cancel()
                    let body = Data(data[range.upperBound...])
                    Task { await handle(method: method, path: path, headers: headers, body: body) }
                } catch { processing = true; fail(error) }
            } else if data.count > 16384 || complete || error != nil { processing = true; fail(GatewayFailure(400, "headers", "请求头不完整。")) }
            else { receive() }
        }
    }
    private func parse(_ header: String) throws -> (String, String, [String: String]) {
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].contains("?"), !first[1].contains("%") else { throw GatewayFailure(400, "request_line", "请求路径或方法无效。") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw GatewayFailure(400, "header", "请求头格式无效。") }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { throw GatewayFailure(400, "duplicate_header", "不接受重复请求头。") }; headers[key] = value
        }
        let host = headers["host"] ?? ""
        guard host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:") else { throw GatewayFailure(403, "host", "仅接受本机网关主机名。") }
        guard headers["origin"] == nil else { throw GatewayFailure(403, "browser_origin", "网关不接受网页跨域调用。") }
        return (String(first[0]), String(first[1]), headers)
    }
    private func handle(method: String, path: String, headers: [String: String], body: Data) async {
        do {
            let environment = await gateway.capabilities.environment
            if method == "GET" && path == "/health" { send(status: 200, data: Data("{\"status\":\"ok\",\"version\":\"1.1.0\"}".utf8), environment: environment); return }
            let supplied = Array((headers["authorization"] ?? "").utf8), expected = Array(("Bearer " + token).utf8)
            var difference = supplied.count ^ expected.count
            for i in 0..<max(supplied.count, expected.count) { difference |= Int((i < supplied.count ? supplied[i] : 0) ^ (i < expected.count ? expected[i] : 0)) }
            guard difference == 0 else { throw GatewayFailure(401, "unauthorized", "网关访问密钥无效。") }
            if method == "POST" { guard headers["content-type"]?.hasPrefix("application/json") == true else { throw GatewayFailure(415, "content_type", "请使用 application/json。") } }
            let response: Data
            if method == "GET" && path == "/v1/capabilities" { response = try GatewayHash.data(await gateway.capabilities) }
            else if method == "GET" && path == "/v1/operations" { response = try GatewayHash.data(["operations": await gateway.list()]) }
            else if method == "GET" && path == "/v1/audit" { response = try GatewayHash.data(["events": await gateway.audit()]) }
            else if method == "POST" && path == "/v1/operations" {
                let draft = try JSONDecoder().decode(GatewayDraft.self, from: body)
                response = try GatewayHash.data(await gateway.create(draft, key: headers["idempotency-key"] ?? ""))
            } else {
                let parts = path.split(separator: "/").map(String.init)
                guard (3...4).contains(parts.count), parts[0] == "v1", parts[1] == "operations", UUID(uuidString: parts[2]) != nil else { throw GatewayFailure(404, "route", "找不到该接口。") }
                if method == "GET" && parts.count == 3 { response = try GatewayHash.data(await gateway.get(parts[2])) }
                else if method == "POST" && parts.count == 4 && parts[3] == "approve" {
                    response = try GatewayHash.data(await gateway.approve(parts[2], approval: JSONDecoder().decode(GatewayApproval.self, from: body)))
                } else if method == "POST" && parts.count == 4 && parts[3] == "renew-approval" { response = try GatewayHash.data(await gateway.renewApproval(parts[2])) }
                else if method == "POST" && parts.count == 4 && parts[3] == "cancel" { response = try GatewayHash.data(await gateway.cancel(parts[2])) }
                else { throw GatewayFailure(404, "route", "找不到该接口。") }
            }
            send(status: 200, data: response, environment: environment)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        let failure = error as? GatewayFailure ?? GatewayFailure(400, "invalid_request", "请求数据格式或内容无效。")
        let body = try! GatewayHash.data(["code": failure.code, "message": failure.message])
        send(status: failure.status, data: body, environment: nil)
    }
    private func send(status: Int, data: Data, environment: GatewayEnvironment?) {
        timeout?.cancel()
        let env = environment.map { "X-Qingcai-Environment: \($0.rawValue)\r\n" } ?? ""
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\(env)\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [self] _ in connection.cancel() })
    }
}
