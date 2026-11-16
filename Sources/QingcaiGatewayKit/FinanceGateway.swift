import Foundation
import QingcaiCore

public actor FinanceGateway {
    private let store: GatewayStore
    private let provider: any GatewayProvider
    public let capabilities: GatewayCapabilities
    public init(database: URL, provider: any GatewayProvider) throws {
        self.store = try GatewayStore(url: database); self.provider = provider; self.capabilities = provider.capabilities
        for var operation in try store.active() where operation.status == .submitting {
            operation.status = .unknown; operation.errorCode = "interrupted_submission"; operation.updatedAt = GatewayClock.string()
            try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: "启动恢复：中断提交转为待核查")
        }
    }
    public func list() throws -> [GatewayOperation] { try store.operations() }
    public func audit() throws -> [GatewayAuditEvent] { try store.audit() }
    public func verifyAudit() throws -> Bool { try store.verifyAudit() }
    public func get(_ id: String) throws -> GatewayOperation {
        guard let operation = try store.lookup(id: id) else { throw GatewayFailure(404, "not_found", "找不到该任务。") }; return operation
    }
    public func create(_ draft: GatewayDraft, key: String, now: Date = Date()) throws -> GatewayOperation {
        guard key.count >= 8 && key.count <= 128, key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw GatewayFailure(400, "idempotency_key", "请求必须带有 8–128 位幂等键。") }
        guard capabilities.availableOperations.contains(draft.kind), capabilities.environment == .sandbox || capabilities.productionReady else {
            throw GatewayFailure(503, "provider_not_ready", "此业务尚未取得并配置真实接口授权。")
        }
        var normalized = draft
        if draft.kind == .taxPayment {
            let id = try Self.required(draft.payload, "declarationID")
            let declaration = try get(id)
            guard declaration.kind == .taxDeclaration, declaration.status == .succeeded, declaration.environment == capabilities.environment,
                  let receipt = declaration.receipt, let amount = receipt["taxAmount"]?.string, let money = Money.parse(amount), money > 0,
                  ["taxpayerID", "period", "authority"].allSatisfy({ receipt[$0]?.string?.isEmpty == false }) else {
                throw GatewayFailure(409, "declaration_not_payable", "须先取得同环境申报成功回执，且存在待缴税款。")
            }
            // Amount and authority come only from the verified declaration, never a payment form.
            for key in ["taxAmount", "taxpayerID", "period", "authority"] { normalized.payload[key] = receipt[key] }
        }
        try validate(normalized)
        let digest = try GatewayHash.digest(normalized)
        if let existing = try store.lookup(key: key) {
            guard existing.payloadDigest == digest else { throw GatewayFailure(409, "idempotency_conflict", "同一幂等键不能用于不同请求内容。") }; return existing
        }
        let business = Self.businessKey(normalized.kind, normalized.payload)
        if let business, let existing = try store.lookup(business: business) {
            guard existing.payloadDigest == digest else { throw GatewayFailure(409, "duplicate_business", "该订单、申报期间或税款已有任务，须先核对原任务。") }; return existing
        }
        let operation = GatewayOperation(id: UUID().uuidString, environment: capabilities.environment, draft: normalized, key: key, digest: digest,
            now: GatewayClock.string(now), expires: normalized.kind.requiresApproval ? GatewayClock.string(now.addingTimeInterval(300)) : nil)
        try store.save(operation, business: business, action: normalized.kind.requiresApproval ? "生成待确认草稿" : "只读同步排队")
        return operation
    }
    public func renewApproval(_ id: String, now: Date = Date()) throws -> GatewayOperation {
        var operation = try get(id)
        guard operation.status == .awaitingApproval && operation.attempts == 0 else { throw GatewayFailure(409, "approval_state", "仅未提交的待确认草稿可刷新确认期限。") }
        operation.approvalExpiresAt = GatewayClock.string(now.addingTimeInterval(300)); operation.updatedAt = GatewayClock.string(now)
        try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: "刷新草稿确认期限")
        return operation
    }
    public func approve(_ id: String, approval: GatewayApproval, now: Date = Date()) throws -> GatewayOperation {
        var operation = try get(id)
        guard approval.acknowledged, approval.payloadDigest == operation.payloadDigest else { throw GatewayFailure(409, "approval_digest", "确认内容与草稿不一致，未提交。") }
        if operation.status != .awaitingApproval {
            // A repeated approval after a lost response must return the same operation.
            guard operation.status != .cancelled else { throw GatewayFailure(409, "cancelled", "草稿已取消。") }; return operation
        }
        guard let expiry = operation.approvalExpiresAt.flatMap(GatewayClock.date), expiry > now else { throw GatewayFailure(409, "approval_expired", "确认已过期，请重新打开并核对草稿。") }
        operation.status = .queued; operation.updatedAt = GatewayClock.string(now)
        try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: "确认内容摘要后排队")
        return operation
    }
    public func cancel(_ id: String) throws -> GatewayOperation {
        var operation = try get(id)
        guard operation.status == .awaitingApproval else { throw GatewayFailure(409, "cancel_state", "已排队或已提交的任务不能当作未提交草稿取消。") }
        operation.status = .cancelled; operation.updatedAt = GatewayClock.string()
        try store.save(operation, business: nil, action: "取消未提交草稿"); return operation
    }
    public func tick() async throws {
        // At most one submission is claimed at a time; persist submitting before network I/O.
        for snapshot in try store.active() {
            var operation = try get(snapshot.id)
            if operation.status == .queued {
                operation.status = .submitting; operation.attempts += 1; operation.updatedAt = GatewayClock.string()
                try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: "提交前持久化")
                do {
                    let result = try await provider.submit(operation)
                    try apply(result, to: &operation, action: "机构受理结果")
                } catch {
                    operation.status = .unknown; operation.errorCode = "submission_result_unknown"; operation.updatedAt = GatewayClock.string()
                    try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: "提交结果未知：仅查询原单")
                }
            } else if operation.status == .pending || operation.status == .unknown {
                do { let result = try await provider.reconcile(operation); try apply(result, to: &operation, action: "查询原单结果") }
                catch {
                    // No resubmission. Retain pending/unknown and audit a generic error only.
                    operation.errorCode = "reconciliation_unavailable"; operation.updatedAt = GatewayClock.string()
                    try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: "查询暂不可用：保留原单")
                }
            }
        }
    }
    private func apply(_ result: GatewayProviderResult, to operation: inout GatewayOperation, action: String) throws {
        guard [.pending, .succeeded, .failed, .unknown].contains(result.status) else { throw GatewayFailure(502, "provider_status", "机构返回了无效状态。") }
        if result.status == .succeeded {
            guard let receipt = result.receipt, receipt["receiptNo"]?.string?.isEmpty == false else { throw GatewayFailure(502, "missing_receipt", "缺少成功回执，不确认已完成。") }
            if operation.environment == .live && receipt["simulated"] == .bool(true) { throw GatewayFailure(502, "environment_mismatch", "测试回执不得作为真实业务结果。") }
        }
        operation.status = result.status; operation.providerReference = result.reference; operation.receipt = result.receipt
        operation.updatedAt = GatewayClock.string(); operation.errorCode = nil
        try store.save(operation, business: Self.businessKey(operation.kind, operation.payload), action: action)
    }
    static func businessKey(_ kind: GatewayOperationKind, _ p: [String: JSONValue]) -> String? {
        let fields: [String]
        switch kind {
        case .bankSync: return nil
        case .invoiceIssue: fields = [kind.rawValue, p["sellerTaxID"]?.string ?? "", p["orderNo"]?.string ?? ""]
        case .taxDeclaration: fields = [kind.rawValue, p["taxpayerID"]?.string ?? "", p["period"]?.string ?? ""]
        case .taxPayment: fields = [kind.rawValue, p["declarationID"]?.string ?? ""]
        }
        return try? GatewayHash.digest(fields)
    }
    private static func required(_ payload: [String: JSONValue], _ key: String) throws -> String {
        guard let value = payload[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 512 else { throw GatewayFailure(422, "invalid_payload", "缺少或无效的字段：\(key)。") }; return value
    }
    private func validate(_ draft: GatewayDraft) throws {
        let p = draft.payload
        func required(_ key: String) throws -> String { try Self.required(p, key) }
        func amount(_ v: JSONValue?) throws -> Decimal {
            guard let s = v?.string, let d = Money.parse(s), d >= 0 else { throw GatewayFailure(422, "invalid_money", "金额必须为最多两位小数的非负字符串。") }; return d
        }
        switch draft.kind {
        case .bankSync:
            _ = try required("accountID")
            guard let start = ChinaDate.parse(try required("from")), let end = ChinaDate.parse(try required("to")), end >= start,
                  end.timeIntervalSince(start) <= 93 * 86400 else { throw GatewayFailure(422, "date_range", "流水查询日期必须有效，且不超过 93 天。") }
        case .invoiceIssue:
            for key in ["orderNo", "sellerTaxID", "buyerName", "invoiceType"] { _ = try required(key) }
            guard ["ordinary", "special"].contains(p["invoiceType"]?.string ?? "") else { throw GatewayFailure(422, "invoice_type", "不支持此票种。") }
            if p["invoiceType"]?.string == "special" { _ = try required("buyerTaxID") }
            let total = try amount(p["grossAmount"])
            guard total > 0, let lines = p["lines"]?.array, (1...100).contains(lines.count) else { throw GatewayFailure(422, "invoice_lines", "请提供有效开票明细。") }
            var sum = Decimal.zero
            for value in lines {
                guard let line = value.object else { throw GatewayFailure(422, "invoice_line", "开票明细格式不正确。") }
                _ = try Self.required(line, "itemName"); _ = try Self.required(line, "taxCode")
                guard let rate = line["vatRate"]?.string.flatMap({ Decimal(string: $0) }), [Decimal(0), 1, 3, 6, 9, 13].contains(rate) else { throw GatewayFailure(422, "vat_rate", "开票税率无效。") }
                let gross = try amount(line["grossAmount"]); guard gross > 0 else { throw GatewayFailure(422, "invoice_amount", "明细金额必须大于零。") }; sum += gross
            }
            guard total == sum else { throw GatewayFailure(422, "invoice_total", "开票明细合计与总额不一致。") }
        case .taxDeclaration:
            for key in ["taxpayerID", "period", "region", "sourceDigest"] { _ = try required(key) }
            guard (try required("period")).range(of: "^20[0-9]{2}-(Q[1-4]|M([1-9]|1[0-2]))$", options: .regularExpression) != nil else { throw GatewayFailure(422, "period", "申报所属期格式无效。") }
            let total = try amount(p["taxAmount"])
            guard let items = p["taxItems"]?.array, !items.isEmpty else { throw GatewayFailure(422, "tax_items", "缺少申报税种明细。") }
            var sum = Decimal.zero
            for item in items { guard let row = item.object else { throw GatewayFailure(422, "tax_items", "税种明细格式不正确。") }; _ = try Self.required(row, "type"); sum += try amount(row["amount"]) }
            guard total == sum else { throw GatewayFailure(422, "tax_total", "申报税种合计与总额不一致。") }
        case .taxPayment:
            _ = try required("accountID"); _ = try required("agreementID")
            guard try amount(p["taxAmount"]) > 0 else { throw GatewayFailure(422, "payment_amount", "无待缴税款。") }
        }
        if capabilities.environment == .sandbox {
            let identity = p["sellerTaxID"]?.string ?? p["taxpayerID"]?.string ?? p["accountID"]?.string ?? ""
            guard identity.hasPrefix("SANDBOX-") else { throw GatewayFailure(422, "sandbox_identity", "测试环境只接受 SANDBOX 样例身份，不接收真实公司数据。") }
        }
    }
}
