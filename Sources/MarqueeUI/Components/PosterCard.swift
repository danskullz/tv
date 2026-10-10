import SwiftUI

/// How a card draws keyboard selection.
public enum CardSelection: Sendable {
    case none
    /// Selected in a focused container: accent ring.
    case focused
    /// Selected but the container isn't focused: quiet ring.
    case inactive
}

/// Poster (2:3) or wide (16:9) card: artwork, optional download ring / watched bar, title and subtitle.
/// Pure display plus hover; selection and activation are owned by the container (`PosterGrid`, `ShelfRow`).
public struct PosterCard: View {
    private let item: PosterItem
    private let width: CGFloat
    private let style: ShelfStyle
    private let selection: CardSelection
    private let actions: ((PosterItem) -> [PosterAction])?

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        _ item: PosterItem, width: CGFloat, style: ShelfStyle = .poster,
        selection: CardSelection = .none, actions: ((PosterItem) -> [PosterAction])? = nil
    ) {
        self.item = item
        self.width = width
        self.style = style
        self.selection = selection
        self.actions = actions
    }

    private var artworkSize: CGSize {
        let ratio = style == .poster ? Tokens.AspectRatio.poster : Tokens.AspectRatio.backdrop
        return CGSize(width: width, height: (width / ratio).rounded())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(Tokens.Typography.cardTitle)
                    .lineLimit(1)
                Text(verbatim: item.subtitle.isEmpty ? " " : item.subtitle)
                    .font(Tokens.Typography.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let actions {
                ForEach(actions(item)) { action in
                    Button(role: action.isDestructive ? .destructive : nil, action: action.handler) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(verbatim: item.spokenState))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if let actions {
                ForEach(actions(item)) { action in
                    Button(action.title, action: action.handler)
                }
            }
        }
    }

    private var artwork: some View {
        let size = artworkSize
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.artwork, style: .continuous)
        // The ring sits 3pt outside the artwork, so its radius grows by the same 3pt; keeping the
        // artwork radius there makes the corners non-concentric and opens gaps at each one.
        let ring = RoundedRectangle(cornerRadius: Tokens.Radius.artwork + 3, style: .continuous)
        return ArtworkView(style == .poster ? item.poster : item.backdrop, targetSize: size)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topTrailing) { cornerBadge.padding(7) }
            .overlay(alignment: .bottom) { watchBar }
            .overlay { if hovering { hoverPlay } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .overlay(ring.strokeBorder(selectionColor, lineWidth: 3).padding(-3).opacity(selection == .none ? 0 : 1))
            // Applied only while hovering: a 14 pt blur shadow costs an offscreen render pass per
            // card, and a grid of them was being paid on every render even at zero opacity.
            .modifier(ConditionalShadow(visible: hovering, color: .black.opacity(Tokens.Shadow.cardOpacity),
                                        radius: Tokens.Shadow.cardRadius, y: 6))
            .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
            .motion(Tokens.Motion.snappy, value: hovering)
    }

    private var selectionColor: Color {
        selection == .focused ? Color.accentColor : Color.secondary.opacity(0.7)
    }

    @ViewBuilder
    private var cornerBadge: some View {
        if item.isInLibrary {
            badgeIcon("checkmark")
        } else { switch item.availability {
        case .downloading:
            ZStack {
                Circle().fill(.black.opacity(0.55))
                LiveProgressRing(id: item.id, fallback: item.downloadFraction, lineWidth: 3)
                    .padding(5)
                    .colorScheme(.dark)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
        case .queued:
            badgeIcon("clock.fill")
        case .importing:
            badgeIcon("tray.and.arrow.down.fill")
        case .local, .missing, .unaired:
            if item.watch == .watched {
                badgeIcon("checkmark")
            }
        }
        }
    }

    private func badgeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.55), in: Circle())
    }

    @ViewBuilder
    private var watchBar: some View {
        if let f = item.watch.fraction {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(.white).frame(width: proxy.size.width * max(0.04, min(1, f)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .shadow(color: .black.opacity(0.35), radius: 2)
        }
    }

    private var hoverPlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .transition(.opacity)
    }
}

/// Applies a shadow only when `visible`. `.shadow(radius:)` always builds a shadow layer and an
/// offscreen blur pass, so a zero-opacity shadow is still paid for on every card in a grid.
private struct ConditionalShadow: ViewModifier {
    let visible: Bool
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        if visible {
            content.shadow(color: color, radius: radius, y: y)
        } else {
            content
        }
    }
}

/// Button style for cards used in shelves: no chrome, a focus ring for keyboard users, press feedback.
public struct PosterButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        PosterButtonBody(configuration: configuration)
    }
}

private struct PosterButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: Tokens.Radius.artwork + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
    }
}

extension ButtonStyle where Self == PosterButtonStyle {
    public static var poster: PosterButtonStyle { PosterButtonStyle() }
}
