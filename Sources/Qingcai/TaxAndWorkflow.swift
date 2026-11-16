import SwiftUI
import QingcaiCore

struct TaxView: View {
    @EnvironmentObject var store: AppStore
    @State private var adjustment = "0"
    @State private var prepaid = "0"
    @State private var input = "0"
    var body: some View {
        if store.filing.needsReview { Hint(text: "本期账目或公司参数已变化，先前确认的税额需要重新核对；原申报与缴款回执已保留。", warning: true) }
        HStack(spacing: 16) {
            Stat(title: "本期增值税", value: value(store.tax.vat), detail: store.document.company.taxpayer.rawValue, prominent: true)
            Stat(title: "本期附加税费", value: value(store.tax.surcharges), detail: "城建税 + 教育费附加 + 地方教育附加")
            Stat(title: "年累计所得税减已预缴", value: value(store.tax.incomeTax), detail: "截至本期 · 管理测算 · 复核后申报")
        }
        Hint(text: "政策包适用 2026–2027 年常规境内业务，核验于 \(PolicySources.checked)。不动产、差额计税、出口及特殊行业不适用此自动测算；未覆盖税种应另行登记。实际申报和缴款通过电子税务局办理。", warning: true)
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "本期增值税与附加", caption: store.period.title)
                taxRow("不含税销售额", store.tax.sales)
                taxRow("销项 / 征收税额（减免前）", store.tax.outputVAT)
                if store.document.company.taxpayer == .general { taxRow("本期已确认进项税", store.tax.inputVAT); taxRow("期末测算留抵", store.tax.carryForward) }
                if store.document.company.taxpayer == .small {
                    HStack { Text("增值税起征点"); Spacer(); Text(Money.yuan(store.period.threshold)) }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Tag(text: store.tax.belowThreshold ? "未达到起征点 · 专票对应交易仍计税" : "达到起征点 · 全额按适用征收率计算")
                }
                Divider(); taxRow("增值税", store.tax.vat); taxRow("城市维护建设税", store.tax.cityTax); taxRow("教育费附加", store.tax.education); taxRow("地方教育附加", store.tax.localEducation)
                Divider(); taxRow("本期增值税及附加合计", store.tax.vatAndSurcharges, strong: true)
                Text("含税金额 ÷（1 + 税率）= 不含税金额。收入按归属期纳入，款项是否结清不影响本期试算。2026 年起严格按“未达到”起征点判断。").font(.system(size: 10)).lineSpacing(5).foregroundStyle(Palette.muted)
            }.panel().frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 17) {
                SectionTitle(title: "所得税与期初调整")
                Text("以下金额只属于当前所选期间，请逐期核对。所得税为年累计口径，与本期增值税分别显示。").font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.muted)
                TextField("0.00", text: $adjustment).textFieldStyle(.roundedBorder).fieldLabel("年累计纳税调整（元，可为负）")
                TextField("0.00", text: $prepaid).textFieldStyle(.roundedBorder).fieldLabel("本年此前实际预缴所得税（元）")
                if store.document.company.taxpayer == .general { TextField("0.00", text: $input).textFieldStyle(.roundedBorder).fieldLabel("期初可用留抵进项税（元）") }
                Button("保存本期调整") { saveAdjustments() }.buttonStyle(.bordered)
                Divider(); taxRow("调整后年累计所得额", store.tax.ytdProfit)
                HStack { Text("所得税测算适用率"); Spacer(); Text("\(Money.raw(store.tax.effectiveIncomeRate))%") }.font(.system(size: 12))
                taxRow("年累计减已预缴", store.tax.incomeTax, strong: true)
                Link("前往电子税务局 ↗", destination: portal).font(.system(size: 12, weight: .medium))
            }.panel().frame(width: 290)
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "复核事项")
            ForEach(store.tax.warnings, id: \.self) { Hint(text: $0, warning: true) }
            Hint(text: "印花税、工资个税、社保公积金、房产税及土地使用税、消费税等未并入上方金额。请按公司实际业务在提醒中登记税种、核定金额及办理日期。")
        }
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(title: "官方政策依据", caption: "可在线打开核对")
            ForEach(PolicySources.links, id: \.0) { name, url in Link(destination: URL(string: url)!) { HStack { Text(name); Spacer(); Image(systemName: "arrow.up.right") } }.font(.system(size: 11)).padding(.vertical, 4) }
        }.panel().onAppear(perform: load).onChange(of: store.period.id) { _, _ in load() }
    }
    private var portal: URL { URL(string: store.document.company.taxPortal).flatMap { $0.scheme == "https" ? $0 : nil } ?? URL(string: "https://etax.chinatax.gov.cn/")! }
    private func value(_ amount: Decimal) -> String { store.tax.valid ? Money.yuan(amount) : "待复核" }
    private func taxRow(_ title: String, _ amount: Decimal, strong: Bool = false) -> some View {
        HStack { Text(title).foregroundStyle(strong ? Palette.ink : Palette.muted); Spacer(); Text(value(amount)).monospacedDigit().fontWeight(strong ? .semibold : .medium) }.font(.system(size: strong ? 14 : 12))
    }
    private func saveAdjustments() {
        guard let a = Money.parse(adjustment), let p = Money.parse(prepaid), let i = Money.parse(input), p >= 0, i >= 0 else { store.error = "调整金额格式有误，预缴和留抵金额不能为负。"; return }
        store.updateFiling { f in
            if f.has(.review) { throw FinanceError.invalid("本期税额已确认，请先在流程中重开“核对税额”及后续步骤。") }
            f.adjustment = a; f.prepaidIncomeTax = p; f.carriedInputVAT = i
        }
    }
    private func load() { adjustment = Money.raw(store.filing.adjustment); prepaid = Money.raw(store.filing.prepaidIncomeTax); input = Money.raw(store.filing.carriedInputVAT) }
}

