import Foundation

public enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}
public enum GatewayEnvironment: String, Codable, CaseIterable { case sandbox, live
    public var label: String { self == .sandbox ? "测试环境" : "正式环境" }
}
public enum GatewayOperationKind: String, Codable, CaseIterable {
    case bankSync, invoiceIssue, taxDeclaration, taxPayment
    public var label: String {
        switch self { case .bankSync: return "拉取银行流水"; case .invoiceIssue: return "开具数电发票"; case .taxDeclaration: return "提交税务申报"; case .taxPayment: return "缴纳已申报税款" }
    }
    public var requiresApproval: Bool { self != .bankSync }
}
public enum GatewayOperationStatus: String, Codable {
    case awaitingApproval, queued, submitting, pending, succeeded, failed, unknown, cancelled
    public var label: String {
        switch self {
        case .awaitingApproval: return "待确认"; case .queued: return "已排队"; case .submitting: return "提交中"; case .pending: return "处理中"
        case .succeeded: return "已完成"; case .failed: return "已失败"; case .unknown: return "结果待核实"; case .cancelled: return "已取消"
        }
    }
    public var isInFlight: Bool { [.queued, .submitting, .pending, .unknown].contains(self) }
}
public struct GatewayDraft: Codable, Equatable {
    public var kind: GatewayOperationKind
    public var payload: [String: JSONValue]
    public init(kind: GatewayOperationKind, payload: [String: JSONValue]) { self.kind = kind; self.payload = payload }
}
public struct GatewayOperation: Codable, Identifiable, Equatable {
    public var id: String
    public var environment: GatewayEnvironment
    public var kind: GatewayOperationKind
    public var status: GatewayOperationStatus
    public var idempotencyKey: String
    public var payload: [String: JSONValue]
    public var payloadDigest: String
    public var createdAt: String
    public var updatedAt: String
    public var approvalExpiresAt: String?
    public var providerReference: String?
    public var receipt: [String: JSONValue]?
    public var errorCode: String?
    public var attempts: Int
    public init(id: String, environment: GatewayEnvironment, draft: GatewayDraft, key: String, digest: String, now: String, expires: String?) {
        self.id = id; self.environment = environment; self.kind = draft.kind
        self.status = draft.kind.requiresApproval ? .awaitingApproval : .queued
        self.idempotencyKey = key; self.payload = draft.payload; self.payloadDigest = digest
        self.createdAt = now; self.updatedAt = now; self.approvalExpiresAt = expires; self.attempts = 0
    }
}
public struct GatewayCapabilities: Codable {
    public var apiVersion: Int
    public var environment: GatewayEnvironment
    public var provider: String
    public var productionReady: Bool
    public var availableOperations: [GatewayOperationKind]
    public var message: String
    public init(environment: GatewayEnvironment, provider: String, productionReady: Bool, operations: [GatewayOperationKind], message: String) {
        apiVersion = 1; self.environment = environment; self.provider = provider; self.productionReady = productionReady
        availableOperations = operations; self.message = message
    }
}
public struct GatewayAuditEvent: Codable, Identifiable {
    public var id: Int
    public var operationID: String
    public var time: String
    public var action: String
    public var digest: String
    public init(id: Int, operationID: String, time: String, action: String, digest: String) {
        self.id = id; self.operationID = operationID; self.time = time; self.action = action; self.digest = digest
    }
}
public struct GatewayOperationList: Codable { public var operations: [GatewayOperation] }
public struct GatewayAuditList: Codable { public var events: [GatewayAuditEvent] }
public struct GatewayApproval: Codable {
    public var payloadDigest: String
    public var acknowledged: Bool
    public init(payloadDigest: String, acknowledged: Bool) { self.payloadDigest = payloadDigest; self.acknowledged = acknowledged }
}
public struct GatewayAPIError: Codable { public var code: String; public var message: String }
public enum GatewayClock {
    public static func string(_ date: Date = Date()) -> String { ISO8601DateFormatter().string(from: date) }
    public static func date(_ string: String) -> Date? { ISO8601DateFormatter().date(from: string) }
}

