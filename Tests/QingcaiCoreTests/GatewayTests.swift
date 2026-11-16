import Foundation
import QingcaiCore
import QingcaiGatewayKit

struct GatewayCheckRunner {
    var failures = 0
    var count = 0
    mutating func run(_ name: String, _ work: () async throws -> Void) async {
        count += 1
        do { try await work(); print("PASS \(name)") } catch { failures += 1; print("FAIL \(name): \(error)") }
    }
}
struct GatewayTestFailure: Error { let message: String }
private func expect(_ condition: Bool, _ message: String) throws { if !condition { throw GatewayTestFailure(message: message) } }
private func expectFailure(_ code: String, _ work: () async throws -> Void) async throws {
    do { try await work(); throw GatewayTestFailure(message: "Expected failure \(code)") }
    catch let failure as GatewayFailure { try expect(failure.code == code, "Expected \(code), got \(failure.code)") }
}
private func fixture(_ root: URL, provider: (any GatewayProvider)? = nil) throws -> FinanceGateway {
    try FinanceGateway(database: root.appendingPathComponent(UUID().uuidString + ".sqlite"), provider: provider ?? SandboxProvider())
}
private func finish(_ gateway: FinanceGateway, _ operation: GatewayOperation) async throws -> GatewayOperation {
    if operation.status == .awaitingApproval { _ = try await gateway.approve(operation.id, approval: .init(payloadDigest: operation.payloadDigest, acknowledged: true)) }
    try await gateway.tick(); try await gateway.tick()
    return try await gateway.get(operation.id)
}

