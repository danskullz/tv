import SwiftUI

/// Borderless glyph button used inside the player's glass panel: a soft round highlight on hover,
/// a quick squish on press. White-on-glass, sized for the pointer (hit target 36 pt, 48 pt for Play).
public struct PlayerIconButtonStyle: ButtonStyle {
    public enum Size: Sendable {
        case regular, prominent
        var diameter: CGFloat { self == .prominent ? 48 : 36 }
        var font: Font { self == .prominent ? .system(size: 24, weight: .semibold) : .system(size: 16, weight: .medium) }
    }

    private let size: Size
    public init(size: Size = .regular) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(size.font)
                .labelStyle(.iconOnly)
                .foregroundStyle(.white)
                .frame(minWidth: size.diameter, minHeight: size.diameter)
                .background(
                    Circle().fill(.white.opacity(configuration.isPressed ? 0.26 : hovering ? 0.16 : 0))
                )
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .onHover { hovering = $0 }
                .motion(Tokens.Motion.fade, value: hovering)
                .motion(Tokens.Motion.snappy, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PlayerIconButtonStyle {
    public static var playerIcon: PlayerIconButtonStyle { PlayerIconButtonStyle() }
    public static var playerIconProminent: PlayerIconButtonStyle { PlayerIconButtonStyle(size: .prominent) }
}

/// Round glass button floating over video (close, dismiss).
public struct PlayerGlassCircleButton: View {
    private let systemImage: String
    private let label: LocalizedStringKey
    private let action: () -> Void

    public init(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .marqueeGlass(in: Circle(), interactive: true)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}

/// Small pill that confirms a keyboard action ("Volume 60%", "Subtitles: English").
public struct PlayerHUDPill: View {
    private let text: String
    private let systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
            Text(verbatim: text).font(.system(size: 15, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .marqueeGlass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// Monospaced diagnostics panel for the `I` overlay.
public struct PlayerStatsPanel: View {
    public struct Line: Identifiable, Sendable {
        public var id: String { label }
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    private let lines: [Line]
    public init(lines: [Line]) { self.lines = lines }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(lines) { line in
                GridRow {
                    Text(verbatim: line.label).foregroundStyle(.white.opacity(0.62))
                    Text(verbatim: line.value).foregroundStyle(.white)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .marqueeGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Playback statistics"))
    }
}
