import SwiftUI

/// Full-bleed backdrop with the title, metadata and primary actions set directly on the artwork over a
/// legibility scrim. On macOS 26 the artwork extends under the sidebar glass. Parallax is skipped under
/// Reduce Motion.
public struct HeroHeader<Actions: View>: View {
    private let title: String
    private let eyebrow: String?
    private let metadata: [String]
    private let quality: Quality?
    private let overview: String?
    private let backdrop: Artwork
    private let height: CGFloat
    private let actions: Actions

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(
        title: String, eyebrow: String? = nil, metadata: [String] = [], quality: Quality? = nil,
        overview: String? = nil, backdrop: Artwork, height: CGFloat = 500,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.eyebrow = eyebrow
        self.metadata = metadata
        self.quality = quality
        self.overview = overview
        self.backdrop = backdrop
        self.height = height
        self.actions = actions()
    }

    public var body: some View {
        GeometryReader { geo in
            let minY = reduceMotion ? 0 : geo.frame(in: .scrollView).minY
            let shift = minY < 0 ? -minY * 0.4 : 0
            ZStack(alignment: .bottomLeading) {
                ArtworkView(backdrop, targetSize: CGSize(width: geo.size.width, height: height))
                    .frame(width: geo.size.width, height: height + 200)
                    .offset(y: shift)
                    .frame(width: geo.size.width, height: height, alignment: .bottom)
                    .clipped()
                    .overlay(scrim)
                    .extendingUnderSidebar()
                panel
                    .padding(.horizontal, Tokens.Spacing.gutter)
                    .padding(.bottom, Tokens.Spacing.xl)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    private var scrim: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
            LinearGradient(
                stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.65)],
                startPoint: .leading, endPoint: .trailing
            )
            // Dark mode melts into the window; light mode keeps a clean edge (a dark-to-white fade smears).
            LinearGradient(
                stops: colorScheme == .dark
                    ? [
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.55), location: 0.85),
                        .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                    ]
                    : [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.6), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let eyebrow {
                Text(verbatim: eyebrow)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text(verbatim: title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
                .accessibilityAddTraits(.isHeader)
            if !metadata.isEmpty || quality != nil {
                HStack(spacing: Tokens.Spacing.s) {
                    Text(verbatim: metadata.joined(separator: "  ·  "))
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(.white.opacity(0.8))
                    if let quality { QualityBadge(quality) }
                }
            }
            if let overview, !overview.isEmpty {
                Text(verbatim: overview)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(3)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            HStack(spacing: Tokens.Spacing.s + 2) { actions }
                .padding(.top, Tokens.Spacing.s)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

private extension View {
    @ViewBuilder
    func extendingUnderSidebar() -> some View {
        if #available(macOS 26, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }
}
