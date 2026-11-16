import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingcaiCore

struct LedgerView: View {
    @EnvironmentObject var store: AppStore
    @State private var filter = "全部"
    var filtered: [LedgerEntry] {
        let base = ["待收款", "待付款"].contains(filter) ? store.document.entries.sorted { $0.date > $1.date } : store.periodEntries
        return base.filter { e in
            let matches = filter == "全部" || filter == e.kind.rawValue || (filter == "待收款" && e.kind == .income && !e.isSettled && e.affectsCash) || (filter == "待付款" && e.kind == .expense && !e.isSettled && e.affectsCash)
            return matches && (store.search.isEmpty || "\(e.title) \(e.counterparty) \(e.category)".localizedCaseInsensitiveContains(store.search))
        }
    }
    var body: some View {
        HStack(spacing: 14) {
            Picker("筛选", selection: $filter) { ForEach(["全部", "收入", "支出", "待收款", "待付款"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(maxWidth: 380)
            Spacer()
            TextField("搜索事项、往来单位", text: $store.search).textFieldStyle(.roundedBorder).frame(width: 180)
            Menu("导入 / 导出") { Button("导入 CSV") { store.importLedger() }; Button("下载导入模板") { store.exportLedger(template: true) }; Divider(); Button("导出全部账目") { store.exportLedger() } }
        }
        HStack(spacing: 16) {
            Stat(title: "当前筛选收入", value: Money.yuan(filtered.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }), detail: "含税金额 · 按业务归属期")
            Stat(title: "当前筛选支出", value: Money.yuan(filtered.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }), detail: "含资产购置及非现金费用")
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "收支明细", caption: "\(filtered.count) 笔 · 待收待付显示全部期间")
            if filtered.isEmpty { EmptyState(title: "这里还没有账目", detail: "新增一笔业务，或使用 CSV 模板批量导入。", actionTitle: "新增账目", action: store.newEntry) }
            else { ForEach(filtered) { LedgerRow(entry: $0) } }
        }.panel()
        Hint(text: "首版按整笔业务结清。分期收付款请拆成多笔记录；固定资产购置请选择对应分类，折旧通过资产模块计提。")
    }
}

struct InvoiceView: View {
    @EnvironmentObject var store: AppStore
    @State private var missingOnly = false
    var body: some View {
        HStack(spacing: 16) {
            Stat(title: "本期业务凭证", value: "\(store.periodEntries.filter { $0.invoice != .none }.count) / \(store.periodEntries.count)", detail: "已登记凭证类型 / 全部业务")
            Stat(title: "待补凭证", value: "\(store.missingVouchers.count) 笔", detail: "补齐发票或其他合法有效凭证")
            Stat(title: "已归档附件", value: "\(store.periodEntries.filter { $0.attachment != nil }.count) 份", detail: "本机文件 · 随完整备份导出")
        }
        Hint(text: "这里管理凭证登记与附件归档。发票真伪、重复报销和抵扣资格仍需核对；点击官方查验入口可在线查验。")
        HStack { Toggle("只看待补凭证", isOn: $missingOnly).toggleStyle(.switch).font(.system(size: 12)); Spacer(); Link("国家税务总局发票查验 ↗", destination: URL(string: "https://inv-veri.chinatax.gov.cn/")!).font(.system(size: 12)) }
        VStack(alignment: .leading, spacing: 10) {
            let entries = store.periodEntries.filter { !missingOnly || $0.invoice == .none }
            if entries.isEmpty { EmptyState(icon: "doc.text.magnifyingglass", title: "暂无需要整理的凭证", detail: "新增业务后，在账目编辑中选择凭证类型并上传 PDF 或图片。") }
            ForEach(entries) { e in
                HStack(spacing: 14) {
                    Image(systemName: "doc.text").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.green).frame(width: 34)
                    VStack(alignment: .leading, spacing: 7) { Text(e.title).font(.system(size: 13, weight: .medium)); Text("\(e.counterparty) · \(ChinaDate.string(e.date))").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    Spacer(); Tag(text: e.invoice.rawValue, color: e.invoice == .none ? Palette.amber : Palette.green)
                    Text(Money.yuan(e.amount)).font(.system(size: 13, weight: .medium)).monospacedDigit().frame(width: 115, alignment: .trailing)
                    Button(e.attachment == nil ? "补齐凭证" : "管理附件") { store.editingEntry = e }.buttonStyle(.bordered)
                }.padding(.vertical, 14)
                Divider().overlay(Palette.line)
            }
        }.panel()
    }
}

