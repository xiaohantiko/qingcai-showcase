import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import QingcaiCore

enum Route: String, CaseIterable, Identifiable {
    case overview = "财务概览", ledger = "收支与往来", invoices = "发票与凭证", claims = "报销审批", bank = "银行对账"
    case payroll = "工资与社保", assets = "固定资产", journals = "会计总账", tax = "税务中心", workflow = "流程与提醒", automation = "接口与自动化", reports = "报表与结账", settings = "公司与备份"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"; case .ledger: return "arrow.left.arrow.right"; case .invoices: return "doc.text"
        case .claims: return "checkmark.seal"; case .bank: return "building.columns"; case .payroll: return "person.2"
        case .assets: return "desktopcomputer"; case .journals: return "books.vertical"; case .tax: return "percent"
        case .workflow: return "checklist"; case .automation: return "point.3.connected.trianglepath.dotted"; case .reports: return "chart.bar.xaxis"; case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "看清每一笔，安心经营每一天。"
        case .ledger: return "业务归属与实际收付款，分别记录。"
        case .invoices: return "将发票、合同和付款凭证归到同一笔业务。"
        case .claims: return "从费用申请、内部审批到付款入账。"
        case .bank: return "导入银行流水，逐笔核对实际收付款。"
        case .payroll: return "登记工资、代扣个税和社保公积金。"
        case .assets: return "登记资产原值，按月计提直线折旧。"
        case .journals: return "手工录入借贷平衡的会计凭证，查看试算平衡。"
        case .tax: return "每一项税额，都有可核对的依据。"
        case .workflow: return "从核对账目到缴款确认，一步一步完成。"
        case .automation: return "从本机测试到真实接口，每一步都有办理状态和回执。"
        case .reports: return "查看管理报表，核对并完成月末结账。"
        case .settings: return "公司资料、税务参数与数据备份。"
        }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var document = FinanceDocument()
    @Published var route: Route = .overview
    @Published var anchor = Date()
    @Published var search = ""
    @Published var editingEntry: LedgerEntry?
    @Published var error: String?
    @Published var notice: String?
    @Published var demo = false
    @Published var loadFailed = false
    @Published var backupStatus = "尚未设置云盘备份"
    @Published var notificationStatus = "未开启系统提醒"
    @Published var showClaim = false
    @Published var showPayroll = false
    @Published var showAsset = false
    @Published var showJournal = false
    @Published var showReminder = false
    let repository: FinanceRepository
    let integrations = IntegrationController()
    var period: TaxPeriod { TaxPeriod(date: anchor, cycle: document.company.cycle) }
    var tax: TaxEstimate { TaxEngine.estimate(document: document, period: period) }
    var periodEntries: [LedgerEntry] { document.entries.filter { period.contains($0.date) }.sorted { $0.date > $1.date } }
    var filing: FilingRecord { document.filings.first { $0.id == period.id } ?? FilingRecord(id: period.id) }
    var cashBalance: Decimal { document.company.openingBalance + document.entries.filter { $0.affectsCash && $0.isSettled && $0.settlementDate <= Date() }.reduce(0) { $0 + ($1.kind == .income ? $1.amount : -$1.amount) } }
    var receivables: Decimal { document.entries.filter { $0.affectsCash && !$0.isSettled && $0.kind == .income }.reduce(0) { $0 + $1.amount } }
    var payables: Decimal { document.entries.filter { $0.affectsCash && !$0.isSettled && $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
    var missingVouchers: [LedgerEntry] { periodEntries.filter { $0.invoice == .none } }
    var currentMonthID: String { ChinaDate.string(anchor, format: "yyyy-MM") }
    var isClosed: Bool { document.closedMonths.contains(currentMonthID) }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QingcaiCommunity")
        repository = FinanceRepository(directory: base)
        if CommandLine.arguments.contains("--demo") { demo = true; document = .demonstration() }
        else { do { document = try repository.load() } catch { self.error = "数据载入失败：\(error.localizedDescription)\n请先备份数据目录，再从历史快照恢复。"; loadFailed = true } }
        if UserDefaults.standard.data(forKey: "backupBookmark") != nil { backupStatus = "已设置自动备份文件夹" }
        if UserDefaults.standard.bool(forKey: "notificationsEnabled") { notificationStatus = "系统提醒已开启"; scheduleNotifications() }
    }
    @discardableResult func update(_ change: (inout FinanceDocument) throws -> Void) -> Bool {
        guard !loadFailed else { error = "当前数据载入失败，已阻止覆盖。请使用恢复备份。"; return false }
        do {
            var next = document; try change(&next); next.modifiedAt = Date()
            _ = try next.validated()
            let previous = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.id, $0) })
            let future = Dictionary(uniqueKeysWithValues: next.entries.map { ($0.id, $0) })
            for id in Set(previous.keys).union(future.keys) where previous[id] != future[id] {
                let changed = [previous[id], future[id]].compactMap { $0 }
                try requireOpen(changed.flatMap { [$0.date] + ($0.affectsCash && $0.isSettled ? [$0.settlementDate] : []) })
            }
            if next.entries != document.entries || next.company != document.company {
                for i in next.filings.indices where next.filings[i].has(.review) { next.filings[i].needsReview = true }
            }
            _ = try next.validated()
            if !demo { try repository.save(next) }
            document = next
            if !demo { backupAutomatically(); scheduleNotifications() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func requireOpen(_ dates: [Date]) throws {
        if dates.contains(where: { document.closedMonths.contains(ChinaDate.string($0, format: "yyyy-MM")) }) {
            throw FinanceError.invalid("该月已结账，请到「报表与结账」重开后再修改。")
        }
    }
    func saveEntry(_ entry: LedgerEntry) -> Bool {
        update { d in
            let old = d.entries.first { $0.id == entry.id }
            try requireOpen([entry.date] + (entry.affectsCash && entry.isSettled ? [entry.settlementDate] : []) + (old.map { [$0.date] + ($0.affectsCash && $0.isSettled ? [$0.settlementDate] : []) } ?? []))
            try LedgerMutation.upsert(entry, in: &d)
        }
    }
    func deleteEntry(_ entry: LedgerEntry) {
        _ = update { d in
            try requireOpen([entry.date])
            guard !d.claims.contains(where: { $0.entryID == entry.id }), !d.payrolls.contains(where: { $0.entryID == entry.id }),
                  !d.bankLines.contains(where: { $0.entryID == entry.id }), entry.category != "资产折旧" else {
                throw FinanceError.invalid("此账目关联报销、薪酬、折旧或银行对账，不能直接删除。")
            }
            d.entries.removeAll { $0.id == entry.id }
        }
    }
    func toggleSettlement(_ entry: LedgerEntry) {
        var e = entry; e.isSettled.toggle(); e.settlementDate = Date(); _ = saveEntry(e)
    }
    func newEntry() { editingEntry = LedgerEntry(vatRate: document.company.taxpayer == .small ? 1 : 6) }
    func toggleDemo() {
        do {
            if demo { let real = try repository.load(); document = real; demo = false }
            else { document = .demonstration(); demo = true }
            anchor = Date(); search = ""; route = .overview; loadFailed = false
        } catch { self.error = error.localizedDescription }
    }
    func updateFiling(_ change: (inout FilingRecord) throws -> Void) {
        _ = update { d in
            var f = filing; try change(&f)
            d.filings.removeAll { $0.id == f.id }; d.filings.append(f)
        }
    }
    func completeStep(_ step: WorkflowStep, receipt: String = "") {
        updateFiling { f in
            let prior = Array(WorkflowStep.allCases.prefix { $0 != step })
            guard prior.allSatisfy({ f.has($0) }) else { throw FinanceError.invalid("请先完成前面的核对步骤。") }
            if step == .review && !tax.valid { throw FinanceError.invalid("请先完善税务设置，并处理税务中心的阻断提示。") }
            if step == .vouchers && !missingVouchers.isEmpty { throw FinanceError.invalid("本期仍有待补凭证的账目，请补齐发票或其他有效凭证后再确认。") }
            if (step == .file || step == .pay) && f.needsReview { throw FinanceError.invalid("账目或公司参数有变化，请先重开并复核税额。") }
            if step == .review { f.needsReview = false }
            if step == .file { guard !receipt.trimmingCharacters(in: .whitespaces).isEmpty else { throw FinanceError.invalid("请填写真实申报回执号。") }; f.filingReceipt = receipt }
            if step == .pay { guard !receipt.trimmingCharacters(in: .whitespaces).isEmpty else { throw FinanceError.invalid("请填写缴款凭证号；零申报可填“无应缴款”。") }; f.paymentReceipt = receipt }
            f.completed[step.rawValue] = Date()
        }
    }
    func reopenSteps(from step: WorkflowStep) {
        updateFiling { f in
            f.auditLog.append("\(ChinaDate.string(Date(), format: "yyyy-MM-dd HH:mm")) 重开 \(step.rawValue)；原申报回执：\(f.filingReceipt)；原缴款凭证：\(f.paymentReceipt)")
            for item in WorkflowStep.allCases.drop(while: { $0 != step }) { f.completed.removeValue(forKey: item.rawValue) }
            if !f.has(.file) { f.filingReceipt = "" }; if !f.has(.pay) { f.paymentReceipt = "" }
        }
    }
    func importLedger() {
        guard let url = openFile(types: [.commaSeparatedText, .plainText]) else { return }
        do {
            let entries = try LedgerCSV.decode(String(contentsOf: url, encoding: .utf8))
            try requireOpen(entries.map(\.date))
            let result = LedgerCSV.merge(entries, into: document.entries)
            if update({ $0.entries = result.entries }) { notice = "已导入 \(result.added) 笔，跳过 \(result.skipped) 笔重复记录。" }
        } catch { self.error = error.localizedDescription }
    }
    func exportLedger(template: Bool = false) {
        saveText(LedgerCSV.encode(template ? [] : document.entries), name: template ? "清财-账目导入模板.csv" : "清财-收支账本.csv", type: .commaSeparatedText)
    }
    func importBank() {
        guard let url = openFile(types: [.commaSeparatedText, .plainText]) else { return }
        do {
            let incoming = try BankLine.decode(String(contentsOf: url, encoding: .utf8))
            var count = 0
            if update({ d in
                var ids = Set(d.bankLines.map(\.id))
                for line in incoming where !ids.contains(line.id) { d.bankLines.append(line); ids.insert(line.id); count += 1 }
            }) { notice = "已导入 \(count) 笔银行流水，已自动跳过重复流水号。" }
        } catch { self.error = error.localizedDescription }
    }
    func reconcile(_ line: BankLine, with entry: LedgerEntry?) {
        _ = update { d in
            guard let index = d.bankLines.firstIndex(where: { $0.id == line.id }) else { return }
            try requireOpen([line.date])
            if let entry {
                guard line.matches(entry), !d.bankLines.contains(where: { $0.entryID == entry.id && $0.id != line.id }) else { throw FinanceError.invalid("日期、方向或金额不匹配，或该账目已核销。") }
            }
            d.bankLines[index].entryID = entry?.id
        }
    }
    func approveClaim(_ claim: ExpenseClaim) {
        _ = update { d in
            try requireOpen([claim.date])
            guard let i = d.claims.firstIndex(where: { $0.id == claim.id }), d.claims[i].status == .pending else { return }
            let entry = LedgerEntry(kind: .expense, title: claim.purpose, counterparty: claim.employee, amount: claim.amount,
                vatRate: 0, date: claim.date, isSettled: false, dueDate: Date(), category: "员工报销", notes: "来自报销审批，请补齐凭证并复核税额。")
            d.entries.append(entry); d.claims[i].entryID = entry.id; d.claims[i].status = .approved
        }
    }
    func payClaim(_ claim: ExpenseClaim) {
        _ = update { d in
            guard let i = d.claims.firstIndex(where: { $0.id == claim.id }), let ei = d.entries.firstIndex(where: { $0.id == claim.entryID }) else { return }
            try requireOpen([d.entries[ei].date, Date()]); d.entries[ei].isSettled = true; d.entries[ei].settlementDate = Date(); d.claims[i].status = .paid
        }
    }
    func postPayroll(_ record: PayrollRecord) {
        _ = update { d in
            try requireOpen([record.month])
            guard let i = d.payrolls.firstIndex(where: { $0.id == record.id }), d.payrolls[i].entryID == nil else { return }
            let entry = LedgerEntry(kind: .expense, title: "\(record.employee) · \(ChinaDate.string(record.month, format: "yyyy-MM")) 薪酬总成本",
                counterparty: record.employee, amount: record.cost, vatRate: 0, invoice: .other, date: record.month,
                isSettled: false, category: "人员薪酬", notes: "含税前工资及单位社保公积金。净工资、代扣个税及社保公积金全部支付后再结清。")
            d.entries.append(entry); d.payrolls[i].entryID = entry.id
        }
    }
    func postDepreciation() {
        _ = update { d in
            try requireOpen([anchor]); let monthID = currentMonthID
            for i in d.assets.indices where !d.assets[i].postedMonths.contains(monthID) {
                let amount = d.assets[i].depreciation(for: anchor)
                guard amount > 0 else { continue }
                d.entries.append(LedgerEntry(kind: .expense, title: "\(d.assets[i].name) · \(monthID) 折旧", amount: amount,
                    vatRate: 0, invoice: .other, date: anchor, isSettled: false, category: "资产折旧", affectsCash: false))
                d.assets[i].postedMonths.append(monthID)
            }
        }
    }
    func openFile(types: [UTType]) -> URL? {
        let p = NSOpenPanel(); p.allowedContentTypes = types; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }
    func saveText(_ text: String, name: String, type: UTType = .plainText) {
        let p = NSSavePanel(); p.nameFieldStringValue = name; p.allowedContentTypes = [type]
        if p.runModal() == .OK, let url = p.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8); notice = "文件已导出。" } catch { self.error = error.localizedDescription }
        }
    }
    func chooseBackupFolder() {
        guard !demo else { error = "演示模式不写入云盘，请先回到真实账本。"; return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = "选择 iCloud Drive 或其他同步文件夹。清财会在其中建立 Qingcai-Community-Backup，财务数据及凭证将交由该云盘同步。"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let target = url.appendingPathComponent("Qingcai-Community-Backup", isDirectory: true)
            guard !target.standardizedFileURL.path.hasPrefix(repository.directory.standardizedFileURL.path) else { throw FinanceError.invalid("请选择独立备份文件夹。") }
            try repository.exportSnapshot(document, to: target)
            UserDefaults.standard.set(try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "backupBookmark")
            backupStatus = "已备份 · \(ChinaDate.string(Date(), format: "MM-dd HH:mm"))"
        } catch { self.error = error.localizedDescription }
    }
    func backupAutomatically() {
        guard let data = UserDefaults.standard.data(forKey: "backupBookmark") else { return }
        do {
            var stale = false; let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { UserDefaults.standard.set(try url.bookmarkData(), forKey: "backupBookmark") }
            try repository.exportSnapshot(document, to: url); backupStatus = "已备份 · \(ChinaDate.string(Date(), format: "MM-dd HH:mm"))"
        } catch { backupStatus = "备份失败：\(error.localizedDescription)（本机数据已保存）" }
    }
    func exportBackup() {
        guard !demo else { error = "请在真实账本中导出财务备份。"; return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = "选择备份保存位置，将同时导出账本与凭证附件。"
        if p.runModal() == .OK, let url = p.url {
            do { try repository.exportSnapshot(document, to: url.appendingPathComponent("清财备份-" + ChinaDate.string(Date(), format: "yyyyMMdd-HHmmss"))); notice = "完整备份已导出，包含凭证附件。" }
            catch { self.error = error.localizedDescription }
        }
    }
    func restoreBackup() {
        guard !demo else { error = "请先回到真实账本。"; return }
        guard let url = openFile(types: [.json]) else { return }
        do {
            let recovered = try FinanceRepository.decode(Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "恢复这份财务备份？"
            alert.informativeText = "\(recovered.company.name)\n\(recovered.entries.count) 笔账目，更新于 \(ChinaDate.string(recovered.modifiedAt, format: "yyyy-MM-dd HH:mm"))。恢复会替换当前账本；当前文件会保存在本机 History 中。"
            alert.addButton(withTitle: "恢复备份"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try repository.importAttachments(for: recovered, from: url.deletingLastPathComponent())
            try repository.save(recovered); document = recovered; loadFailed = false
            backupAutomatically(); scheduleNotifications(); notice = "账本及凭证已恢复。"
        } catch { self.error = error.localizedDescription }
    }
    func requestNotifications() {
        guard !demo else { error = "演示模式不会发送系统提醒。"; return }
        Task {
            do {
                let enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
                notificationStatus = enabled ? "系统提醒已开启 · 到期日 09:00" : "未获授权，请在系统设置的通知中开启"
                if enabled { scheduleNotifications() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func scheduleNotifications() {
        guard !demo, UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        let reminders = document.reminders.filter { !$0.done }.map { ($0.id.uuidString, $0.title, $0.due) }
        let unpaid = document.entries.filter { $0.affectsCash && !$0.isSettled }.map { ($0.id.uuidString, ($0.kind == .income ? "应收款到期：" : "应付款到期：") + $0.title, $0.dueDate) }
        Task {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            let list = (reminders + unpaid).filter { item in
                (ChinaDate.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: item.2) ?? .distantPast) > Date()
            }.sorted { $0.2 < $1.2 }.prefix(60)
            for item in list {
                var parts = ChinaDate.calendar.dateComponents([.year, .month, .day], from: item.2)
                parts.hour = 9; parts.minute = 0; parts.timeZone = ChinaDate.calendar.timeZone
                guard let due = ChinaDate.calendar.date(from: parts), due > Date() else { continue }
                let content = UNMutableNotificationContent(); content.title = "清财 · 财务提醒"; content.body = item.1; content.sound = .default
                do { try await center.add(UNNotificationRequest(identifier: item.0, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))) }
                catch { notificationStatus = "提醒排期失败：\(error.localizedDescription)" }
            }
        }
    }
}
