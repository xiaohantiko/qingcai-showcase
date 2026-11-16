import SwiftUI
import QingcaiCore

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 215)
            VStack(spacing: 0) {
                header
                if store.demo {
                    HStack(spacing: 8) { Image(systemName: "eye"); Text("演示账本 · 所有数据仅为功能示例，修改不会写入真实账本"); Spacer(); Button("回到真实账本") { store.toggleDemo() } }
                        .font(.system(size: 11)).foregroundStyle(Palette.green).padding(.horizontal, 30).padding(.vertical, 10).background(Palette.pale)
                }
                if let notice = store.notice {
                    HStack { Image(systemName: "checkmark.circle"); Text(notice); Spacer(); Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .font(.system(size: 12)).foregroundStyle(Palette.green).padding(12).background(Palette.pale)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { page }.padding(30).frame(maxWidth: 1500).frame(maxWidth: .infinity)
                }.background(Palette.canvas)
            }
        }.tint(Palette.green).foregroundStyle(Palette.ink)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.timeZone, ChinaDate.calendar.timeZone)
            .sheet(item: $store.editingEntry) { EntryEditor(entry: $0).environmentObject(store) }
            .sheet(isPresented: $store.showClaim) { OperationEditor(kind: .claim).environmentObject(store) }
            .sheet(isPresented: $store.showPayroll) { OperationEditor(kind: .payroll).environmentObject(store) }
            .sheet(isPresented: $store.showAsset) { OperationEditor(kind: .asset).environmentObject(store) }
            .sheet(isPresented: $store.showReminder) { OperationEditor(kind: .reminder).environmentObject(store) }
            .sheet(isPresented: $store.showJournal) { JournalEditor().environmentObject(store) }
            .alert("需要处理", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23, weight: .medium)).foregroundStyle(Palette.green)
                Text("清财").font(.system(size: 23, weight: .semibold)).tracking(2)
                Text("MAC").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(Palette.muted).padding(.top, 8)
            }.padding(.top, 42).padding(.bottom, 28).padding(.horizontal, 22)
            Text("企业财务工作台").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(Palette.muted).padding(.horizontal, 24).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Route.allCases) { route in
                        Button { withAnimation(.easeInOut(duration: 0.18)) { store.route = route; store.search = "" } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: route.icon).font(.system(size: 15, weight: .regular)).frame(width: 20)
                                Text(route.rawValue).font(.system(size: 12, weight: store.route == route ? .semibold : .regular))
                                Spacer()
                                if route == .invoices && !store.missingVouchers.isEmpty { Text("\(store.missingVouchers.count)").font(.system(size: 10)).foregroundStyle(Palette.amber) }
                            }.padding(.horizontal, 14).padding(.vertical, 11)
                                .foregroundStyle(store.route == route ? Palette.green : Palette.muted)
                                .background(store.route == route ? Color.white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) { Circle().fill(Palette.green).frame(width: 5, height: 5); Text(store.demo ? "演示空间" : "本机账本 · 自动保存").font(.system(size: 10)) }
                Text(store.document.company.name.isEmpty ? "尚未设置公司" : store.document.company.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Button(store.demo ? "退出演示" : "体验演示账本") { store.toggleDemo() }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.green)
            }.foregroundStyle(Palette.muted).padding(22).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }.background(Palette.sidebar)
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.route.rawValue).font(.system(size: 23, weight: .semibold)).tracking(0.3)
                Text(store.route.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            HStack(spacing: 12) {
                Button { store.anchor = store.period.shifted(-1).start } label: { Image(systemName: "chevron.left") }.help("上一个期间")
                Text(store.period.title).font(.system(size: 11, weight: .medium)).frame(minWidth: 118)
                Button { store.anchor = store.period.shifted(1).start } label: { Image(systemName: "chevron.right") }.help("下一个期间")
            }.buttonStyle(.plain).foregroundStyle(Palette.muted).padding(.horizontal, 14).padding(.vertical, 10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
            Button { store.newEntry() } label: { Label("记一笔", systemImage: "plus") }.buttonStyle(PrimaryButton()).padding(.leading, 12)
        }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 23).background(.white)
    }
    @ViewBuilder private var page: some View {
        switch store.route {
        case .overview: OverviewView()
        case .ledger: LedgerView()
        case .invoices: InvoiceView()
        case .claims: OperationsView(kind: .claim)
        case .bank: BankView()
        case .payroll: OperationsView(kind: .payroll)
        case .assets: OperationsView(kind: .asset)
        case .journals: JournalsView()
        case .tax: TaxView()
        case .workflow: WorkflowView()
        case .automation: IntegrationView().environmentObject(store.integrations)
        case .reports: ReportsView()
        case .settings: SettingsView()
        }
    }
}
