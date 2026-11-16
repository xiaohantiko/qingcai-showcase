import SwiftUI
import UserNotifications
import QingcaiCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var company = Company()
    @State private var opening = "0"
    @State private var error: String?
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 20) {
                SectionTitle(title: "公司资料", caption: "中国大陆 · 人民币")
                TextField("公司全称", text: $company.name).textFieldStyle(.roundedBorder).fieldLabel("公司名称 *")
                HStack(spacing: 16) { TextField("省 / 市 / 区", text: $company.region).textFieldStyle(.roundedBorder).fieldLabel("公司注册地 *"); TextField("18 位统一社会信用代码", text: $company.taxID).textFieldStyle(.roundedBorder).fieldLabel("纳税人识别号（可稍后补充）") }
                Picker("纳税人类型", selection: $company.taxpayer) { ForEach(Taxpayer.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("增值税申报周期", selection: $company.cycle) { ForEach(FilingCycle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("城市维护建设税率", selection: $company.cityRate) { Text("市区 7%").tag(Decimal(7)); Text("县城 / 镇 5%").tag(Decimal(5)); Text("其他 1%").tag(Decimal(1)) }
                TextField("0.00", text: $opening).textFieldStyle(.roundedBorder).fieldLabel("开始使用本账本前的资金余额（元）")
                Text("余额是管理口径的期初资金，不能与导入的历史收付款重复；会计总账期初余额需另用平衡分录录入。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
                Divider()
                Toggle("已核实符合小型微利企业所得税优惠", isOn: $company.smallProfitEligible)
                Hint(text: "须同时符合非限制禁止行业、年应纳税所得额不超 300 万元、从业人数不超 300 人、资产总额不超 5000 万元等条件。未确认时按 25% 试算；确认后在政策有效期及所得额范围内按 5% 有效税负测算。")
                Toggle("已核实可享受六税两费减半优惠", isOn: $company.sixTaxEligible)
                TextField("https://…", text: $company.taxPortal).textFieldStyle(.roundedBorder).fieldLabel("公司使用的电子税务局网址（HTTPS）")
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                Button("确认并保存公司设置") { save() }.buttonStyle(PrimaryButton())
            }.font(.system(size: 12)).panel().frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 20) {
                SectionTitle(title: "账本与云盘备份")
                HStack { Image(systemName: "internaldrive").font(.system(size: 22, weight: .light)); VStack(alignment: .leading, spacing: 5) { Text("本机自动保存").font(.system(size: 13, weight: .medium)); Text("每次修改前保留历史快照，最近 10 份。").font(.system(size: 10)).foregroundStyle(Palette.muted) } }
                Text(store.backupStatus).font(.system(size: 11)).foregroundStyle(Palette.green).fixedSize(horizontal: false, vertical: true)
                Button("选择 iCloud Drive / 同步文件夹") { store.chooseBackupFolder() }.buttonStyle(.bordered)
                Button("立即备份到已选文件夹") { store.backupAutomatically() }.disabled(store.demo)
                Hint(text: "备份包含公司资料、工资、账目及凭证，交由你选择的云盘同步。清财不提供账号云服务、端到端加密或多端合并；另一台 Mac 需手工恢复备份。请勿将多人同时写入当作协作同步。")
                HStack { Button("导出完整备份") { store.exportBackup() }; Button("恢复备份…") { store.restoreBackup() } }
                Button("在 Finder 查看本机数据") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.repository.directory.path) }.font(.system(size: 11))
                Divider(); SectionTitle(title: "系统通知")
                Text(store.notificationStatus).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Button("授权并开启到期提醒") { store.requestNotifications() }.buttonStyle(.bordered)
                Button("关闭系统提醒") { UserDefaults.standard.set(false, forKey: "notificationsEnabled"); UNUserNotificationCenter.current().removeAllPendingNotificationRequests(); store.notificationStatus = "已关闭系统提醒" }
                Text("到期日 09:00 提醒；过期事项在 App 内显示。最多安排最近 60 个未完成事项，启动 App 或修改账本时刷新排期。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
                Divider(); Text("清财 1.1 · 原生 Mac 财务工作台").font(.system(size: 12, weight: .medium))
                Text("本版税务规则核验于 \(PolicySources.checked)。官方接口未接入的事项由你办理并确认。会计、管理报表与税务测算分别维护，正式财务报表需复核。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.panel().frame(width: 335)
        }.onAppear {
            company = store.document.company; opening = Money.raw(company.openingBalance)
            if !company.setupConfirmed && company.region.isEmpty {
                company.region = "河北省石家庄市"
                if company.taxPortal == Company().taxPortal { company.taxPortal = "https://etax.hebei.chinatax.gov.cn/" }
            }
        }
    }
    private func save() {
        guard !company.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !company.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写公司全称和注册地。"; return }
        guard let balance = Money.parse(opening) else { error = "期初资金余额格式有误。"; return }
        guard let portal = URL(string: company.taxPortal), portal.scheme == "https", portal.host != nil else { error = "税务局网址须为有效的 HTTPS 地址。"; return }
        if !company.taxID.isEmpty && company.taxID.range(of: "^[A-Z0-9]{18}$", options: .regularExpression) == nil { error = "统一社会信用代码应为 18 位大写字母及数字。"; return }
        company.openingBalance = balance; company.setupConfirmed = true
        if store.update({ $0.company = company }) {
            error = nil; store.notice = "公司设置已保存。已确认税额的期间会标记为需复核，原回执保留。"
        }
    }
}
