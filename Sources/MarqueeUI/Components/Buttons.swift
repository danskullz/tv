import SwiftUI

private struct FocusRing: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content.overlay(
            Capsule().strokeBorder(Color.accentColor, lineWidth: 3).padding(-4).opacity(isFocused ? 1 : 0)
        )
    }
}

private struct PlayButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let label = configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .labelStyle(.titleAndIcon)
            // One line, always. "Resume S0 · E1" was wrapping to two lines and making this button
            // taller than its neighbours. `fixedSize(horizontal:)` stops the row squeezing the label
            // into a wrap; the hero row is allowed to lay out wide rather than fold the text.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 26)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        Group {
            if #available(macOS 26, *), !reduceTransparency {
                label.marqueeGlass(in: Capsule(), tint: .accentColor, interactive: true)
            } else {
                label
                    .background(Color.accentColor.gradient, in: Capsule())
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
            }
        }
        .modifier(FocusRing())
        .opacity(isEnabled ? 1 : 0.5)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .motion(Tokens.Motion.snappy, value: configuration.isPressed)
    }
}

/// The hero control: a prominent accent capsule (tinted Liquid Glass on macOS 26). One per screen.
public struct PlayButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        PlayButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.headline.weight(.medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .marqueeGlass(in: Capsule(), interactive: true)
            .modifier(FocusRing())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .motion(Tokens.Motion.snappy, value: configuration.isPressed)
    }
}

/// Glass capsule for actions next to Play (Download, Monitor, Play from episode 1).
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == PlayButtonStyle {
    public static var marqueePlay: PlayButtonStyle { PlayButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    public static var marqueeSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

private struct AccentIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .background(Color.accentColor.gradient, in: Circle())
            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
            .modifier(FocusRing())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .motion(Tokens.Motion.snappy, value: configuration.isPressed)
    }
}

/// Accent-coloured circular control that carries an icon only. Used where an action is important
/// but must not compete with the hero Play button for a row's width (add to library, quick toggles).
/// The caller is responsible for an accessibility label — there is no visible text to speak.
public struct AccentIconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        AccentIconButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == AccentIconButtonStyle {
    public static var marqueeAccentIcon: AccentIconButtonStyle { AccentIconButtonStyle() }
}

/// Ready-made Play / Resume button. `context` is read by VoiceOver ("Play, Harbor Lights season 2").
public struct PlayButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let context: String?
    private let action: () -> Void

    public init(
        _ title: LocalizedStringKey = "Play", systemImage: String = "play.fill",
        context: String? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.context = context
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.marqueePlay)
        .accessibilityHint(Text(context ?? ""))
        .accessibilityAddTraits(.startsMediaSession)
    }
}
