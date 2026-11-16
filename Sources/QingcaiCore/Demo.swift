import Foundation

public extension FinanceDocument {
    static func demonstration(now: Date = Date()) -> FinanceDocument {
        var d = FinanceDocument()
        d.company.name = "示例公司 · 演示"
        d.company.region = "示例地区"; d.company.taxpayer = .small; d.company.setupConfirmed = true
        d.company.smallProfitEligible = true; d.company.openingBalance = 86_420
        let currentMonth = ChinaDate.calendar.component(.month, from: now)
        let year = ChinaDate.calendar.component(.year, from: now)
        let examples: [(EntryKind, String, String, Decimal, Bool, InvoiceKind, String, Int)] = [
            (.income, "品牌视觉设计 · 二期", "演示客户1", 48_480, true, .ordinary, "服务收入", 3),
            (.expense, "十月办公室租金", "演示供应商1", 8_600, true, .ordinary, "房租物业", 5),
            (.income, "年度设计顾问", "演示客户2", 32_320, true, .special, "服务收入", 9),
            (.expense, "团队差旅与交通", "演示供应商2", 2_346, true, .none, "差旅交通", 12),
            (.income, "产品包装设计 · 尾款", "演示客户3", 18_685, false, .none, "服务收入", 18),
            (.expense, "软件服务订阅", "演示供应商3", 1_280, true, .ordinary, "软件服务", 20),
            (.expense, "项目外包制作", "演示供应商4", 6_780, false, .special, "外包采购", 22)
        ]
        for e in examples {
            let date = ChinaDate.make(year, currentMonth, e.7)
            d.entries.append(LedgerEntry(kind: e.0, title: e.1, counterparty: e.2, amount: e.3,
                vatRate: e.0 == .income ? 1 : 6, invoice: e.5, date: date, isSettled: e.4,
                settlementDate: date, dueDate: ChinaDate.calendar.date(byAdding: .day, value: 10, to: date)!, category: e.6))
        }
        for offset in 1...5 {
            let monthDate = ChinaDate.calendar.date(byAdding: .month, value: -offset, to: ChinaDate.make(year, currentMonth))!
            d.entries.append(LedgerEntry(title: "设计服务项目", counterparty: "演示客户", amount: Decimal(35_000 + offset * 7_320),
                invoice: .ordinary, date: monthDate, settlementDate: monthDate))
            d.entries.append(LedgerEntry(kind: .expense, title: "项目运营费用", counterparty: "演示供应商", amount: Decimal(17_000 + offset * 1_270),
                vatRate: 6, invoice: .ordinary, date: monthDate, settlementDate: monthDate, category: "日常运营"))
        }
        d.reminders = [FinanceReminder(title: "跟进产品包装设计尾款", due: ChinaDate.calendar.date(byAdding: .day, value: 2, to: now)!, notes: "核实客户付款时间，到账后更新结算状态。"),
            FinanceReminder(title: "核对本月发票和银行流水", due: ChinaDate.calendar.date(byAdding: .day, value: 4, to: now)!, notes: "内部工作计划；法定申报期限请查询当地征期。")]
        return d
    }
}
