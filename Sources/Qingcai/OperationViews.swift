import SwiftUI
import QingcaiCore

enum OperationKind { case claim, payroll, asset, reminder
    var title: String {
        switch self { case .claim: return "新增报销申请"; case .payroll: return "登记工资"; case .asset: return "登记固定资产"; case .reminder: return "新增财务提醒" }
    }
}

struct OperationEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: OperationKind
    @State private var name = ""
    @State private var purpose = ""
    @State private var amount = ""
    @State private var second = "0"
    @State private var third = "0"
    @State private var fourth = "0"
    @State private var date = Date()
    @State private var months = "36"
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            Text(kind.title).font(.system(size: 23, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField(kind == .reminder ? "例如：确认增值税申报征期" : kind == .asset ? "例如：设计工作站" : "员工姓名", text: $name).textFieldStyle(.roundedBorder).fieldLabel(kind == .reminder ? "提醒事项 *" : kind == .asset ? "资产名称 *" : "员工姓名 *")
                    DatePicker(kind == .reminder ? "提醒日期" : kind == .payroll ? "工资所属月份" : kind == .asset ? "达到预定可使用状态日期" : "费用发生日期", selection: $date, displayedComponents: .date)
                    if kind != .reminder { TextField("0.00", text: $amount).textFieldStyle(.roundedBorder).fieldLabel(kind == .payroll ? "税前工资（元）*" : kind == .asset ? "入账原值（元）*" : "报销金额（元）*") }
                    if kind == .claim { TextField("说明用途，审批后请到账目补齐凭证", text: $purpose, axis: .vertical).textFieldStyle(.roundedBorder).fieldLabel("报销事由 *"); Hint(text: "这是本机内部审批记录。批准后生成一笔待付款费用；审批人身份校验及员工在线提单尚未接入。") }
                    if kind == .payroll {
                        TextField("0.00", text: $second).textFieldStyle(.roundedBorder).fieldLabel("个人社保公积金（元）")
                        TextField("0.00", text: $third).textFieldStyle(.roundedBorder).fieldLabel("本月应代扣个税（元）· 以自然人电子税务局核定为准")
                        TextField("0.00", text: $fourth).textFieldStyle(.roundedBorder).fieldLabel("单位社保公积金（元）")
                        if let gross = Money.parse(amount), let insurance = Money.parse(second), let tax = Money.parse(third) { Text("实发工资：" + Money.yuan(gross - insurance - tax)).font(.system(size: 17, weight: .medium)).monospacedDigit() }
                        Hint(text: "社保基数、缴费比例、专项附加扣除及累计个税需由当地系统核定。本模块登记已复核金额，不自动推定个人税务资料。")
                    }
                    if kind == .asset {
                        TextField("36", text: $months).textFieldStyle(.roundedBorder).fieldLabel("折旧月数 *")
                        TextField("0", text: $second).textFieldStyle(.roundedBorder).fieldLabel("预计净残值率（%）")
                        Hint(text: "使用直线法，自可使用月份的次月计提。请按会计政策确认年限。购置付款需另外记入「固定资产购置」分类；税会差异在纳税调整中处理。")
                    }
                    if kind == .reminder {
                        TextField("办理入口、需准备材料、已核实的法定期限等", text: $purpose, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder).fieldLabel("办理说明")
                        Hint(text: "日期由你设定；遇节假日延期请查询主管税务机关。开启系统通知后，会在到期日 09:00 提醒。")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 28).padding(.bottom, 22)
            }
            FormFooter(error: error, saveTitle: "保存", save: save)
        }.frame(width: 580, height: kind == .payroll ? 690 : 580).background(Palette.canvas)
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写名称或事项。"; return }
        do {
            if kind != .reminder { try store.requireOpen([date]) }
            let okay: Bool
            if kind == .reminder { okay = store.update { $0.reminders.append(FinanceReminder(title: name, due: date, notes: purpose)) } }
            else {
                guard let value = Money.parse(amount), value > 0 else { error = "请输入大于 0、最多两位小数的金额。"; return }
                switch kind {
                case .claim:
                    guard !purpose.isEmpty else { error = "请填写报销事由。"; return }
                    okay = store.update { $0.claims.append(ExpenseClaim(employee: name, purpose: purpose, amount: value, date: date)) }
                case .payroll:
                    guard let insurance = Money.parse(second), let tax = Money.parse(third), let employer = Money.parse(fourth) else { error = "请检查工资扣款金额。"; return }
                    let payroll = PayrollRecord(employee: name, month: date, gross: value, personalInsurance: insurance, incomeTax: tax, employerInsurance: employer)
                    if let e = payroll.validationError { error = e; return }
                    guard !store.document.payrolls.contains(where: { $0.employee == name && ChinaDate.string($0.month, format: "yyyy-MM") == ChinaDate.string(date, format: "yyyy-MM") }) else { error = "该员工当月已有工资记录，请先删除未入账记录再更正。"; return }
                    okay = store.update { $0.payrolls.append(payroll) }
                case .asset:
                    guard let life = Int(months), let residual = Money.parse(second) else { error = "请检查折旧月数与残值率。"; return }
                    let asset = FixedAsset(name: name, cost: value, residualPercent: residual, lifeMonths: life, purchaseDate: date)
                    if let e = asset.validationError { error = e; return }
                    okay = store.update { $0.assets.append(asset) }
                case .reminder: return
                }
            }
            if okay { dismiss() } else { error = store.error; store.error = nil }
        } catch { self.error = error.localizedDescription }
    }
}

