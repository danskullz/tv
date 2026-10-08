import SwiftUI
import AppKit

/// Design tokens shared by every Marquee view. Extend here rather than hard-coding values in views.
public enum Tokens {
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 40
        /// Horizontal inset of full-width content (shelves, grids, detail pages).
        public static let gutter: CGFloat = 28
        /// Gap between cards in grids and shelves.
        public static let cardGap: CGFloat = 18
    }

    public enum Radius {
        public static let s: CGFloat = 6
        public static let m: CGFloat = 10
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 26
        /// Corner radius for poster/backdrop artwork.
        public static let artwork: CGFloat = 10
    }

    /// Width / height ratios for artwork. Use with `.aspectRatio(_, contentMode:)`.
    public enum AspectRatio {
        public static let poster: CGFloat = 2.0 / 3.0
        public static let backdrop: CGFloat = 16.0 / 9.0
        public static let still: CGFloat = 16.0 / 9.0
        public static let square: CGFloat = 1
    }

    public enum PosterSize {
        public static let minimum: Double = 110
        public static let maximum: Double = 260
        public static let standard: Double = 160
        /// Card widths used by Home shelves.
        public static let shelfPoster: CGFloat = 150
        public static let shelfWide: CGFloat = 290
    }

    /// Type scale. Everything maps to a system text style so it follows the user's text size settings.
    public enum Typography {
        public static let heroTitle = Font.largeTitle.weight(.bold)
        public static let pageTitle = Font.title.weight(.bold)
        public static let sectionTitle = Font.title3.weight(.semibold)
        public static let cardTitle = Font.subheadline.weight(.medium)
        public static let cardSubtitle = Font.caption
        public static let body = Font.body
        public static let metadata = Font.subheadline
        public static let badge = Font.caption2.weight(.bold)
        public static let numeric = Font.body.monospacedDigit()
    }

    /// Motion springs. Always apply through `View.motion(_:value:)` or `withMotion` so Reduce Motion is honored.
    public enum Motion {
        public static let snappy = Animation.snappy(duration: 0.22)
        public static let smooth = Animation.smooth(duration: 0.38)
        public static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.72)
        public static let fade = Animation.easeOut(duration: 0.18)
    }

    public enum Shadow {
        public static let cardRadius: CGFloat = 14
        public static let cardOpacity: Double = 0.28
    }
}

// MARK: - Motion helpers

/// Runs `body` inside `withAnimation` unless the user enabled Reduce Motion.
@MainActor
public func withMotion<R>(_ animation: Animation = Tokens.Motion.snappy, _ body: () throws -> R) rethrows -> R {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        return try body()
    }
    return try withAnimation(animation, body)
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `animation(_:value:)` that is skipped when Reduce Motion is on.
    public func motion<V: Equatable>(_ animation: Animation = Tokens.Motion.snappy, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}