func runGatewayChecks() async -> (count: Int, failures: Int) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qingcai-gateway-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var runner = GatewayCheckRunner()
    await runner.run("gateway_bank_to_invoice_to_declaration_to_payment") {
        let gateway = try fixture(root)
        let bank = try await gateway.create(GatewaySamples.bank(), key: "bank-key-001")
        let invoice = try await gateway.create(GatewaySamples.invoice(), key: "invoice-key-001")
        let declaration = try await gateway.create(GatewaySamples.declaration(), key: "test-dcl")
        try expect(bank.status == .queued && invoice.status == .awaitingApproval, "Read/write approval states")
        let invoiceResult = try await finish(gateway, invoice)
        try expect(invoiceResult.status == .succeeded && invoiceResult.receipt?["simulated"] == .bool(true), "Invoice test receipt")
        let declarationResult = try await finish(gateway, declaration)
        let payment = try await gateway.create(GatewaySamples.payment(declarationID: declarationResult.id), key: "payment-key-001")
        try expect(payment.payload["taxAmount"] == .string("103.50"), "Payment amount inherited from declaration")
        let paymentResult = try await finish(gateway, payment)
        let bankResult = try await gateway.get(bank.id)
        try expect(paymentResult.status == .succeeded && bankResult.receipt?["bankLines"]?.array?.count == 2, "Full sandbox flow")
    }
    await runner.run("gateway_idempotency_returns_original_operation") {
        let gateway = try fixture(root)
        let a = try await gateway.create(GatewaySamples.invoice(), key: "same-key-001")
        let b = try await gateway.create(GatewaySamples.invoice(), key: "same-key-001")
        try expect(a.id == b.id, "Duplicate task created")
    }
    await runner.run("gateway_idempotency_rejects_changed_payload") {
        let gateway = try fixture(root); _ = try await gateway.create(GatewaySamples.invoice(), key: "same-key-002")
        var changed = GatewaySamples.invoice(); changed.payload["buyerName"] = .string("另一个测试买方")
        try await expectFailure("idempotency_conflict") { _ = try await gateway.create(changed, key: "same-key-002") }
    }
    await runner.run("gateway_order_period_and_payment_business_deduplication") {
        let gateway = try fixture(root)
        let a = try await gateway.create(GatewaySamples.invoice(), key: "business-key-1")
        let b = try await gateway.create(GatewaySamples.invoice(), key: "business-key-2")
        try expect(a.id == b.id, "Order duplicated with different client keys")
        let d1 = try await gateway.create(GatewaySamples.declaration(), key: "test-d01")
        let d2 = try await gateway.create(GatewaySamples.declaration(), key: "test-d02")
        try expect(d1.id == d2.id, "Declaration duplicated")
        let done = try await finish(gateway, d1)
        let p1 = try await gateway.create(GatewaySamples.payment(declarationID: done.id), key: "payment-dedupe-1")
        let p2 = try await gateway.create(GatewaySamples.payment(declarationID: done.id), key: "payment-dedupe-2")
        try expect(p1.id == p2.id, "Payment duplicated")
    }
    await runner.run("gateway_approval_binds_payload_and_acknowledgement") {
        let gateway = try fixture(root); let op = try await gateway.create(GatewaySamples.invoice(), key: "test-app")
        try await expectFailure("approval_digest") { _ = try await gateway.approve(op.id, approval: .init(payloadDigest: "changed", acknowledged: true)) }
        try await expectFailure("approval_digest") { _ = try await gateway.approve(op.id, approval: .init(payloadDigest: op.payloadDigest, acknowledged: false)) }
        try await gateway.tick(); let after = try await gateway.get(op.id)
        try expect(after.status == .awaitingApproval && after.attempts == 0, "Unapproved write submitted")
    }
    await runner.run("gateway_expired_approval_requires_renewal") {
        let gateway = try fixture(root); let now = Date()
        let op = try await gateway.create(GatewaySamples.invoice(), key: "expiry-key-0001", now: now)
        let expired = now.addingTimeInterval(301)
        try await expectFailure("approval_expired") { _ = try await gateway.approve(op.id, approval: .init(payloadDigest: op.payloadDigest, acknowledged: true), now: expired) }
        let renewed = try await gateway.renewApproval(op.id, now: expired)
        _ = try await gateway.approve(renewed.id, approval: .init(payloadDigest: renewed.payloadDigest, acknowledged: true), now: expired)
    }
    await runner.run("gateway_timeout_queries_original_and_never_resubmits") {
        let provider = SandboxProvider(), gateway = try fixture(root, provider: provider)
        let op = try await gateway.create(GatewaySamples.invoice(scenario: "timeoutAfterSubmit"), key: "timeout-key-0001")
        _ = try await gateway.approve(op.id, approval: .init(payloadDigest: op.payloadDigest, acknowledged: true))
        try await gateway.tick(); let unknown = try await gateway.get(op.id)
        try expect(unknown.status == .unknown, "Timeout should not report failure or success")
        try await gateway.tick(); try await gateway.tick()
        let result = try await gateway.get(op.id), count = await provider.submissionCount(op.idempotencyKey)
        try expect(result.status == .succeeded && count == 1 && result.attempts == 1, "Write repeated after timeout")
    }
    await runner.run("gateway_parallel_ticks_claim_submission_once") {
        let provider = SandboxProvider(), gateway = try fixture(root, provider: provider)
        let op = try await gateway.create(GatewaySamples.bank(), key: "parallel-key-001")
        async let one: Void = gateway.tick(); async let two: Void = gateway.tick(); _ = try await (one, two)
        let count = await provider.submissionCount(op.idempotencyKey)
        try expect(count == 1, "Concurrent worker duplicated submission")
    }
    await runner.run("gateway_payment_requires_successful_declaration") {
        let gateway = try fixture(root)
        let declaration = try await gateway.create(GatewaySamples.declaration(), key: "unfiled-key-001")
        try await expectFailure("declaration_not_payable") { _ = try await gateway.create(GatewaySamples.payment(declarationID: declaration.id), key: "unpaid-key-0001") }
    }
    await runner.run("gateway_payment_ignores_client_amount_and_payee_override") {
        let gateway = try fixture(root), declaration = try await gateway.create(GatewaySamples.declaration(), key: "payment-source-1")
        let done = try await finish(gateway, declaration)
        var draft = GatewaySamples.payment(declarationID: done.id); draft.payload["taxAmount"] = .string("999999.00"); draft.payload["authority"] = .string("伪造收款方")
        let payment = try await gateway.create(draft, key: "payment-source-2")
        try expect(payment.payload["taxAmount"] == .string("103.50") && payment.payload["authority"] != .string("伪造收款方"), "Untrusted payment fields accepted")
    }
    await runner.run("gateway_money_strings_and_totals_are_validated") {
        let gateway = try fixture(root)
        var invoice = GatewaySamples.invoice(); invoice.payload["grossAmount"] = .number(10100)
        try await expectFailure("invalid_money") { _ = try await gateway.create(invoice, key: "invalid-money-1") }
        invoice = GatewaySamples.invoice(); invoice.payload["grossAmount"] = .string("1.00")
        try await expectFailure("invoice_total") { _ = try await gateway.create(invoice, key: "invalid-money-2") }
        var declaration = GatewaySamples.declaration(); declaration.payload["taxAmount"] = .string("200.00")
        try await expectFailure("tax_total") { _ = try await gateway.create(declaration, key: "invalid-tax-001") }
    }
    await runner.run("gateway_test_environment_rejects_real_identity") {
        let gateway = try fixture(root); var invoice = GatewaySamples.invoice(); invoice.payload["sellerTaxID"] = .string("REAL-COMPANY")
        try await expectFailure("sandbox_identity") { _ = try await gateway.create(invoice, key: "real-identity-1") }
    }
    await runner.run("gateway_live_without_adapter_cannot_submit") {
        let gateway = try fixture(root, provider: UnconfiguredLiveProvider())
        try await expectFailure("provider_not_ready") { _ = try await gateway.create(GatewaySamples.invoice(), key: "live-test-0001") }
    }
    await runner.run("gateway_cancelled_draft_cannot_be_approved") {
        let gateway = try fixture(root); let op = try await gateway.create(GatewaySamples.invoice(), key: "cancel-key-001")
        _ = try await gateway.cancel(op.id)
        try await expectFailure("cancelled") { _ = try await gateway.approve(op.id, approval: .init(payloadDigest: op.payloadDigest, acknowledged: true)) }
    }
    await runner.run("gateway_database_restart_preserves_tasks_and_deduplication") {
        let url = root.appendingPathComponent("restart.sqlite")
        let first = try FinanceGateway(database: url, provider: SandboxProvider())
        let op = try await first.create(GatewaySamples.invoice(), key: "restart-key-001")
        let second = try FinanceGateway(database: url, provider: SandboxProvider())
        let recovered = try await second.create(GatewaySamples.invoice(), key: "restart-key-001")
        try expect(op.id == recovered.id && recovered.status == .awaitingApproval, "Restart lost original operation")
        let verified = try await second.verifyAudit(); try expect(verified, "Audit verification after restart")
    }
    await runner.run("gateway_approval_replay_does_not_resubmit") {
        let provider = SandboxProvider(), gateway = try fixture(root, provider: provider)
        let op = try await gateway.create(GatewaySamples.invoice(), key: "approval-replay-1")
        _ = try await finish(gateway, op)
        let replay = try await gateway.approve(op.id, approval: .init(payloadDigest: op.payloadDigest, acknowledged: true))
        try await gateway.tick(); let count = await provider.submissionCount(op.idempotencyKey)
        try expect(replay.status == .succeeded && count == 1, "Approval replay submitted twice")
    }
    await runner.run("gateway_endpoint_rejects_credentials_redirect_paths_and_live_http") {
        _ = try GatewayEndpoint.validate("http://127.0.0.1:18765", environment: .sandbox)
        _ = try GatewayEndpoint.validate("https://finance.example", environment: .live)
        for raw in ["http://finance.example", ("https://" + "fixture" + ":" + "fixture" + "@finance.example"), "https://finance.example/a", "https://finance.example?test=fixture"] {
            do { _ = try GatewayEndpoint.validate(raw, environment: .live); throw GatewayTestFailure(message: "Accepted unsafe endpoint") } catch is FinanceError {}
        }
    }
    await runner.run("gateway_http_authentication_origin_and_environment_headers") {
        let gateway = try fixture(root), token = String(repeating: "x", count: 48)
        let server = try GatewayHTTPServer(gateway: gateway, token: token), port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        var request = URLRequest(url: base.appendingPathComponent("v1/capabilities"))
        let (_, unauthorized) = try await URLSession.shared.data(for: request)
        try expect((unauthorized as? HTTPURLResponse)?.statusCode == 401, "Missing token accepted")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let caps = try JSONDecoder().decode(GatewayCapabilities.self, from: data)
        try expect(caps.environment == .sandbox && (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Qingcai-Environment") == "sandbox", "Environment handshake")
        request.setValue("https://malicious.example", forHTTPHeaderField: "Origin")
        let (_, blocked) = try await URLSession.shared.data(for: request)
        try expect((blocked as? HTTPURLResponse)?.statusCode == 403, "Browser origin accepted")
    }
    await runner.run("gateway_http_creates_and_queries_durable_tasks") {
        let gateway = try fixture(root), token = String(repeating: "q", count: 48)
        let server = try GatewayHTTPServer(gateway: gateway, token: token), port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        var request = URLRequest(url: base.appendingPathComponent("v1/operations")); request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("http-create-key-1", forHTTPHeaderField: "Idempotency-Key"); request.httpBody = try JSONEncoder().encode(GatewaySamples.bank())
        let (data, response) = try await URLSession.shared.data(for: request)
        try expect((response as? HTTPURLResponse)?.statusCode == 200, "HTTP create failed")
        let operation = try JSONDecoder().decode(GatewayOperation.self, from: data)
        try await gateway.tick(); try await gateway.tick()
        var query = URLRequest(url: base.appendingPathComponent("v1/operations/" + operation.id)); query.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (result, _) = try await URLSession.shared.data(for: query)
        let completed = try JSONDecoder().decode(GatewayOperation.self, from: result)
        try expect(completed.status == .succeeded, "HTTP operation result not saved")
    }
    print("Gateway: \(runner.count) cases, \(runner.failures) failures")
    return (runner.count, runner.failures)
}
