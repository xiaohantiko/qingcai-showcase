import SwiftUI
import QingcaiCore

enum Palette {
    static let ink = Color(hex: 0x223D35)
    static let green = Color(hex: 0x34735D)
    static let pale = Color(hex: 0xE7EFE7)
    static let canvas = Color(hex: 0xF6F7F3)
    static let sidebar = Color(hex: 0xEDF1E9)
    static let muted = Color(hex: 0x7C887F)
    static let line = Color(hex: 0xE5EAE2)
    static let amber = Color(hex: 0xA07135)
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}
extension View {
    func panel(_ padding: CGFloat = 24) -> some View {
        self.padding(padding).background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
    }
    func fieldLabel(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted); self }
    }
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(.white).background(Palette.green.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
struct Tag: View {
    let text: String
    var color: Color = Palette.green
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.09), in: Capsule()) }
}
struct SectionTitle: View {
    let title: String
    var caption = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer(); if !caption.isEmpty { Text(caption).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
    }
}
struct EmptyState: View {
    var icon = "tray"
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.green).padding(18).background(Palette.pale, in: RoundedRectangle(cornerRadius: 18))
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(PrimaryButton()).padding(.top, 5) }
        }.frame(maxWidth: .infinity).padding(.vertical, 44)
    }
}
struct Stat: View {
    let title: String
    let value: String
    let detail: String
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 12)).foregroundStyle(prominent ? .white.opacity(0.75) : Palette.muted)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                .foregroundStyle(prominent ? .white : Palette.ink)
            Text(detail).font(.system(size: 10)).foregroundStyle(prominent ? .white.opacity(0.65) : Palette.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(prominent ? Palette.ink : .white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(prominent ? Palette.ink : Palette.line, lineWidth: 1))
    }
}
struct Hint: View {
    let text: String
    var warning = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: warning ? "exclamationmark.circle" : "info.circle").padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).lineSpacing(5).foregroundStyle(warning ? Palette.amber : Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background((warning ? Palette.amber : Palette.green).opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}
struct FormFooter: View {
    let error: String?
    let saveTitle: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button(saveTitle, action: save).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction) }
        }.padding(22).background(.white)
    }
}
