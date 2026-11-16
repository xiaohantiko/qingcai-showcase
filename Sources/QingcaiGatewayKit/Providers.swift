import Foundation
import QingcaiCore

public struct GatewayProviderResult {
    public var status: GatewayOperationStatus
    public var reference: String
    public var receipt: [String: JSONValue]?
    public init(status: GatewayOperationStatus, reference: String, receipt: [String: JSONValue]? = nil) {
        self.status = status; self.reference = reference; self.receipt = receipt
    }
}

/// Implement against the contracted bank/service provider's exact signed API.
/// Submission and reconciliation are separate so a timeout never blindly repeats a write.
public protocol GatewayProvider {
    var capabilities: GatewayCapabilities { get }
    func submit(_ operation: GatewayOperation) async throws -> GatewayProviderResult
    func reconcile(_ operation: GatewayOperation) async throws -> GatewayProviderResult
}

public actor SandboxProvider: GatewayProvider {
    public nonisolated let capabilities = GatewayCapabilities(environment: .sandbox, provider: "清财本机模拟器", productionReady: false,
        operations: GatewayOperationKind.allCases, message: "模拟银行、发票、申报与缴款结果，不连接真实机构，不产生真实发票或资金划转。")
    private var submissions: [String: Int] = [:]
    public init() {}
    public func submissionCount(_ key: String) -> Int { submissions[key, default: 0] }
    public func submit(_ operation: GatewayOperation) async throws -> GatewayProviderResult {
        submissions[operation.idempotencyKey, default: 0] += 1
        if operation.payload["scenario"]?.string == "timeoutAfterSubmit" {
            throw GatewayFailure(504, "provider_timeout", "测试：机构已接收但响应超时，必须查询原单。")
        }
        return GatewayProviderResult(status: .pending, reference: "SANDBOX-" + operation.id)
    }
    public func reconcile(_ operation: GatewayOperation) async throws -> GatewayProviderResult {
        let reference = "SANDBOX-" + operation.id
        var receipt: [String: JSONValue] = ["simulated": .bool(true), "receiptNo": .string(reference), "message": .string("测试回执，不具备真实业务效力")]
        switch operation.kind {
        case .bankSync:
            receipt["accountID"] = operation.payload["accountID"]
            receipt["bankLines"] = .array([
                .object(["id": .string("SANDBOX-BANK-001"), "date": .string("2026-10-26"), "summary": .string("模拟客户收款"), "kind": .string("income"), "amount": .string("10100.00")]),
                .object(["id": .string("SANDBOX-BANK-002"), "date": .string("2026-10-26"), "summary": .string("模拟服务费"), "kind": .string("expense"), "amount": .string("200.00")])])
        case .invoiceIssue:
            receipt["invoiceNo"] = .string("SANDBOX-INVOICE-" + String(operation.id.prefix(8)))
            receipt["grossAmount"] = operation.payload["grossAmount"]; receipt["orderNo"] = operation.payload["orderNo"]
        case .taxDeclaration:
            receipt["taxAmount"] = operation.payload["taxAmount"]; receipt["taxpayerID"] = operation.payload["taxpayerID"]
            receipt["period"] = operation.payload["period"]; receipt["taxItems"] = operation.payload["taxItems"]
            receipt["authority"] = .string("模拟主管税务机关（河北石家庄）")
        case .taxPayment:
            for key in ["taxAmount", "declarationID", "taxpayerID", "period", "accountID", "authority"] { receipt[key] = operation.payload[key] }
        }
        return GatewayProviderResult(status: .succeeded, reference: reference, receipt: receipt)
    }
}

/// No undocumented endpoints or login automation are treated as production APIs.
public struct UnconfiguredLiveProvider: GatewayProvider {
    public let capabilities = GatewayCapabilities(environment: .live, provider: "尚未签约真实服务", productionReady: false, operations: [],
        message: "需提供开户银行及服务商的正式接口文档、测试权限、企业授权和验收记录，才能实现对应适配器。")
    public init() {}
    public func submit(_ operation: GatewayOperation) async throws -> GatewayProviderResult { throw GatewayFailure(503, "provider_not_configured", "正式接口尚未配置。") }
    public func reconcile(_ operation: GatewayOperation) async throws -> GatewayProviderResult { throw GatewayFailure(503, "provider_not_configured", "正式接口尚未配置。") }
}
