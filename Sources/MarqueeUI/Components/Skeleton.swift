import SwiftUI

private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let w = proxy.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.22), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 0.55)
                        .offset(x: phase * w)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.1 }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// Sweeps a highlight across the view. Apply once to a group of skeleton blocks, not to each block.
    /// The animation exists only while the view is on screen and is off under Reduce Motion.
    public func shimmering() -> some View { modifier(ShimmerModifier()) }
}

/// A placeholder block for content that is loading. Prefer skeletons to spinners.
public struct SkeletonView: View {
    private let cornerRadius: CGFloat
    private let shimmer: Bool

    public init(cornerRadius: CGFloat = Tokens.Radius.s, shimmer: Bool = true) {
        self.cornerRadius = cornerRadius
        self.shimmer = shimmer
    }

    public var body: some View {
        let block = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
        if shimmer { block.shimmering() } else { block.accessibilityHidden(true) }
    }
}

/// Poster-shaped skeleton with title / subtitle lines.
public struct PosterSkeleton: View {
    private let width: CGFloat
    private let style: ShelfStyle

    public init(width: CGFloat = Tokens.PosterSize.shelfPoster, style: ShelfStyle = .poster) {
        self.width = width
        self.style = style
    }

    public var body: some View {
        let ratio = style == .poster ? Tokens.AspectRatio.poster : Tokens.AspectRatio.backdrop
        VStack(alignment: .leading, spacing: 8) {
            SkeletonView(cornerRadius: Tokens.Radius.artwork, shimmer: false)
                .frame(width: width, height: width / ratio)
            SkeletonView(shimmer: false).frame(width: width * 0.8, height: 11)
            SkeletonView(shimmer: false).frame(width: width * 0.5, height: 9)
        }
    }
}

/// A shelf of skeleton cards sharing a single shimmer.
public struct ShelfSkeleton: View {
    private let style: ShelfStyle
    private let count: Int

    public init(style: ShelfStyle = .poster, count: Int = 8) {
        self.style = style
        self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SkeletonView(shimmer: false).frame(width: 170, height: 16)
            HStack(alignment: .top, spacing: Tokens.Spacing.cardGap) {
                ForEach(0..<count, id: \.self) { _ in
                    PosterSkeleton(
                        width: style == .poster ? Tokens.PosterSize.shelfPoster : Tokens.PosterSize.shelfWide,
                        style: style
                    )
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.gutter)
        .shimmering()
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}