struct OperationsView: View {
    @EnvironmentObject var store: AppStore
    let kind: OperationKind
    var body: some View {
        HStack {
            if kind == .asset {
                DatePicker("计提月份", selection: $store.anchor, displayedComponents: .date).fixedSize()
                Text("按所选日期所在月计提").font(.system(size: 10)).foregroundStyle(Palette.muted)
            } else { Text("\(store.period.title) · 内部财务记录").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            Spacer()
            if kind == .asset { Button("计提本月折旧") { store.postDepreciation() }.buttonStyle(.bordered) }
            Button { switch kind { case .claim: store.showClaim = true; case .payroll: store.showPayroll = true; case .asset: store.showAsset = true; case .reminder: break } } label: { Label(kind.title, systemImage: "plus") }.buttonStyle(PrimaryButton())
        }
        if kind == .claim {
            Hint(text: "批准生成应付费用，实际付款后确认支付；请在凭证模块补齐发票。审批仅供本机管理，未接入多人审批权限。")
            VStack(spacing: 0) {
                if store.document.claims.isEmpty { EmptyState(icon: "checkmark.seal", title: "让每一笔报销有据可查", detail: "记录事由和金额，内部批准后生成应付款。") }
                ForEach(store.document.claims.sorted { $0.date > $1.date }) { claim in
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 7) { Text(claim.purpose).font(.system(size: 13, weight: .medium)); Text("\(claim.employee) · \(ChinaDate.string(claim.date))").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        Spacer(); Text(Money.yuan(claim.amount)).monospacedDigit(); Tag(text: claim.status.rawValue)
                        if claim.status == .pending {
                            Button("退回") { _ = store.update { d in if let i = d.claims.firstIndex(where: { $0.id == claim.id }) { d.claims[i].status = .returned } } }
                            Button("批准并入账") { store.approveClaim(claim) }.buttonStyle(.bordered)
                        }
                        if claim.status == .approved { Button("确认已支付") { store.payClaim(claim) }.buttonStyle(.bordered) }
                        if claim.status == .returned { Button("重新提交") { _ = store.update { d in if let i = d.claims.firstIndex(where: { $0.id == claim.id }) { d.claims[i].status = .pending } } } }
                        if claim.entryID == nil { Button { _ = store.update { $0.claims.removeAll { $0.id == claim.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除尚未入账的申请") }
                    }.font(.system(size: 12)).padding(.vertical, 18); Divider()
                }
            }.panel()
        }
        if kind == .payroll {
            HStack(spacing: 16) {
                let rows = store.document.payrolls.filter { store.period.contains($0.month) }
                Stat(title: "本期税前工资", value: Money.yuan(rows.reduce(0) { $0 + $1.gross }), detail: "\(rows.count) 条员工工资记录")
                Stat(title: "应实发工资", value: Money.yuan(rows.reduce(0) { $0 + $1.net }), detail: "税前工资 − 个人社保公积金 − 个税")
                Stat(title: "单位总成本", value: Money.yuan(rows.reduce(0) { $0 + $1.cost }), detail: "税前工资 + 单位社保公积金")
            }
            Hint(text: "费用入账后，薪酬总成本会列为待付款。请在净工资、代扣个税、社保公积金均支付后再结清；分项支付需自行拆账核对。")
            HStack { Link("自然人电子税务局 ↗", destination: URL(string: "https://etax.chinatax.gov.cn/")!); Spacer() }.font(.system(size: 12))
            VStack(spacing: 0) {
                let rows = store.document.payrolls.filter { store.period.contains($0.month) }.sorted { $0.month > $1.month }
                if rows.isEmpty { EmptyState(icon: "person.2", title: "本期还没有工资记录", detail: "登记员工工资及已核实的代扣代缴金额，然后将成本记入账本。") }
                ForEach(rows) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(p.employee).fontWeight(.medium); Text(ChinaDate.string(p.month, format: "yyyy-MM")).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        Spacer(); VStack(alignment: .trailing, spacing: 6) { Text("实发 " + Money.yuan(p.net)); Text("个税 " + Money.yuan(p.incomeTax)).font(.system(size: 10)).foregroundStyle(Palette.muted) }.monospacedDigit()
                        Text("成本 " + Money.yuan(p.cost)).frame(width: 150, alignment: .trailing).monospacedDigit()
                        if p.entryID == nil { Button("记入费用") { store.postPayroll(p) }.buttonStyle(.bordered); Button { _ = store.update { $0.payrolls.removeAll { $0.id == p.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                        else { Tag(text: "已入账").frame(width: 100) }
                    }.font(.system(size: 12)).padding(.vertical, 18); Divider()
                }
            }.panel()
        }
        if kind == .asset {
            Hint(text: "这是资产台账及会计折旧。购置业务另行记为「固定资产购置」，避免一次性冲减经营利润；资产处置、减值、加速折旧及税会差异需手工处理。每月折旧可重复点击，已计提的月份不会重复入账。")
            VStack(spacing: 0) {
                if store.document.assets.isEmpty { EmptyState(icon: "desktopcomputer", title: "登记公司的长期资产", detail: "电脑、设备等资产可以按使用年限分月计提折旧。") }
                ForEach(store.document.assets) { asset in
                    HStack {
                        VStack(alignment: .leading, spacing: 7) { Text(asset.name).font(.system(size: 13, weight: .medium)); Text("\(asset.lifeMonths) 个月 · 残值率 \(Money.raw(asset.residualPercent))% · \(ChinaDate.string(asset.purchaseDate)) 启用").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        Spacer(); VStack(alignment: .trailing, spacing: 7) { Text("原值 " + Money.yuan(asset.cost)); Text("本月折旧 " + Money.yuan(asset.depreciation(for: store.anchor))).foregroundStyle(Palette.muted).font(.system(size: 10)) }.monospacedDigit()
                        Tag(text: asset.postedMonths.contains(store.currentMonthID) ? "本月已计提" : asset.depreciation(for: store.anchor) > 0 ? "本月待计提" : "本月无需计提").frame(width: 115)
                        if asset.postedMonths.isEmpty { Button { _ = store.update { $0.assets.removeAll { $0.id == asset.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除未计提资产") }
                    }.font(.system(size: 12)).padding(.vertical, 18); Divider()
                }
            }.panel()
        }
    }
}

struct BankView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack {
            SectionTitle(title: "流水核销", caption: "\(store.document.bankLines.filter { $0.entryID != nil }.count) / \(store.document.bankLines.count) 笔已核销")
            Button("下载模板") { store.saveText(BankLine.template, name: "清财-银行流水模板.csv", type: .commaSeparatedText) }
            Button("导入银行 CSV") { store.importBank() }.buttonStyle(PrimaryButton())
        }
        Hint(text: "将银行导出的流水整理为模板格式后导入。同一流水号不会重复导入；仅当方向、金额和实际结算日期一致时才允许核销。银行直连及合并、分拆匹配尚未接入。")
        VStack(spacing: 0) {
            if store.document.bankLines.isEmpty { EmptyState(icon: "building.columns", title: "先导入一份银行流水", detail: "核对后将真实收付款与业务账目关联，及时发现漏记和重复记录。") }
            ForEach(store.document.bankLines.sorted { $0.date > $1.date }) { line in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) { Text(line.summary).fontWeight(.medium); Text("\(ChinaDate.string(line.date)) · \(line.id)").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    Spacer(); Text((line.kind == .income ? "+ " : "− ") + Money.yuan(line.amount)).monospacedDigit().frame(width: 140, alignment: .trailing)
                    if line.entryID != nil { Tag(text: "已核销"); Button("取消关联") { store.reconcile(line, with: nil) } }
                    else {
                        let candidates = store.document.entries.filter { e in line.matches(e) && !store.document.bankLines.contains(where: { $0.entryID == e.id }) }
                        Menu(candidates.isEmpty ? "暂无匹配账目" : "选择账目核销") {
                            ForEach(candidates.filter { e in !store.document.bankLines.contains { $0.entryID == e.id } }) { e in Button(e.title) { store.reconcile(line, with: e) } }
                        }.frame(width: 160)
                    }
                }.font(.system(size: 12)).padding(.vertical, 18); Divider()
            }
        }.panel()
    }
}
