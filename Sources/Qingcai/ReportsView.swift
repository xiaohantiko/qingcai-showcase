import SwiftUI
import QingcaiCore

struct ReportsView: View {
    @EnvironmentObject var store: AppStore
    var income: Decimal { store.periodEntries.filter(\.isBusinessRevenue).reduce(0) { $0 + $1.net } }
    var cost: Decimal { store.periodEntries.filter(\.isProfitExpense).reduce(0) { sum, e in
        sum + (store.document.company.taxpayer == .general && e.deductible && e.invoice == .special ? e.net : e.amount)
    } }
    var monthEntries: [LedgerEntry] { store.document.entries.filter { ChinaDate.string($0.date, format: "yyyy-MM") == store.currentMonthID } }
    var monthChecks: [(String, Bool)] {
        let month = store.currentMonthID
        let bank = store.document.bankLines.filter { ChinaDate.string($0.date, format: "yyyy-MM") == month }
        return [
            ("业务凭证类型已补齐", !monthEntries.contains { $0.invoice == .none }),
            ("导入的银行流水全部核销", bank.allSatisfy { $0.entryID != nil }),
            ("本月已登记工资全部入账", store.document.payrolls.filter { ChinaDate.string($0.month, format: "yyyy-MM") == month }.allSatisfy { $0.entryID != nil }),
            ("本月资产折旧已经计提", store.document.assets.allSatisfy { $0.depreciation(for: store.anchor) == 0 || $0.postedMonths.contains(month) }),
            ("已录入本月会计凭证", store.document.journals.contains { ChinaDate.string($0.date, format: "yyyy-MM") == month })
        ]
    }
    var body: some View {
        HStack(spacing: 16) {
            Stat(title: "本期不含税收入", value: Money.yuan(income), detail: "按业务归属日期 · 管理口径")
            Stat(title: "本期经营费用", value: Money.yuan(cost), detail: "含折旧及薪酬 · 不含资产购置")
            Stat(title: "本期税前管理利润", value: Money.yuan(income - cost), detail: "未计纳税调整及全部税金")
        }
        Hint(text: "以上为业务管理报表；小规模免税收益、税金及附加、折旧差异等须复核调整。下方会计报表由独立总账生成，尚未录入的会计业务不会自动纳入。")
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 17) {
                SectionTitle(title: "费用分类", caption: store.period.title)
                let expenses = store.periodEntries.filter(\.isProfitExpense)
                let groups = Dictionary(grouping: expenses, by: \.category).map { ($0.key, $0.value.reduce(Decimal.zero) { $0 + $1.amount }) }.sorted { $0.1 > $1.1 }
                if groups.isEmpty { Text("本期暂无费用").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 25) }
                ForEach(groups, id: \.0) { name, amount in
                    VStack(spacing: 9) { HStack { Text(name); Spacer(); Text(Money.yuan(amount)).monospacedDigit() }.font(.system(size: 12)); GeometryReader { g in Capsule().fill(Palette.pale).overlay(alignment: .leading) { Capsule().fill(Palette.green.opacity(0.65)).frame(width: max(3, g.size.width * NSDecimalNumber(decimal: amount / max(1, expenses.reduce(0) { $0 + $1.amount })).doubleValue)) } }.frame(height: 5) }
                }
                Button("导出本期管理报表 CSV") { export() }.buttonStyle(.bordered).padding(.top, 12)
            }.panel().frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 17) {
                SectionTitle(title: "月末结账", caption: store.currentMonthID)
                DatePicker("结账月份", selection: $store.anchor, displayedComponents: .date)
                Text("按所选日期所在月份结账。结账前请另行确认银行完整性、往来余额、存货、摊销、税金及损益结转。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
                ForEach(monthChecks, id: \.0) { name, complete in HStack { Image(systemName: complete ? "checkmark.circle.fill" : "circle").foregroundStyle(complete ? Palette.green : Palette.amber); Text(name).font(.system(size: 11)) } }
                if store.isClosed {
                    Tag(text: "本月已结账")
                    Button("重开本月…") {
                        let a = NSAlert(); a.messageText = "重开 \(store.currentMonthID)？"; a.informativeText = "该月账目及会计凭证将恢复为可编辑。请复核关联税务期间。"; a.addButton(withTitle: "重开"); a.addButton(withTitle: "取消")
                        if a.runModal() == .alertFirstButtonReturn { _ = store.update { $0.closedMonths.removeAll { $0 == store.currentMonthID } } }
                    }.buttonStyle(.bordered)
                } else {
                    Button("确认核对并结账") { _ = store.update { d in guard monthChecks.allSatisfy({ $0.1 }) else { throw FinanceError.invalid("请先完成月末检查。") }; d.closedMonths.append(store.currentMonthID) } }.buttonStyle(PrimaryButton()).disabled(!monthChecks.allSatisfy { $0.1 })
                }
            }.panel().frame(width: 320)
        }
        accountingStatement
        Hint(text: "年度事项：企业所得税汇算清缴、工商年报、年度财务报表，以及按实际业务需要的审计、税务专项报告。请在流程与提醒中登记主管部门公布的期限与材料清单。")
    }
    private var accountingStatement: some View {
        let lines = store.document.journals.filter { $0.date < store.period.end }.flatMap(\.lines)
        func balance(_ prefix: String) -> Decimal { lines.filter { $0.account.hasPrefix(prefix) }.reduce(0) { $0 + $1.debit - $1.credit } }
        let assets = balance("1"), liabilities = -balance("2"), equity = -balance("4"), unclosedProfit = -balance("6")
        return VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: "会计总账报表 · 简表", caption: "截至 \(ChinaDate.string(store.period.end.addingTimeInterval(-1)))")
            if lines.isEmpty { EmptyState(icon: "chart.bar.doc.horizontal", title: "会计总账尚无凭证", detail: "录入期初及日常会计分录后，这里会显示资产、负债、权益及未结转损益。") }
            else {
                HStack(spacing: 16) {
                    Stat(title: "资产净额", value: Money.yuan(assets), detail: "含累计折旧抵减")
                    Stat(title: "负债", value: Money.yuan(liabilities), detail: "应付、薪酬及应交税费等")
                    Stat(title: "权益及未结转损益", value: Money.yuan(equity + unclosedProfit), detail: "权益 " + Money.yuan(equity) + " · 损益 " + Money.yuan(unclosedProfit))
                }
                Tag(text: assets == liabilities + equity + unclosedProfit ? "会计恒等式平衡" : "报表不平，请复核", color: assets == liabilities + equity + unclosedProfit ? Palette.green : Palette.amber)
            }
            Text("按本 App 内置简化科目汇总，未执行报表项目重分类，不是法定格式财务报表。总账中的损益结转及资产处置需手工记账。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.panel()
    }
    private func export() {
        let text = "项目,金额或说明\r\n期间,\(store.period.title)\r\n不含税收入,\(Money.raw(income))\r\n经营费用,\(Money.raw(cost))\r\n税前管理利润,\(Money.raw(income - cost))\r\n待收款（全部期间）,\(Money.raw(store.receivables))\r\n待付款（全部期间）,\(Money.raw(store.payables))\r\n说明,管理口径报表；不代替法定财务报表及税务申报表\r\n"
        store.saveText("\u{FEFF}" + text, name: "清财-管理报表-\(store.period.id).csv", type: .commaSeparatedText)
    }
}
