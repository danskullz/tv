import SwiftUI

/// Full-bleed backdrop with a scrim into the window background and a glass overlay carrying the title,
/// metadata and primary actions. Parallax is skipped under Reduce Motion.
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
                panel
                    .padding(.horizontal, Tokens.Spacing.gutter)
                    .padding(.bottom, Tokens.Spacing.l)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    private var scrim: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s + 2) {
            if let eyebrow {
                Text(verbatim: eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(verbatim: title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if !metadata.isEmpty || quality != nil {
                HStack(spacing: Tokens.Spacing.s) {
                    Text(verbatim: metadata.joined(separator: "  ·  "))
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(.white.opacity(0.78))
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
                .padding(.top, 4)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: 640, alignment: .leading)
        .marqueeGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