struct WorkflowView: View {
    @EnvironmentObject var store: AppStore
    @State private var filingReceipt = ""
    @State private var paymentReceipt = ""
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) { Text("把本期财务办妥").font(.system(size: 21, weight: .semibold)); Text("\(store.period.title) · 已完成 \(store.filing.completed.count) / 5 步").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            Spacer(); Button("开启系统提醒") { store.requestNotifications() }.buttonStyle(.bordered)
            Button { store.showReminder = true } label: { Label("新增提醒", systemImage: "plus") }.buttonStyle(PrimaryButton())
        }
        Hint(text: "申报和缴款步骤需你在官方系统办理后，凭回执手工确认。清财不会代为提交申报或扣款；申报期限请以主管税务机关公布的当期征期为准。")
        if store.filing.needsReview { Hint(text: "数据已有变化，请重开“核对税额”并复核。原回执将记录在重开历史中。", warning: true) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(WorkflowStep.allCases.enumerated()), id: \.element) { index, step in
                let complete = store.filing.has(step)
                HStack(alignment: .top, spacing: 19) {
                    ZStack { Circle().fill(complete ? Palette.green : Palette.pale).frame(width: 38, height: 38); if complete { Image(systemName: "checkmark").foregroundStyle(.white) } else { Text("\(index + 1)").foregroundStyle(Palette.green) } }.font(.system(size: 13, weight: .medium))
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { Text(step.rawValue).font(.system(size: 15, weight: .semibold)); if complete { Tag(text: "已确认") } }
                        Text(step.detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        if complete {
                            Text("确认于 " + ChinaDate.string(store.filing.completed[step.rawValue]!, format: "yyyy-MM-dd HH:mm")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            if step == .file { Text("申报回执：" + store.filing.filingReceipt).font(.system(size: 11)) }
                            if step == .pay { Text("缴款凭证：" + store.filing.paymentReceipt).font(.system(size: 11)) }
                        } else {
                            if step == .file { TextField("真实申报回执号", text: $filingReceipt).textFieldStyle(.roundedBorder).frame(maxWidth: 340) }
                            if step == .pay { TextField("缴款凭证号，或“无应缴款”", text: $paymentReceipt).textFieldStyle(.roundedBorder).frame(maxWidth: 340) }
                        }
                    }
                    Spacer()
                    if complete { Button("重开此步及后续") { store.reopenSteps(from: step) }.font(.system(size: 11)).buttonStyle(.borderless) }
                    else { Button("确认完成") { store.completeStep(step, receipt: step == .file ? filingReceipt : paymentReceipt) }.buttonStyle(.bordered) }
                }.padding(.vertical, 22)
                if index < 4 { Divider().padding(.leading, 57) }
            }
        }.panel()
        if !store.filing.auditLog.isEmpty {
            VStack(alignment: .leading, spacing: 10) { SectionTitle(title: "流程重开历史"); ForEach(Array(store.filing.auditLog.enumerated()), id: \.offset) { _, text in Text(text).font(.system(size: 10)).foregroundStyle(Palette.muted) } }.panel()
        }
        VStack(alignment: .leading, spacing: 15) {
            SectionTitle(title: "我的财务提醒", caption: store.notificationStatus)
            if store.document.reminders.isEmpty { EmptyState(icon: "calendar", title: "把每月和每年的节点安排好", detail: "建议登记：收款跟进、工资发放、社保缴费、各税种申报、年度汇算清缴和企业年报。") }
            ForEach(store.document.reminders.sorted { $0.due < $1.due }) { reminder in
                HStack(alignment: .top, spacing: 13) {
                    Button { _ = store.update { d in if let i = d.reminders.firstIndex(where: { $0.id == reminder.id }) { d.reminders[i].done.toggle() } } } label: { Image(systemName: reminder.done ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(reminder.done ? Palette.green : Palette.muted) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 6) { Text(reminder.title).strikethrough(reminder.done).font(.system(size: 13, weight: .medium)); if !reminder.notes.isEmpty { Text(reminder.notes).font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                    Spacer(); Text(ChinaDate.string(reminder.due)).font(.system(size: 11)).foregroundStyle(reminder.due < Date() && !reminder.done ? Palette.amber : Palette.muted)
                    Button { _ = store.update { $0.reminders.removeAll { $0.id == reminder.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除提醒")
                }.padding(.vertical, 9)
            }
        }.panel()
    }
}
