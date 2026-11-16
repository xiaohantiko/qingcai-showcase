import SwiftUI
import Charts
import QingcaiCore

struct CashPoint: Identifiable { let month: Date; let kind: String; let amount: Double; var id: String { "\(month)-\(kind)" } }
struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    var cashPoints: [CashPoint] {
        let start = ChinaDate.calendar.dateInterval(of: .month, for: store.anchor)!.start
        return (-5...0).flatMap { offset -> [CashPoint] in
            let month = ChinaDate.calendar.date(byAdding: .month, value: offset, to: start)!
            let end = ChinaDate.calendar.date(byAdding: .month, value: 1, to: month)!
            return EntryKind.allCases.map { kind in
                let sum = store.document.entries.filter { $0.affectsCash && $0.isSettled && $0.kind == kind && $0.settlementDate >= month && $0.settlementDate < end }.reduce(Decimal.zero) { $0 + $1.amount }
                return CashPoint(month: month, kind: kind.rawValue, amount: NSDecimalNumber(decimal: sum).doubleValue)
            }
        }
    }
    var body: some View {
        if !store.document.company.setupConfirmed {
            HStack(spacing: 15) {
                Image(systemName: "building.2.crop.circle").font(.system(size: 28, weight: .light))
                VStack(alignment: .leading, spacing: 6) { Text("先认识你的公司").font(.system(size: 15, weight: .semibold)); Text("确认纳税身份、申报周期和优惠资格，清财才能给出适用的测算。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer(); Button("完善公司资料") { store.route = .settings }.buttonStyle(.bordered)
            }.padding(20).background(Palette.pale, in: RoundedRectangle(cornerRadius: 14))
        }
        HStack(spacing: 15) {
            Stat(title: "当前资金余额", value: Money.yuan(store.cashBalance), detail: "期初余额 + 已结算收支 · 截至今日", prominent: true)
            Stat(title: "待收款", value: Money.yuan(store.receivables), detail: "全部期间 · 尚未结清的业务")
            Stat(title: "待付款", value: Money.yuan(store.payables), detail: "全部期间 · 尚未结清的费用")
            Stat(title: "本期增值税及附加", value: store.tax.valid ? Money.yuan(store.tax.vatAndSurcharges) : "待配置", detail: "估算金额 · 所得税请到税务中心查看")
        }
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 22) {
                SectionTitle(title: "收付款趋势", caption: "最近六个月 · 含税实收实付")
                Chart(cashPoints) { p in
                    BarMark(x: .value("月份", p.month, unit: .month), y: .value("金额", p.amount), width: .ratio(0.6))
                        .foregroundStyle(by: .value("类型", p.kind)).position(by: .value("类型", p.kind)).cornerRadius(3)
                }.chartForegroundStyleScale(["收入": Palette.green, "支出": Color(hex: 0xC4CFC0)])
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.twoDigits), centered: true) } }
                    .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3])); AxisValueLabel { if let amount = value.as(Double.self) { Text(amount >= 10000 ? String(format: "%.0f万", amount / 10000) : String(format: "%.0f", amount)).font(.system(size: 9)).foregroundStyle(Palette.muted) } } } }
                    .chartLegend(position: .top, alignment: .trailing, spacing: 12).frame(height: 215)
            }.panel().frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "接下来要做", caption: "内部计划")
                let reminders = store.document.reminders.filter { !$0.done }.sorted { $0.due < $1.due }
                if reminders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) { Image(systemName: "calendar.badge.plus").font(.system(size: 28, weight: .light)); Text("把财务节点记下来").font(.system(size: 14, weight: .medium)); Text("收款跟进、工资发放、纳税申报，都可以设定提醒。").font(.system(size: 11)).foregroundStyle(Palette.muted) }.padding(.vertical, 12)
                } else {
                    ForEach(Array(reminders.prefix(3))) { reminder in
                        HStack(alignment: .top, spacing: 11) {
                            VStack(spacing: 3) { Text(ChinaDate.string(reminder.due, format: "dd")).font(.system(size: 20, weight: .medium, design: .rounded)); Text(ChinaDate.string(reminder.due, format: "M月")).font(.system(size: 9)) }.foregroundStyle(Palette.green).frame(width: 39)
                            VStack(alignment: .leading, spacing: 6) { Text(reminder.title).font(.system(size: 12, weight: .medium)); Text(reminder.notes.isEmpty ? "点击流程与提醒查看" : reminder.notes).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2) }
                        }.padding(.vertical, 5)
                    }
                }
                Spacer(minLength: 0)
                Button { store.showReminder = true } label: { Label("添加一项提醒", systemImage: "plus") }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
            }.frame(width: 245, height: 253, alignment: .topLeading).panel()
        }
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(title: "本期财务进度", caption: store.period.title)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(WorkflowStep.allCases.enumerated()), id: \.element) { index, step in
                    let done = store.filing.has(step)
                    Button { store.route = .workflow } label: {
                        HStack(spacing: 10) {
                            ZStack { Circle().fill(done ? Palette.green : Palette.pale).frame(width: 30, height: 30); if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } else { Text("\(index + 1)").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green) } }
                            VStack(alignment: .leading, spacing: 5) { Text(step.rawValue).font(.system(size: 11, weight: .medium)); Text(done ? "已确认" : "待完成").font(.system(size: 9)).foregroundStyle(Palette.muted) }
                            Spacer(minLength: 4)
                            if index < 4 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.5)).padding(.trailing, 15) }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }.panel()
        VStack(alignment: .leading, spacing: 18) {
            HStack { SectionTitle(title: "最近账目", caption: "本期 \(store.periodEntries.count) 笔"); Button("查看账本 →") { store.route = .ledger }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.green) }
            if store.periodEntries.isEmpty { EmptyState(title: "从第一笔业务开始", detail: "记录收入或费用，清财会自动整理现金流、往来和税务测算。", actionTitle: "记第一笔", action: store.newEntry) }
            else { ForEach(Array(store.periodEntries.prefix(4))) { LedgerRow(entry: $0) } }
        }.panel()
    }
}

