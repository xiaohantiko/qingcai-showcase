import SwiftUI
import AppKit
import QingcaiCore

@main struct QingcaiApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).preferredColorScheme(.light)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("新增收支") { store.newEntry() }.keyboardShortcut("n") }
            CommandMenu("财务") {
                Button("导入账目 CSV") { store.importLedger() }
                Button("导出全部账目") { store.exportLedger() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("导出完整备份") { store.exportBackup() }
                Button("恢复备份") { store.restoreBackup() }
            }
        }
    }
}
