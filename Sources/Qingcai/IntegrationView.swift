import SwiftUI
import QingcaiCore

struct IntegrationView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var integration: IntegrationController
    @State private var tab = "接入向导"
    @State private var liveEndpoint = UserDefaults.standard.string(forKey: "liveGatewayEndpoint") ?? ""
    @State private var token = ""
    @AppStorage("integrationOnboardingCompleted") private var completedSteps = ""
    @State private var inspected: GatewayOperation?
    private var done: Set<String> { Set(completedSteps.split(separator: ",").map(String.init)) }
    var body: some View {
        HStack {
            Picker("接口工作区", selection: $tab) { ForEach(["接入向导", "测试与接口", "任务与回执"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 380)
            Spacer()
            if integration.busy { ProgressView().controlSize(.small) }
            if let caps = integration.capabilities { Tag(text: caps.environment.label, color: caps.environment == .sandbox ? Palette.amber : Palette.green) }
        }
        if let error = integration.error {
            HStack(alignment: .top) { Hint(text: error, warning: true); Button { integration.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }
        if tab == "接入向导" { onboarding }
        if tab == "测试与接口" { connections }
        if tab == "任务与回执" { tasks }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 8) { Text("河北 · 石家庄接入准备").font(.system(size: 23, weight: .semibold)); Text("先准备账户与授权，再逐项启用自动化。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                Spacer(); Text("\(done.count) / \(OnboardingGuide.steps.count)").font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(Palette.green)
            }
            Hint(text: "你目前尚未开通银行、开票及申报接口，也没有服务器。可先使用内置本机测试环境；以下勾选仅记录你自报的办理进度，不会作为机构已授权的证明。")
            ForEach(Array(OnboardingGuide.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 17) {
                    Button {
                        var next = done
                        if next.contains(step.id) { for item in OnboardingGuide.steps.dropFirst(index) { next.remove(item.id) } }
                        else { next.insert(step.id) }
                        completedSteps = OnboardingGuide.steps.filter { next.contains($0.id) }.map(\.id).joined(separator: ",")
                    } label: { Image(systemName: done.contains(step.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 25, weight: .light)).foregroundStyle(done.contains(step.id) ? Palette.green : Palette.muted) }
                        .buttonStyle(.plain).disabled(index > 0 && !done.contains(OnboardingGuide.steps[index - 1].id)).help("记录办理进度，不授予接口权限")
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("\(index + 1). " + step.title).font(.system(size: 15, weight: .semibold)); Spacer(); if done.contains(step.id) { Tag(text: "自报已办理") } }
                        Text(step.detail).font(.system(size: 12)).lineSpacing(5)
                        Text("需要准备：" + step.materials).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                        Link("打开官方入口 / 参考资料 ↗", destination: URL(string: step.url)!).font(.system(size: 11))
                    }
                }.panel()
            }
            HStack { Text("无需把密码、U 盾 PIN、短信验证码、私钥或完整银行资料发给我。取得服务商接口文档和测试权限后，再逐项适配。").font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button("先运行本机测试") { tab = "测试与接口" }.buttonStyle(PrimaryButton()) }
        }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 19) {
                HStack { SectionTitle(title: "内置本机测试网关", caption: "独立原生进程 · 无需服务器"); Button("启动测试环境") { Task { await integration.startLocal() } }.buttonStyle(PrimaryButton()).disabled(integration.busy) }
                Text(integration.status).font(.system(size: 12)).foregroundStyle(Palette.green)
                if !integration.endpoint.isEmpty { Text(integration.endpoint).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                Hint(text: "测试使用内置虚构账户、客户和税号，不读取真实账本、不导入真实账目，不产生真实发票、申报或扣款。本机网关只监听 127.0.0.1；App 关闭时会一并停止。")
                if integration.isSandbox {
                    ForEach(GatewayOperationKind.allCases, id: \.self) { kind in
                        HStack(spacing: 16) {
                            Image(systemName: kind == .bankSync ? "building.columns" : kind == .invoiceIssue ? "doc.text" : kind == .taxDeclaration ? "percent" : "creditcard").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.green).frame(width: 30)
                            VStack(alignment: .leading, spacing: 6) { Text(kind.label).font(.system(size: 13, weight: .medium)); Text(kind == .bankSync ? "自动同步两个虚构流水，无需写操作确认" : kind == .taxPayment ? "金额从已完成申报回执带入；先创建待确认草稿" : "先生成待确认草稿，再由你核对后执行测试").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                            Spacer()
                            Button(kind == .bankSync ? "同步测试流水" : "创建测试草稿") { Task { await integration.sample(kind); tab = "任务与回执" } }.buttonStyle(.bordered).disabled(integration.busy)
                        }.padding(.vertical, 10)
                    }
                    Divider()
                    Button("测试“提交后超时”：验证只查询原单、不重复开票") { Task { await integration.sample(.invoiceIssue, timeout: true); tab = "任务与回执" } }.font(.system(size: 11)).disabled(integration.busy)
                }
            }.panel()
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "正式网关接入", caption: "尚未开通真实机构接口")
                Hint(text: "这里连接实现清财网关协议的受控服务。银行或开票平台的原生 API 地址不能直接填在这里。正式适配需拿到对应机构文档、企业授权、证书/签名配置并完成联调；当前没有内置已开通的真实适配器。", warning: true)
                TextField("https://your-gateway.example", text: $liveEndpoint).textFieldStyle(.roundedBorder).fieldLabel("已部署的正式网关地址（HTTPS）")
                SecureField("留空则读取此网关地址对应的钥匙串密钥", text: $token).textFieldStyle(.roundedBorder).fieldLabel("网关访问密钥 · 仅保存到 macOS 钥匙串")
                HStack {
                    Button("连接并检查授权能力") { Task { await integration.connectLive(endpoint: liveEndpoint, token: token); token = "" } }.buttonStyle(.bordered).disabled(integration.busy)
                    if integration.connected { Button("断开网关") { integration.stop() }.disabled(integration.busy) }
                }
                if let capabilities = integration.capabilities {
                    Text(capabilities.message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack { Text("服务提供方：\(capabilities.provider)").font(.system(size: 11)); Spacer(); Tag(text: capabilities.productionReady ? "机构能力已配置" : "真实业务不可提交", color: capabilities.productionReady ? Palette.green : Palette.amber) }
                    if capabilities.environment == .live && capabilities.productionReady {
                        Button("导入正式待办理任务 JSON…") { importLiveDraft() }.buttonStyle(.bordered).disabled(integration.busy)
                        Text("导入只生成待办理任务。涉及开票、申报和缴税时，仍须核对不可变草稿后确认；查询流水按已授权账户范围执行。").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }
                Link("查看接入资料与网关 API 协议 ↗", destination: URL(string: "https://github.com/xiaohantiko/qingcai-showcase/blob/main/gateway/openapi.json")!).font(.system(size: 11))
            }.panel()
        }
    }
    private func importLiveDraft() {
        guard integration.capabilities?.environment == .live, integration.capabilities?.productionReady == true,
              let url = store.openFile(types: [.json]) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw FinanceError.invalid("任务 JSON 不能超过 1 MB。") }
            let draft = try JSONDecoder().decode(GatewayDraft.self, from: data)
            let alert = NSAlert(); alert.messageText = "将待办理资料发送到正式网关？"
            alert.informativeText = "目的：\(draft.kind.label)\n接收地址：\(integration.endpoint)\n此文件中的公司、客户、账户或税务资料会发送至该网关。写操作先生成草稿，后续需要再次核对确认。"
            alert.addButton(withTitle: "发送并创建任务"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { Task { await integration.create(draft); tab = "任务与回执" } }
        } catch { integration.error = error.localizedDescription }
    }
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { SectionTitle(title: "接口任务", caption: integration.status); Button("刷新状态") { Task { await integration.refresh() } }.disabled(!integration.connected || integration.busy) }
            Hint(text: "任务按环境隔离。开票按订单、申报按税号及所属期、缴税按申报任务防重。超时会进入“结果待核实”，后台只查询原任务，不能直接重提。测试成功不会更新真实账本的发票或申报状态。")
            if integration.operations.isEmpty { EmptyState(icon: "point.3.connected.trianglepath.dotted", title: "还没有接口任务", detail: "先启动本机测试网关，依次创建并确认开票、申报和缴税测试草稿。", actionTitle: "前往测试环境", action: { tab = "测试与接口" }) }
            ForEach(integration.operations) { operation in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) { Text(operation.kind.label).font(.system(size: 15, weight: .semibold)); Text("\(operation.id.prefix(8)) · \(localTime(operation.createdAt))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
                        Spacer(); Tag(text: operation.environment.label, color: operation.environment == .sandbox ? Palette.amber : Palette.green)
                        Tag(text: operation.status.label, color: operation.status == .unknown || operation.status == .failed ? Palette.amber : Palette.green)
                    }
                    HStack(spacing: 18) {
                        if let buyer = operation.payload["buyerName"]?.string { Text("购方：" + buyer) }
                        if let amount = operation.payload["grossAmount"]?.string ?? operation.payload["taxAmount"]?.string { Text("金额 ¥" + amount).monospacedDigit() }
                        if let period = operation.payload["period"]?.string { Text("所属期 " + period) }
                        Spacer(); Text("提交尝试 \(operation.attempts) 次").foregroundStyle(Palette.muted)
                    }.font(.system(size: 11))
                    if let reference = operation.receipt?["receiptNo"]?.string { Text("回执：" + reference).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    if operation.status == .unknown { Hint(text: "未确认机构是否已办结，正在查询原单。此时不会自动再次开票、申报或扣款。", warning: true) }
                    HStack {
                        Button("查看草稿 / 回执") { inspected = operation }.buttonStyle(.borderless)
                        Spacer()
                        if operation.status == .awaitingApproval {
                            Button("取消草稿") { Task { await integration.cancel(operation) } }.disabled(integration.busy)
                            Button(operation.environment == .sandbox ? "核对并确认测试" : "核对并确认办理") { Task { await integration.approve(operation) } }.buttonStyle(PrimaryButton()).disabled(integration.busy)
                        }
                    }.font(.system(size: 11))
                }.panel()
            }
            if !integration.events.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "最近接口审计", caption: "日志只记录动作，不记录密钥")
                    ForEach(Array(integration.events.prefix(12))) { event in HStack(alignment: .top) { Text(localTime(event.time)).frame(width: 155, alignment: .leading); Text(event.operationID.prefix(8)).fontDesign(.monospaced).frame(width: 70); Text(event.action); Spacer() }.font(.system(size: 10)).foregroundStyle(Palette.muted) }
                }.panel()
            }
        }.sheet(item: $inspected) { operation in GatewayOperationInspector(operation: operation) }
            .task {
                while !Task.isCancelled {
                    await integration.refresh()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
    }
    private func localTime(_ timestamp: String) -> String {
        GatewayClock.date(timestamp).map { ChinaDate.string($0, format: "yyyy-MM-dd HH:mm:ss") } ?? timestamp
    }
}

struct GatewayOperationInspector: View {
    let operation: GatewayOperation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(operation.kind.label + " · " + operation.environment.label).font(.system(size: 21, weight: .semibold)); Spacer(); Button("关闭") { dismiss() } }
            Text("任务状态：\(operation.status.label) · 提交尝试 \(operation.attempts) 次").font(.system(size: 12))
            ScrollView {
                let data = (try? JSONEncoder().encode(operation)) ?? Data()
                let formatted = (try? JSONSerialization.jsonObject(with: data)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) } ?? data
                Text(String(data: formatted, encoding: .utf8) ?? "无法显示任务内容").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
            if operation.environment == .sandbox { Hint(text: "SANDBOX 开头的号码仅为本机测试回执，没有真实业务效力。") }
        }.padding(26).frame(width: 740, height: 650)
    }
}
