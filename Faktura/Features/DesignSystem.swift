import SwiftUI

// Ledger: neutral chrome, tabular amounts, restrained blue for attention and selection.
enum Desk {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let accent = adaptive(NSColor(srgbRed: 0.114, green: 0.373, blue: 0.749, alpha: 1), NSColor(srgbRed: 0.45, green: 0.68, blue: 0.98, alpha: 1))
    static let primary = adaptive(NSColor(white: 0.12, alpha: 1), NSColor(white: 0.92, alpha: 1))
    static let actionText = adaptive(.white, NSColor(white: 0.10, alpha: 1))
    static let canvas = adaptive(NSColor(srgbRed: 0.949, green: 0.957, blue: 0.969, alpha: 1), NSColor(white: 0.09, alpha: 1))
    static let surface = adaptive(.white, NSColor(white: 0.12, alpha: 1))
    static let raised = adaptive(NSColor(white: 0.975, alpha: 1), NSColor(white: 0.15, alpha: 1))
    static let selection = adaptive(NSColor(white: 0.90, alpha: 1), NSColor(white: 0.22, alpha: 1))
    static let line = adaptive(NSColor(white: 0.89, alpha: 1), NSColor(white: 0.23, alpha: 1))
    static let controlLine = adaptive(NSColor(white: 0.80, alpha: 1), NSColor(white: 0.34, alpha: 1))
    static let muted = adaptive(NSColor(white: 0.38, alpha: 1), NSColor(white: 0.70, alpha: 1))
    static let warning = adaptive(NSColor(srgbRed: 0.58, green: 0.30, blue: 0.05, alpha: 1), NSColor(srgbRed: 0.94, green: 0.68, blue: 0.32, alpha: 1))
    static let radius: CGFloat = 8
}

struct DeskPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(minHeight: 36)
            .foregroundStyle(enabled ? Desk.actionText : Desk.muted)
            .background(enabled ? Desk.primary.opacity(configuration.isPressed ? 0.8 : 1) : Desk.selection, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Desk.accent : .clear, lineWidth: 2))
    }
}
struct DeskSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(enabled ? Color.primary : Desk.muted)
            .background(configuration.isPressed ? Desk.selection : Desk.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Desk.accent : Desk.controlLine, lineWidth: focused ? 2 : 1))
    }
}
struct DeskCard<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Desk.muted) }
                }
            }
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Desk.surface, in: RoundedRectangle(cornerRadius: Desk.radius))
            .overlay(RoundedRectangle(cornerRadius: Desk.radius).stroke(Desk.line))
    }
}
struct DeskField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var multiline = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Desk.muted)
            TextField(placeholder, text: $text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 2...3 : 1...1).textFieldStyle(.plain).focused($focused)
                .font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 9)
                .background(Desk.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Desk.accent : Desk.controlLine, lineWidth: focused ? 2 : 1))
                .accessibilityLabel(label)
        }
    }
}
struct DeskSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Desk.muted)
            TextField(placeholder, text: $text).textFieldStyle(.plain).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Desk.muted) }
                    .buttonStyle(.plain).help("Vymazat hledání").accessibilityLabel("Vymazat hledání")
            }
        }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 34)
            .background(Desk.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Desk.controlLine))
    }
}
struct DeskHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 24, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Desk.muted) }
        }
    }
}
struct StatusBadge: View {
    let label: String
    var color: Color = Desk.muted
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 7).padding(.vertical, 4)
            .foregroundStyle(color).background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
