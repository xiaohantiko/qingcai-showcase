import Foundation

public enum Money {
    public static func parse(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              abs(value) <= Decimal(1_000_000_000_000) else { return nil }
        return value
    }
    public static func rounded(_ value: Decimal) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }
    public static func text(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: value as NSDecimalNumber) ?? "0.00"
    }
    public static func raw(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    public static func yuan(_ value: Decimal) -> String { "¥" + text(value) }
}

public enum ChinaDate {
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    public static func make(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    public static func string(_ date: Date, format: String = "yyyy-MM-dd") -> String {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone; f.dateFormat = format; return f.string(from: date)
    }
    public static func parse(_ string: String) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let d = f.date(from: string), Self.string(d) == string else { return nil }; return d
    }
}

public enum EntryKind: String, Codable, CaseIterable { case income = "收入", expense = "支出" }
public enum InvoiceKind: String, Codable, CaseIterable { case none = "待补凭证", ordinary = "普通发票", special = "增值税专用发票", other = "其他有效凭证" }
public enum Taxpayer: String, Codable, CaseIterable { case small = "小规模纳税人", general = "一般纳税人" }
public enum FilingCycle: String, Codable, CaseIterable { case monthly = "按月", quarterly = "按季" }

public struct Company: Codable, Equatable {
    public var name = ""
    public var taxID = ""
    public var region = ""
    public var taxpayer: Taxpayer = .small
    public var cycle: FilingCycle = .quarterly
    public var cityRate = Decimal(7)
    public var smallProfitEligible = false
    public var sixTaxEligible = true
    public var setupConfirmed = false
    public var openingBalance = Decimal.zero
    public var taxPortal = "https://etax.chinatax.gov.cn/"
    public init() {}
}

public struct LedgerEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: EntryKind
    public var title: String
    public var counterparty: String
    /// 含税合同金额；款项状态不影响税务归属期。
    public var amount: Decimal
    public var vatRate: Decimal
    public var invoice: InvoiceKind
    /// 用户依据纳税义务发生时间确认的归属日期。
    public var date: Date
    public var isSettled: Bool
    public var settlementDate: Date
    public var dueDate: Date
    public var category: String
    public var deductible: Bool
    public var affectsCash: Bool
    public var attachment: String?
    public var notes: String
    public init(id: UUID = UUID(), kind: EntryKind = .income, title: String = "", counterparty: String = "", amount: Decimal = 0,
                vatRate: Decimal = 1, invoice: InvoiceKind = .none, date: Date = Date(), isSettled: Bool = true,
                settlementDate: Date = Date(), dueDate: Date = Date(), category: String = "服务收入", deductible: Bool = false,
                attachment: String? = nil, notes: String = "", affectsCash: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.counterparty = counterparty; self.amount = amount
        self.vatRate = vatRate; self.invoice = invoice; self.date = date; self.isSettled = isSettled
        self.settlementDate = settlementDate; self.dueDate = dueDate; self.category = category
        self.deductible = deductible; self.attachment = attachment; self.notes = notes
        self.affectsCash = affectsCash
    }
    public var net: Decimal { amount / (1 + vatRate / 100) }
    public var vat: Decimal { amount - net }
    public static let nonOperatingCategories = ["股东出资", "借款到账", "借款归还", "内部转账", "往来垫款", "税费缴纳"]
    public var isBusinessRevenue: Bool { kind == .income && !Self.nonOperatingCategories.contains(category) }
    public var isProfitExpense: Bool { kind == .expense && category != "固定资产购置" && !Self.nonOperatingCategories.contains(category) }
    public var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写事项名称。" }
        if amount <= 0 || amount > 1_000_000_000_000 { return "金额必须大于 0，且不超过 1 万亿元。" }
        if ![Decimal(0), 1, 3, 6, 9, 13].contains(vatRate) { return "不支持该税率，请选择 0%、1%、3%、6%、9% 或 13%。" }
        if deductible && (kind != .expense || invoice != .special) { return "进项抵扣需为支出且持有增值税专用发票；仍须核实用途及勾选确认。" }
        if Self.nonOperatingCategories.contains(category) && (vatRate != 0 || deductible) { return "出资、借还款、内部转账及代垫税费等资金往来请使用 0% 税率且不作进项抵扣。" }
        if let attachment, !Self.safeAttachment(attachment) { return "凭证文件名无效。" }
        return nil
    }
    public static func safeAttachment(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }
}

public struct FinanceReminder: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var due: Date
    public var notes: String
    public var done = false
    public init(title: String, due: Date, notes: String = "") { self.title = title; self.due = due; self.notes = notes }
}

public enum WorkflowStep: String, CaseIterable, Codable, Identifiable {
    case reconcile = "核对收支", vouchers = "补齐凭证", review = "核对税额", file = "完成申报", pay = "确认缴税"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .reconcile: return "核对银行流水、应收应付和税务归属日期。"
        case .vouchers: return "补齐发票及合同；检查抵扣资格和进项勾选。"
        case .review: return "复核税种、减免资格、累计利润和已预缴金额。"
        case .file: return "前往电子税务局申报，并记录申报回执号。"
        case .pay: return "在税务局完成缴款，核对扣款凭证后确认。"
        }
    }
}

