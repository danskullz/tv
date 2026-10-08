import SwiftUI

private struct GlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        } else if #available(macOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background(tint?.opacity(0.35) ?? .clear, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.35), lineWidth: 0.5))
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Liquid Glass on macOS 26; a material with a hairline edge on macOS 15; an opaque fill when Reduce
    /// Transparency is on. Use for floating chrome only (hero overlays, palette, HUDs), never for content.
    public func marqueeGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, tint: tint, interactive: interactive))
    }
}