/// 内置样例只用于测试网关，不读取或发送真实账本。
public enum GatewaySamples {
    public static func bank() -> GatewayDraft { .init(kind: .bankSync, payload: ["accountID": .string("SANDBOX-ACCOUNT"), "from": .string("2026-10-01"), "to": .string("2026-10-31")]) }
    public static func invoice(scenario: String = "normal") -> GatewayDraft {
        .init(kind: .invoiceIssue, payload: ["orderNo": .string("SANDBOX-ORDER-001"), "sellerTaxID": .string("SANDBOX-SELLER"), "buyerName": .string("测试购方（无真实发票）"), "buyerTaxID": .string("SANDBOX-BUYER"), "invoiceType": .string("ordinary"), "grossAmount": .string("10100.00"), "scenario": .string(scenario),
            "lines": .array([.object(["itemName": .string("测试技术服务"), "taxCode": .string("SANDBOX-TAX-CODE"), "grossAmount": .string("10100.00"), "vatRate": .string("1")])])])
    }
    public static func declaration() -> GatewayDraft {
        .init(kind: .taxDeclaration, payload: ["taxpayerID": .string("SANDBOX-SELLER"), "period": .string("2026-Q4"), "region": .string("河北省石家庄市"), "sourceDigest": .string("SANDBOX-REVIEWED-SNAPSHOT"), "taxAmount": .string("103.50"), "taxItems": .array([.object(["type": .string("VAT"), "amount": .string("100.00")]), .object(["type": .string("SURCHARGE"), "amount": .string("3.50")])])])
    }
    public static func payment(declarationID: String) -> GatewayDraft {
        .init(kind: .taxPayment, payload: ["declarationID": .string(declarationID), "accountID": .string("SANDBOX-ACCOUNT"), "agreementID": .string("SANDBOX-THREE-PARTY-AGREEMENT")])
    }
}

public enum OnboardingGuide {
    public struct Step: Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let materials: String
        public let url: String
    }
    public static let steps: [Step] = [
        .init(id: "company", title: "确认公司证照与税号", detail: "公司已注册则核对登记信息；尚未完成注册则先办理营业执照、印章等。清财不会替你提交注册。", materials: "公司全称、统一社会信用代码、注册地址、法定代表人及经营范围。证件在官方渠道提交，不发进聊天。", url: "https://www.chinatax.gov.cn/"),
        .init(id: "taxIdentity", title: "登录河北电子税务局，完成办税身份与新办事项", detail: "法人或已授权办税员确认企业信息、税种、申报周期及数电票开票相关事项。实际事项以主管税务机关展示为准。", materials: "企业登记资料、法人或办税员实名认证；确认主管税务机关、应申报税种和申报周期。", url: "https://etax.hebei.chinatax.gov.cn/"),
        .init(id: "bank", title: "开立对公账户并申请流水查询接口", detail: "先向开户行确认银企直联或开放银行产品、价格、Mac/服务器要求，优先申请余额与流水只读权限。开通网银不等于开通接口。", materials: "开户资料按银行要求准备；技术接入另需应用号、接口文档、测试账号、授权账户范围及证书要求。", url: "https://openapi.cmbchina.com/"),
        .init(id: "agreement", title: "办理存款账户报告及税库银三方协议", detail: "在电子税务局登记银行账户，按银行支持情况签订并验证划缴协议。三方协议只解决税款划缴授权，不代替流水接口授权。", materials: "对公账户信息、开户行及行号、协议编号与验证结果。签约和授权由你在官方渠道完成。", url: "https://etax.hebei.chinatax.gov.cn/"),
        .init(id: "invoice", title: "开通数电发票及开票服务商 API", detail: "先核实开票资格和额度，再比较诺诺、百望或其他授权服务商。开通前要求确认河北支持范围、数电票类型及接口产品。", materials: "卖方税号、票种与额度、商品税收分类编码、开票人权限；服务商提供应用号、沙箱、签名文档与查询回执接口。", url: "https://www.nuonuo.com/"),
        .init(id: "filing", title: "确认河北申报与缴税接口服务", detail: "向服务商核实支持的省份、税种、表单、实名认证及委托授权方式。开票 API 不等于申报 API；不把其他省的乐企条件套用到河北。", materials: "需授权的税种、申报模板、测试数据、正式接口文档、委托关系及回执验收要求。", url: "https://etax.hebei.chinatax.gov.cn/"),
        .init(id: "verification", title: "完成真实接口联调，再启用正式自动化", detail: "逐项验证账户范围、重复请求、超时核查、开票与申报回执、缴款凭证。测试数据与真实账本始终分开。", materials: "已选银行及服务商、测试授权、接口文档版本、生产端点与验收结果；密钥通过钥匙串或受控网关配置。", url: "https://www.chinatax.gov.cn/")
    ]
}