public struct FilingRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var completed: [String: Date] = [:]
    public var filingReceipt = ""
    public var paymentReceipt = ""
    public var adjustment = Decimal.zero
    public var prepaidIncomeTax = Decimal.zero
    public var carriedInputVAT = Decimal.zero
    public var needsReview = false
    public var auditLog: [String] = []
    public init(id: String) { self.id = id }
    public func has(_ step: WorkflowStep) -> Bool { completed[step.rawValue] != nil }
}

public struct FinanceDocument: Codable, Equatable {
    public var schemaVersion = 1
    public var company = Company()
    public var entries: [LedgerEntry] = []
    public var reminders: [FinanceReminder] = []
    public var filings: [FilingRecord] = []
    public var claims: [ExpenseClaim] = []
    public var payrolls: [PayrollRecord] = []
    public var assets: [FixedAsset] = []
    public var bankLines: [BankLine] = []
    public var journals: [JournalVoucher] = []
    public var closedMonths: [String] = []
    public var modifiedAt = Date()
    public init() {}
    public func validated() throws -> FinanceDocument {
        guard schemaVersion == 1 else { throw FinanceError.invalid("备份版本不兼容，请升级 App 后再导入。") }
        guard Set(entries.map(\.id)).count == entries.count,
              Set(reminders.map(\.id)).count == reminders.count,
              Set(filings.map(\.id)).count == filings.count,
              Set(claims.map(\.id)).count == claims.count,
              Set(payrolls.map(\.id)).count == payrolls.count,
              Set(assets.map(\.id)).count == assets.count,
              Set(bankLines.map(\.id)).count == bankLines.count,
              Set(journals.map(\.id)).count == journals.count else { throw FinanceError.invalid("数据存在重复 ID。") }
        guard [Decimal(1), 5, 7].contains(company.cityRate), abs(company.openingBalance) <= 1_000_000_000_000 else {
            throw FinanceError.invalid("公司财务设置无效。")
        }
        for entry in entries { if let error = entry.validationError { throw FinanceError.invalid(error) } }
        for journal in journals { if let error = journal.validationError { throw FinanceError.invalid(error) } }
        for asset in assets { if let error = asset.validationError { throw FinanceError.invalid(error) } }
        for payroll in payrolls { if let error = payroll.validationError { throw FinanceError.invalid(error) } }
        guard claims.allSatisfy({ $0.amount > 0 && $0.amount <= 1_000_000_000_000 }) else { throw FinanceError.invalid("报销金额无效。") }
        let linked = bankLines.compactMap(\.entryID)
        guard Set(linked).count == linked.count else { throw FinanceError.invalid("一条账目不能重复核销多笔流水。") }
        let ids = Set(entries.map(\.id))
        guard (linked + claims.compactMap(\.entryID) + payrolls.compactMap(\.entryID)).allSatisfy(ids.contains) else { throw FinanceError.invalid("数据中的关联账目不存在。") }
        guard bankLines.allSatisfy({ $0.amount > 0 && $0.amount <= 1_000_000_000_000 }) else { throw FinanceError.invalid("银行流水金额无效。") }
        for filing in filings {
            guard filing.prepaidIncomeTax >= 0, filing.carriedInputVAT >= 0,
                  abs(filing.adjustment) <= 1_000_000_000_000,
                  filing.prepaidIncomeTax <= 1_000_000_000_000, filing.carriedInputVAT <= 1_000_000_000_000 else {
                throw FinanceError.invalid("税务调整金额无效。")
            }
        }
        return self
    }
}

public enum FinanceError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(text) = self { return text }; return nil }
}

public struct TaxPeriod: Equatable {
    public var year: Int
    /// 月制 1...12；季制 1...4。
    public var index: Int
    public var cycle: FilingCycle
    public init(date: Date, cycle: FilingCycle) {
        self.cycle = cycle; self.year = ChinaDate.calendar.component(.year, from: date)
        let m = ChinaDate.calendar.component(.month, from: date); self.index = cycle == .monthly ? m : (m - 1) / 3 + 1
    }
    public init(year: Int, index: Int, cycle: FilingCycle) { self.year = year; self.index = index; self.cycle = cycle }
    public var start: Date { ChinaDate.make(year, cycle == .monthly ? index : (index - 1) * 3 + 1) }
    public var end: Date { ChinaDate.calendar.date(byAdding: .month, value: cycle == .monthly ? 1 : 3, to: start)! }
    public var yearStart: Date { ChinaDate.make(year, 1) }
    public var id: String { "\(year)-\(cycle == .monthly ? "M" : "Q")\(index)" }
    public var title: String { cycle == .monthly ? "\(year) 年 \(index) 月" : "\(year) 年第 \(index) 季度" }
    public var threshold: Decimal { cycle == .monthly ? 100_000 : 300_000 }
    public var supportsPolicy: Bool { (2026...2027).contains(year) }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
    public func shifted(_ delta: Int) -> TaxPeriod {
        Self(date: ChinaDate.calendar.date(byAdding: .month, value: delta * (cycle == .monthly ? 1 : 3), to: start)!, cycle: cycle)
    }
}
