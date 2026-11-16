import SwiftUI
import Security
import QingcaiCore

final class GatewayNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class GatewayClient {
    let base: URL
    let environment: GatewayEnvironment
    private let token: String
    private let session: URLSession
    init(base: URL, token: String, environment: GatewayEnvironment) {
        self.base = base; self.token = token; self.environment = environment
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false; config.urlCache = nil
        session = URLSession(configuration: config, delegate: GatewayNoRedirect(), delegateQueue: nil)
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, key: String? = nil) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 4_000_000, let http = response as? HTTPURLResponse else { throw FinanceError.invalid("网关响应超出限制或格式无效。") }
        guard (200..<300).contains(http.statusCode) else {
            if let failure = try? JSONDecoder().decode(GatewayAPIError.self, from: data) { throw FinanceError.invalid("\(failure.message)（\(failure.code)）") }
            throw FinanceError.invalid("网关请求失败（HTTP \(http.statusCode)），未自动重新提交。")
        }
        guard http.value(forHTTPHeaderField: "X-Qingcai-Environment") == environment.rawValue else { throw FinanceError.invalid("网关环境不匹配，已阻止使用响应。") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum GatewayKeychain {
    static func save(_ token: String, for endpoint: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.qingcai.community.gateway", kSecAttrAccount as String: endpoint]
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(token.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FinanceError.invalid("无法将网关密钥保存到 macOS 钥匙串。") }
        } else if updated != errSecSuccess { throw FinanceError.invalid("无法更新钥匙串中的网关密钥。") }
    }
    static func load(for endpoint: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.qingcai.community.gateway", kSecAttrAccount as String: endpoint, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor final class IntegrationController: ObservableObject {
    @Published var capabilities: GatewayCapabilities?
    @Published var operations: [GatewayOperation] = []
    @Published var events: [GatewayAuditEvent] = []
    @Published var status = "尚未启动接口环境"
    @Published var error: String?
    @Published var busy = false
    @Published var endpoint = ""
    private var client: GatewayClient?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var logOutput = ""
    private var startup: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var localToken = ""
    private var generation = UUID()
    var isSandbox: Bool { capabilities?.environment == .sandbox }
    var connected: Bool { capabilities != nil }
    deinit { input?.fileHandleForWriting.closeFile(); if let process, process.isRunning { process.terminate() } }
    func startLocal() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        stop(); error = nil; status = "正在启动内置测试网关…"
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/QingcaiGateway")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { error = "未找到内置网关，请安装完整的 1.1 版本。"; status = "启动失败"; return }
        do {
            let task = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            task.executableURL = helper; task.standardInput = input; task.standardOutput = output; task.standardError = errors
            self.process = task; self.input = input; self.output = output; logOutput = ""
            localToken = UUID().uuidString + UUID().uuidString
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QingcaiCommunity/IntegrationSandbox/gateway.sqlite")
            let config: [String: Any] = ["token": localToken, "port": 0, "databasePath": base.path, "mode": "sandbox"]
            let configData = try JSONSerialization.data(withJSONObject: config) + Data([10])
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                Task { @MainActor [weak self] in self?.receiveStartup(data) }
            }
            errors.fileHandleForReading.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
            task.terminationHandler = { [weak self] finished in Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.startup?.resume(throwing: FinanceError.invalid("内置网关已停止，请重新启动。")); self.startup = nil
                self.capabilities = nil; self.client = nil; self.status = "本机网关已停止"
            } }
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                startupTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, let self, let waiting = self.startup else { return }
                    self.startup = nil; waiting.resume(throwing: FinanceError.invalid("内置网关启动超时，请检查安装包或端口。"))
                    if self.process?.isRunning == true { self.process?.terminate() }
                }
                do { try task.run(); try input.fileHandleForWriting.write(contentsOf: configData) }
                catch { startup = nil; continuation.resume(throwing: error) }
            }
            try await refreshThrowing()
        } catch { self.error = error.localizedDescription; status = "连接失败"; stop() }
    }
    private func receiveStartup(_ data: Data) {
        guard startup != nil else { return }
        logOutput += String(data: data, encoding: .utf8) ?? ""
        if let line = logOutput.components(separatedBy: "\n").first(where: { $0.hasPrefix("QINGCAI_GATEWAY_READY ") }),
           let port = UInt16(line.replacingOccurrences(of: "QINGCAI_GATEWAY_READY ", with: "")) {
            endpoint = "http://127.0.0.1:\(port)"
            client = GatewayClient(base: URL(string: endpoint)!, token: localToken, environment: .sandbox)
            startupTimeout?.cancel(); startup?.resume(); startup = nil
        }
    }
    func stop() {
        generation = UUID(); client = nil; capabilities = nil; operations = []; events = []; endpoint = ""
        startupTimeout?.cancel(); startupTimeout = nil
        startup?.resume(throwing: FinanceError.invalid("网关启动已取消。")); startup = nil
        output?.fileHandleForReading.readabilityHandler = nil; input?.fileHandleForWriting.closeFile()
        input = nil; output = nil
        if let process, process.isRunning { process.terminate() }; process = nil
        status = "接口环境已停止"
    }
    func connectLive(endpoint: String, token: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        stop(); error = nil
        do {
            let base = try GatewayEndpoint.validate(endpoint, environment: .live)
            let stored = token.isEmpty ? GatewayKeychain.load(for: base.absoluteString) : token
            guard let secret = stored, secret.utf8.count >= 32 else { throw FinanceError.invalid("请提供正式网关访问密钥（至少 32 字节），或先保存至钥匙串。") }
            self.endpoint = base.absoluteString
            client = GatewayClient(base: base, token: secret, environment: .live)
            try await refreshThrowing()
            try GatewayKeychain.save(secret, for: base.absoluteString)
            UserDefaults.standard.set(base.absoluteString, forKey: "liveGatewayEndpoint")
        } catch { stop(); self.error = error.localizedDescription; status = "正式网关未连接" }
    }
    func refresh() async {
        guard client != nil, !busy else { return }; busy = true; defer { busy = false }
        do { try await refreshThrowing() } catch { self.error = error.localizedDescription; status = "网关暂不可达 · 保留已有任务状态" }
    }
    private func refreshThrowing() async throws {
        guard let client else { return }; let current = generation
        let capabilities: GatewayCapabilities = try await client.request("v1/capabilities")
        guard capabilities.apiVersion == 1, capabilities.environment == client.environment else { throw FinanceError.invalid("网关协议版本或环境不匹配。") }
        let list: GatewayOperationList = try await client.request("v1/operations")
        let audit: GatewayAuditList = try await client.request("v1/audit")
        guard generation == current else { return }
        guard list.operations.allSatisfy({ $0.environment == capabilities.environment }) else { throw FinanceError.invalid("任务中混入其他环境的数据。") }
        self.capabilities = capabilities; operations = list.operations; events = audit.events
        status = capabilities.environment == .sandbox ? "本机测试网关运行中 · 不连接真实机构" : capabilities.productionReady ? "正式网关已连接 · 按已授权能力开放" : "正式网关已连接 · 真实服务尚未就绪"
    }
    func create(_ draft: GatewayDraft) async {
        guard let client, let capabilities, capabilities.availableOperations.contains(draft.kind), capabilities.environment == .sandbox || capabilities.productionReady, !busy else { error = "当前接口能力尚未就绪。"; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let _: GatewayOperation = try await client.request("v1/operations", method: "POST", body: JSONEncoder().encode(draft), key: UUID().uuidString)
            try await refreshThrowing()
        } catch { self.error = "\(error.localizedDescription)\n未自动重复提交，请先刷新并核对任务列表。" }
    }
    func approve(_ operation: GatewayOperation) async {
        guard let client, operation.environment == capabilities?.environment, !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let fresh: GatewayOperation = try await client.request("v1/operations/\(operation.id)/renew-approval", method: "POST", body: Data("{}".utf8))
            guard fresh.status == .awaitingApproval, fresh.environment == operation.environment else { throw FinanceError.invalid("任务状态或环境已改变，请重新查看。") }
            let alert = NSAlert()
            alert.messageText = (fresh.environment == .sandbox ? "确认执行测试：" : "确认办理：") + fresh.kind.label
            let json = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh.payload)), options: [.prettyPrinted, .sortedKeys])
            alert.informativeText = (fresh.environment == .sandbox ? "仅产生模拟回执，不发送真实银行、发票或税务业务。\n\n" : "将按以下不可变草稿向已配置的服务提交办理。请核对主体、所属期、金额、账户和授权范围。\n\n") + String(data: json, encoding: .utf8)!
            alert.addButton(withTitle: fresh.environment == .sandbox ? "确认执行测试" : "确认提交办理"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let _: GatewayOperation = try await client.request("v1/operations/\(fresh.id)/approve", method: "POST", body: JSONEncoder().encode(GatewayApproval(payloadDigest: fresh.payloadDigest, acknowledged: true)))
            try await refreshThrowing()
        } catch { self.error = "\(error.localizedDescription)\n请查询原任务状态，勿重复创建。" }
    }
    func cancel(_ operation: GatewayOperation) async {
        guard let client, !busy else { return }; busy = true; defer { busy = false }
        do { let _: GatewayOperation = try await client.request("v1/operations/\(operation.id)/cancel", method: "POST", body: Data("{}".utf8)); try await refreshThrowing() }
        catch { self.error = error.localizedDescription }
    }
    func sample(_ kind: GatewayOperationKind, timeout: Bool = false) async {
        guard isSandbox else { error = "样例只允许在本机测试环境执行。"; return }
        let draft: GatewayDraft
        switch kind {
        case .bankSync: draft = GatewaySamples.bank()
        case .invoiceIssue:
            var invoice = GatewaySamples.invoice(scenario: timeout ? "timeoutAfterSubmit" : "normal")
            invoice.payload["orderNo"] = .string("SANDBOX-ORDER-" + UUID().uuidString); draft = invoice
        case .taxDeclaration: draft = GatewaySamples.declaration()
        case .taxPayment:
            guard let declaration = operations.first(where: { $0.kind == .taxDeclaration && $0.status == .succeeded }) else { error = "请先完成并取得模拟申报回执。"; return }
            draft = GatewaySamples.payment(declarationID: declaration.id)
        }
        await create(draft)
    }
}
