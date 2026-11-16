import Foundation

public enum ClaimStatus: String, Codable, CaseIterable { case pending = "待审批", approved = "已批准", returned = "已退回", paid = "已支付" }
public struct ExpenseClaim: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var employee: String
    public var purpose: String
    public var amount: Decimal
    public var date: Date
    public var status: ClaimStatus = .pending
    public var entryID: UUID?
    public init(employee: String, purpose: String, amount: Decimal, date: Date = Date()) {
        self.employee = employee; self.purpose = purpose; self.amount = amount; self.date = date
    }
}

public struct PayrollRecord: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var employee: String
    public var month: Date
    public var gross: Decimal
    public var personalInsurance: Decimal
    public var incomeTax: Decimal
    public var employerInsurance: Decimal
    public var entryID: UUID?
    public var net: Decimal { gross - personalInsurance - incomeTax }
    public var cost: Decimal { gross + employerInsurance }
    public init(employee: String, month: Date, gross: Decimal, personalInsurance: Decimal, incomeTax: Decimal, employerInsurance: Decimal) {
        self.employee = employee; self.month = month; self.gross = gross; self.personalInsurance = personalInsurance
        self.incomeTax = incomeTax; self.employerInsurance = employerInsurance
    }
    public var validationError: String? {
        if employee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写员工姓名。" }
        if gross <= 0 || personalInsurance < 0 || incomeTax < 0 || employerInsurance < 0 || net < 0 || cost > 1_000_000_000_000 { return "工资、扣款或单位缴费金额无效。" }
        return nil
    }
}

public struct FixedAsset: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    /// 会计入账原值（含不可抵扣税额）。
    public var cost: Decimal
    public var residualPercent: Decimal
    public var lifeMonths: Int
    public var purchaseDate: Date
    public var postedMonths: [String] = []
    public init(name: String, cost: Decimal, residualPercent: Decimal, lifeMonths: Int, purchaseDate: Date) {
        self.name = name; self.cost = cost; self.residualPercent = residualPercent; self.lifeMonths = lifeMonths; self.purchaseDate = purchaseDate
    }
    public var depreciable: Decimal { Money.rounded(cost * (1 - residualPercent / 100)) }
    public var monthlyDepreciation: Decimal { Money.rounded(depreciable / Decimal(max(1, lifeMonths))) }
    public func depreciation(for month: Date) -> Decimal {
        let c = ChinaDate.calendar
        let purchased = c.dateInterval(of: .month, for: purchaseDate)!.start
        let target = c.dateInterval(of: .month, for: month)!.start
        let count = c.dateComponents([.month], from: purchased, to: target).month ?? 0
        guard count >= 1 && count <= lifeMonths else { return 0 }
        if count == lifeMonths { return max(0, depreciable - monthlyDepreciation * Decimal(lifeMonths - 1)) }
        return monthlyDepreciation
    }
    public var validationError: String? {
        if name.isEmpty || cost <= 0 || cost > 1_000_000_000_000 || residualPercent < 0 || residualPercent >= 100 || lifeMonths < 1 || lifeMonths > 1200 { return "资产名称、原值、残值率或折旧月数无效。" }
        if lifeMonths > 1 && monthlyDepreciation * Decimal(lifeMonths - 1) > depreciable { return "原值太小，无法按当前年限分摊至分，请缩短年限。" }
        return nil
    }
}

public struct BankLine: Codable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var summary: String
    public var kind: EntryKind
    public var amount: Decimal
    public var entryID: UUID?
    public init(id: String, date: Date, summary: String, kind: EntryKind, amount: Decimal) {
        self.id = id; self.date = date; self.summary = summary; self.kind = kind; self.amount = amount
    }
    public func matches(_ e: LedgerEntry) -> Bool {
        e.affectsCash && e.isSettled && e.kind == kind && e.amount == amount && ChinaDate.string(e.settlementDate) == ChinaDate.string(date)
    }
    public static let template = "日期,摘要,收入,支出,流水号\r\n2026-10-26,客户货款,10100,0,BANK-20261026-001\r\n"
    public static func decode(_ text: String) throws -> [BankLine] {
        let rows = try LedgerCSV.parse(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard rows.first == ["日期", "摘要", "收入", "支出", "流水号"] else { throw FinanceError.invalid("请使用银行对账模板的五列表头。") }
        return try rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.enumerated().map { index, row in
            guard row.count == 5, let date = ChinaDate.parse(row[0]), let income = Money.parse(row[2]),
                  let expense = Money.parse(row[3]), income >= 0, expense >= 0,
                  (income > 0) != (expense > 0), !row[4].isEmpty else { throw FinanceError.invalid("银行流水第 \(index + 2) 行格式有误；收入和支出只能有一项大于 0。") }
            return BankLine(id: row[4], date: date, summary: row[1], kind: income > 0 ? .income : .expense, amount: max(income, expense))
        }
    }
}

