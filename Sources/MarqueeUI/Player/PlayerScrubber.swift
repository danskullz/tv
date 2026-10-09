import SwiftUI

/// Scrub bar with elapsed and remaining time. Shows played, buffered-ahead and total; a hover tooltip
/// previews the time under the pointer; dragging previews live and seeks once on release.
public struct PlayerScrubber: View {
    private let position: TimeInterval
    private let duration: TimeInterval?
    private let bufferedAhead: TimeInterval?
    private let isEnabled: Bool
    private let onScrubbing: (Bool) -> Void
    private let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    @State private var hoverFraction: Double?
    @State private var width: CGFloat = 1

    public init(
        position: TimeInterval, duration: TimeInterval?, bufferedAhead: TimeInterval?, isEnabled: Bool = true,
        onScrubbing: @escaping (Bool) -> Void = { _ in }, onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.position = position
        self.duration = duration
        self.bufferedAhead = bufferedAhead
        self.isEnabled = isEnabled
        self.onScrubbing = onScrubbing
        self.onSeek = onSeek
    }

    private var total: TimeInterval { max(duration ?? 0, 0) }
    private var canScrub: Bool { isEnabled && total > 0 }
    private var playedFraction: Double { total > 0 ? min(1, max(0, position / total)) : 0 }
    private var bufferedFraction: Double { total > 0 ? min(1, max(playedFraction, (position + (bufferedAhead ?? 0)) / total)) : 0 }
    private var shownFraction: Double { dragFraction ?? playedFraction }
    private var shownTime: TimeInterval { shownFraction * total }
    private var isActive: Bool { dragFraction != nil || hoverFraction != nil }

    public var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: PlayerTime.clock(total > 0 ? shownTime : position))
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
            track
            Text(verbatim: total > 0 ? PlayerTime.remaining(total - shownTime) : "--:--")
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityHidden(true)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.78))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(verbatim: total > 0
            ? String(localized: "\(PlayerTime.spoken(position)) of \(PlayerTime.spoken(total))")
            : PlayerTime.spoken(position)))
        .accessibilityAdjustableAction { direction in
            guard canScrub else { return }
            switch direction {
            case .increment: onSeek(min(total, position + 10))
            case .decrement: onSeek(max(0, position - 10))
            @unknown default: break
            }
        }
    }

    private var track: some View {
        let thickness: CGFloat = isActive && canScrub ? 8 : 5
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22)).frame(height: thickness)
            Capsule().fill(.white.opacity(0.38)).frame(width: max(0, width * bufferedFraction), height: thickness)
            Capsule().fill(.white).frame(width: max(0, width * shownFraction), height: thickness)
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(x: width * shownFraction - 7)
                .opacity(isActive && canScrub ? 1 : 0)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { max(1, $0.size.width) } action: { width = $0 }
        .overlay(alignment: .topLeading) { tooltip }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverFraction = canScrub ? fraction(at: point.x) : nil
            case .ended: hoverFraction = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard canScrub else { return }
                    if dragFraction == nil { onScrubbing(true) }
                    dragFraction = fraction(at: value.location.x)
                }
                .onEnded { value in
                    guard canScrub else { return }
                    let target = fraction(at: value.location.x) * total
                    dragFraction = nil
                    onScrubbing(false)
                    onSeek(target)
                }
        )
        .motion(Tokens.Motion.fade, value: isActive)
    }

    @ViewBuilder
    private var tooltip: some View {
        if canScrub, let f = dragFraction ?? hoverFraction {
            let x = min(max(width * f, 26), width - 26)
            Text(verbatim: PlayerTime.clock(f * total))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .marqueeGlass(in: Capsule())
                .fixedSize()
                .position(x: x, y: -16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func fraction(at x: CGFloat) -> Double { min(1, max(0, Double(x / width))) }
}

/// Thin horizontal slider (volume). Same visual language as the scrubber.
public struct PlayerSlider: View {
    private let value: Double
    private let label: LocalizedStringKey
    private let onChange: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false
    @State private var width: CGFloat = 1

    public init(value: Double, label: LocalizedStringKey, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.label = label
        self.onChange = onChange
    }

    public var body: some View {
        let active = hovering || dragging
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22)).frame(height: active ? 6 : 4)
            Capsule().fill(.white).frame(width: max(0, width * value), height: active ? 6 : 4)
            Circle().fill(.white).frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .offset(x: width * value - 6)
                .opacity(active ? 1 : 0)
        }
        .frame(width: 84, height: 28)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { max(1, $0.size.width) } action: { width = $0 }
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    onChange(min(1, max(0, Double(v.location.x / width))))
                }
                .onEnded { _ in dragging = false }
        )
        .motion(Tokens.Motion.fade, value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(Formatters.percent(value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, value + 0.1))
            case .decrement: onChange(max(0, value - 0.1))
            @unknown default: break
            }
        }
    }
}
