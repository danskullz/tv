import SwiftUI

/// Circular progress indicator. Determinate when `fraction` is set, otherwise an indeterminate arc that
/// spins only while on screen (and holds still under Reduce Motion).
public struct ProgressRing: View {
    private let fraction: Double?
    private let lineWidth: CGFloat
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    public init(fraction: Double?, lineWidth: CGFloat = 3, tint: Color = .accentColor) {
        self.fraction = fraction
        self.lineWidth = lineWidth
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .motion(.linear(duration: 0.9), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true }
                    }
                    .onDisappear { spinning = false }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(fraction.map { Text(Formatters.percent($0)) } ?? Text("In progress"))
    }
}

/// A `ProgressRing` that follows the live `ProgressBox` for `id`, falling back to a snapshot value.
public struct LiveProgressRing: View {
    private let id: String
    private let fallback: Double?
    private let lineWidth: CGFloat
    @Environment(DownloadTracker.self) private var tracker: DownloadTracker?

    public init(id: String, fallback: Double? = nil, lineWidth: CGFloat = 3) {
        self.id = id
        self.fallback = fallback
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ProgressRing(fraction: tracker?.box(for: id)?.fraction ?? fallback, lineWidth: lineWidth)
    }
}