public struct Account: Identifiable {
    public var code: String
    public var name: String
    public var id: String { code }
    public var label: String { code + " " + name }
    public static let chart: [Account] = [
        .init(code: "1001", name: "库存现金"), .init(code: "1002", name: "银行存款"), .init(code: "1122", name: "应收账款"),
        .init(code: "1221", name: "其他应收款"), .init(code: "1405", name: "库存商品"), .init(code: "1601", name: "固定资产"),
        .init(code: "1602", name: "累计折旧"), .init(code: "2202", name: "应付账款"), .init(code: "2211", name: "应付职工薪酬"),
        .init(code: "2221", name: "应交税费"), .init(code: "2241", name: "其他应付款"), .init(code: "4001", name: "实收资本"),
        .init(code: "4103", name: "本年利润"), .init(code: "4104", name: "利润分配"), .init(code: "6001", name: "主营业务收入"),
        .init(code: "6401", name: "主营业务成本"), .init(code: "6403", name: "税金及附加"), .init(code: "6601", name: "销售费用"),
        .init(code: "6602", name: "管理费用"), .init(code: "6603", name: "财务费用"), .init(code: "6801", name: "所得税费用")
    ]
}
public struct JournalLine: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var account: String
    public var debit: Decimal
    public var credit: Decimal
    public init(account: String = "1002", debit: Decimal = 0, credit: Decimal = 0) { self.account = account; self.debit = debit; self.credit = credit }
}
public struct JournalVoucher: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var date: Date
    public var summary: String
    public var lines: [JournalLine]
    public init(date: Date, summary: String, lines: [JournalLine]) { self.date = date; self.summary = summary; self.lines = lines }
    public var debit: Decimal { lines.reduce(0) { $0 + $1.debit } }
    public var credit: Decimal { lines.reduce(0) { $0 + $1.credit } }
    public var validationError: String? {
        if summary.isEmpty || lines.count < 2 { return "请填写摘要和至少两条分录。" }
        if lines.contains(where: { !Account.chart.map(\.code).contains($0.account) || $0.debit < 0 || $0.credit < 0 || ($0.debit > 0) == ($0.credit > 0) || Money.rounded($0.debit) != $0.debit || Money.rounded($0.credit) != $0.credit }) { return "每行请选择科目，借贷只能填写一方，金额精确到分。" }
        if debit != credit || debit <= 0 || debit > 1_000_000_000_000 { return "借贷金额必须相等且大于 0。" }
        return nil
    }
}

public enum LedgerMutation {
    /// 业务记录仍保留其来源约束；修改结清状态时同步报销状态。
    public static func upsert(_ entry: LedgerEntry, in document: inout FinanceDocument) throws {
        if let error = entry.validationError { throw FinanceError.invalid(error) }
        if let claim = document.claims.first(where: { $0.entryID == entry.id }) {
            guard entry.kind == .expense, entry.amount == claim.amount, entry.affectsCash else {
                throw FinanceError.invalid("报销关联账目必须保留原申请金额、支出方向及现金属性。")
            }
        }
        if let payroll = document.payrolls.first(where: { $0.entryID == entry.id }) {
            guard entry.kind == .expense, entry.amount == payroll.cost, entry.affectsCash else {
                throw FinanceError.invalid("薪酬关联账目必须保留单位总成本、支出方向及现金属性。")
            }
        }
        if let index = document.entries.firstIndex(where: { $0.id == entry.id }) {
            if document.bankLines.contains(where: { $0.entryID == entry.id }), document.entries[index] != entry {
                throw FinanceError.invalid("此账目已与银行流水核销，请先取消关联。")
            }
            document.entries[index] = entry
        } else { document.entries.append(entry) }
        if let index = document.claims.firstIndex(where: { $0.entryID == entry.id }) {
            document.claims[index].status = entry.isSettled ? .paid : .approved
        }
    }
}
