import SwiftUI
import QingcaiCore

struct JournalsView: View {
    @EnvironmentObject var store: AppStore
    var rows: [JournalVoucher] { store.document.journals.filter { store.period.contains($0.date) }.sorted { $0.date > $1.date } }
    var body: some View {
        HStack { SectionTitle(title: "会计凭证", caption: "\(rows.count) 张 · \(store.period.title)"); Button("新增借贷凭证") { store.showJournal = true }.buttonStyle(PrimaryButton()) }
        Hint(text: "收支账本用于业务与税务管理，会计总账独立维护。此处手工录入会计分录，避免自动套用不适合公司的会计政策；期初、收入确认、成本结转、税金计提和损益结转均需录入。正式报表前请核对两套记录。")
        HStack(spacing: 16) {
            Stat(title: "本期借方发生额", value: Money.yuan(rows.reduce(0) { $0 + $1.debit }), detail: "每张凭证保存前校验借贷平衡")
            Stat(title: "本期贷方发生额", value: Money.yuan(rows.reduce(0) { $0 + $1.credit }), detail: "总账和管理账独立，不能直接相加")
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "科目试算平衡", caption: "本期发生额 · 不含期初")
            HStack { Text("科目"); Spacer(); Text("借方").frame(width: 150, alignment: .trailing); Text("贷方").frame(width: 150, alignment: .trailing) }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            let lines = rows.flatMap(\.lines)
            ForEach(Account.chart.filter { account in lines.contains { $0.account == account.code } }) { account in
                HStack { Text(account.label); Spacer(); Text(Money.yuan(lines.filter { $0.account == account.code }.reduce(0) { $0 + $1.debit })).frame(width: 150, alignment: .trailing); Text(Money.yuan(lines.filter { $0.account == account.code }.reduce(0) { $0 + $1.credit })).frame(width: 150, alignment: .trailing) }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 7)
            }
            if rows.isEmpty { EmptyState(icon: "books.vertical", title: "建立公司的会计总账", detail: "从一张期初凭证开始，再录入日常和期末分录。每张凭证均须借贷平衡。") }
        }.panel()
        ForEach(rows) { voucher in
            VStack(alignment: .leading, spacing: 14) {
                HStack { SectionTitle(title: voucher.summary, caption: ChinaDate.string(voucher.date)); Button("删除…", role: .destructive) {
                    let a = NSAlert(); a.messageText = "删除这张会计凭证？"; a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
                    if a.runModal() == .alertFirstButtonReturn { _ = store.update { d in try store.requireOpen([voucher.date]); d.journals.removeAll { $0.id == voucher.id } } }
                }.font(.system(size: 10)).buttonStyle(.borderless) }
                ForEach(voucher.lines) { line in
                    HStack { Text(Account.chart.first { $0.code == line.account }?.label ?? line.account); Spacer(); Text(line.debit > 0 ? "借 " + Money.yuan(line.debit) : "贷 " + Money.yuan(line.credit)).monospacedDigit() }.font(.system(size: 12))
                }
            }.panel()
        }
    }
}

struct DraftJournalLine: Identifiable {
    let id = UUID()
    var account = "1002"
    var debit = ""
    var credit = ""
}
struct JournalEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var summary = ""
    @State private var lines = [DraftJournalLine(), DraftJournalLine(account: "6001")]
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            Text("新增会计凭证").font(.system(size: 23, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DatePicker("凭证日期", selection: $date, displayedComponents: .date)
                    TextField("业务摘要 / 期初余额 / 期末结转", text: $summary).textFieldStyle(.roundedBorder).fieldLabel("摘要 *")
                    HStack { Text("会计科目").frame(maxWidth: .infinity, alignment: .leading); Text("借方金额").frame(width: 115); Text("贷方金额").frame(width: 115); Spacer().frame(width: 24) }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    ForEach($lines) { $line in
                        HStack {
                            Picker("科目", selection: $line.account) { ForEach(Account.chart) { Text($0.label).tag($0.code) } }.labelsHidden().frame(maxWidth: .infinity)
                            TextField("0.00", text: $line.debit).textFieldStyle(.roundedBorder).frame(width: 115)
                            TextField("0.00", text: $line.credit).textFieldStyle(.roundedBorder).frame(width: 115)
                            Button { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).disabled(lines.count <= 2)
                        }
                    }
                    Button("添加分录") { lines.append(DraftJournalLine()) }
                    Hint(text: "每行借贷仅填一方；保存时验证金额精确到分、科目有效、借贷总额相等。")
                }.padding(.horizontal, 28)
            }
            FormFooter(error: error, saveTitle: "保存会计凭证") {
                do {
                    try store.requireOpen([date])
                    let records = try lines.map { line -> JournalLine in
                        guard let debit = Money.parse(line.debit.isEmpty ? "0" : line.debit), let credit = Money.parse(line.credit.isEmpty ? "0" : line.credit) else { throw FinanceError.invalid("借贷金额格式不正确。") }
                        return JournalLine(account: line.account, debit: debit, credit: credit)
                    }
                    let voucher = JournalVoucher(date: date, summary: summary, lines: records)
                    if let problem = voucher.validationError { error = problem; return }
                    if store.update({ $0.journals.append(voucher) }) { dismiss() } else { error = store.error; store.error = nil }
                } catch { self.error = error.localizedDescription }
            }
        }.frame(width: 720, height: 590).background(Palette.canvas)
    }
}