struct LedgerRow: View {
    @EnvironmentObject var store: AppStore
    let entry: LedgerEntry
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind == .income ? "arrow.down.left" : "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(entry.kind == .income ? Palette.green : Palette.muted)
                .frame(width: 34, height: 34).background(entry.kind == .income ? Palette.pale : Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
            Button { store.editingEntry = entry } label: {
                VStack(alignment: .leading, spacing: 6) { Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(entry.counterparty.isEmpty ? entry.category : entry.counterparty).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Text(ChinaDate.string(entry.date, format: "MM-dd")).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 56)
            Text((entry.kind == .income ? "+ " : "− ") + Money.text(entry.amount)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(entry.kind == .income ? Palette.green : Palette.ink).frame(width: 120, alignment: .trailing)
            Tag(text: !entry.affectsCash ? "非现金费用" : entry.isSettled ? "已结清" : entry.kind == .income ? "待收款" : "待付款", color: entry.isSettled || !entry.affectsCash ? Palette.muted : Palette.amber).frame(width: 90)
            Menu {
                Button("编辑账目") { store.editingEntry = entry }
                if entry.affectsCash { Button(entry.isSettled ? "改为未结清" : "确认今日已全部结清") { store.toggleSettlement(entry) } }
                if let name = entry.attachment { Button("查看凭证") { NSWorkspace.shared.open(store.repository.attachments.appendingPathComponent(name)) } }
                Divider(); Button("删除账目…", role: .destructive) {
                    let alert = NSAlert(); alert.messageText = "删除“\(entry.title)”？"; alert.informativeText = "此操作将移除账目；修改前的本机历史快照仍可恢复。"
                    alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn { store.deleteEntry(entry) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 20) }.menuStyle(.borderlessButton).fixedSize().help("账目操作")
        }.padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.65)).frame(height: 1) }
    }
}