struct EntryEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var entry: LedgerEntry
    @State private var amount = ""
    @State private var error: String?
    @State private var attachmentURL: URL?
    let categories = ["服务收入", "商品收入", "日常运营", "房租物业", "软件服务", "差旅交通", "外包采购", "人员薪酬", "员工报销", "固定资产购置", "其他"] + LedgerEntry.nonOperatingCategories
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text(store.document.entries.contains(where: { $0.id == entry.id }) ? "编辑账目" : "记一笔业务").font(.system(size: 23, weight: .semibold)); Text("金额统一填写含税金额，税额由清财拆分。").font(.system(size: 11)).foregroundStyle(Palette.muted) }; Spacer(); Image(systemName: "square.and.pencil").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.green) }.padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    Picker("业务类型", selection: $entry.kind) { ForEach(EntryKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    TextField("例如：品牌设计项目尾款", text: $entry.title).textFieldStyle(.roundedBorder).fieldLabel("事项名称 *")
                    HStack(spacing: 16) { TextField("0.00", text: $amount).textFieldStyle(.roundedBorder).fieldLabel("含税金额（元）*"); TextField("客户 / 供应商 / 员工", text: $entry.counterparty).textFieldStyle(.roundedBorder).fieldLabel("往来单位") }
                    HStack(spacing: 16) {
                        Picker("", selection: $entry.category) { ForEach(Array(Set(categories + [entry.category])).sorted(), id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(maxWidth: .infinity).fieldLabel("分类")
                        Picker("", selection: $entry.vatRate) { ForEach([0, 1, 3, 6, 9, 13], id: \.self) { Text("\($0)%").tag(Decimal($0)) } }.labelsHidden().frame(maxWidth: .infinity).fieldLabel("适用税率 / 征收率")
                    }
                    DatePicker("业务归属日期", selection: $entry.date, displayedComponents: .date)
                    Text("请按实际纳税义务发生时间确认；开票、预收款及特殊业务可能早于实际收款。").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Toggle("涉及现金收付款", isOn: $entry.affectsCash)
                    if entry.affectsCash {
                        Toggle(entry.kind == .income ? "已全部收款" : "已全部付款", isOn: $entry.isSettled)
                        if entry.isSettled { DatePicker("实际收付款日期", selection: $entry.settlementDate, displayedComponents: .date) }
                        else { DatePicker("约定收付款日期", selection: $entry.dueDate, displayedComponents: .date) }
                    }
                    Divider()
                    Picker("凭证类型", selection: $entry.invoice) { ForEach(InvoiceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if entry.kind == .expense && entry.invoice == .special && store.document.company.taxpayer == .general { Toggle("已确认可抵扣，且已完成本期进项勾选", isOn: $entry.deductible) }
                    HStack {
                        Image(systemName: "paperclip"); Text(attachmentURL?.lastPathComponent ?? (entry.attachment == nil ? "未添加附件" : "已归档一份凭证")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                        Spacer()
                        Button("选择 PDF / 图片") { attachmentURL = store.openFile(types: [.pdf, .png, .jpeg, .heic, .tiff]) }
                    }
                    TextField("补充合同号、用途或核对说明", text: $entry.notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).fieldLabel("备注")
                }.font(.system(size: 12)).padding(.horizontal, 28).padding(.bottom, 22)
            }
            FormFooter(error: error, saveTitle: "保存账目", save: save)
        }.frame(width: 610, height: 720).background(Palette.canvas).onAppear { amount = entry.amount == 0 ? "" : Money.raw(entry.amount) }
            .onChange(of: entry.kind) { _, kind in entry.category = kind == .income ? "服务收入" : "日常运营"; entry.deductible = false }
            .onChange(of: entry.category) { _, category in if LedgerEntry.nonOperatingCategories.contains(category) { entry.vatRate = 0; entry.deductible = false } }
    }
    private func save() {
        guard let value = Money.parse(amount) else { error = "请输入最多两位小数的金额。"; return }
        entry.amount = value
        if entry.kind != .expense || entry.invoice != .special || store.document.company.taxpayer != .general { entry.deductible = false }
        if !entry.affectsCash { entry.isSettled = false }
        if let problem = entry.validationError { error = problem; return }
        do {
            try store.requireOpen([entry.date])
            if let attachmentURL {
                guard !store.demo else { error = "演示模式不写入真实附件；请回到真实账本后上传。"; return }
                entry.attachment = try store.repository.addAttachment(from: attachmentURL)
            }
            if store.saveEntry(entry) { dismiss() } else { error = store.error; store.error = nil }
        } catch { self.error = error.localizedDescription }
    }
}
