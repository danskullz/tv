import SwiftUI

/// One episode as the player sees it (Up Next card and episode strip).
public struct PlayerEpisode: Identifiable, Hashable, Sendable {
    public var id: String
    /// "Dust and Ashes"
    public var title: String
    /// "S1 · E4"
    public var subtitle: String
    public var artwork: Artwork?
    /// 0...1: how much of the episode's first segment is already on disk (pre-warming); `nil` = unknown.
    public var bufferedFraction: Double?

    public init(id: String, title: String, subtitle: String, artwork: Artwork? = nil, bufferedFraction: Double? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.bufferedFraction = bufferedFraction
    }
}

/// Calm full-window state shown before the first frame: blurred artwork, the title, and one truthful
/// status line. Failures replace the status with a plain message plus Retry and Close.
public struct PlayerPrerollView: View {
    public enum Phase: Equatable, Sendable {
        case working(status: String)
        case failed(message: String)
    }

    private let title: String
    private let subtitle: String?
    private let artwork: Artwork?
    private let phase: Phase
    private let onRetry: () -> Void
    private let onClose: () -> Void

    public init(
        title: String, subtitle: String?, artwork: Artwork?, phase: Phase,
        onRetry: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.phase = phase
        self.onRetry = onRetry
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black
            if let artwork {
                ArtworkView(artwork, targetSize: CGSize(width: 640, height: 360))
                    .scaleEffect(1.25)
                    .blur(radius: 60, opaque: true)
                    .opacity(0.55)
                    .accessibilityHidden(true)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                Text(verbatim: title)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                }
                statusArea.padding(.top, 22)
            }
            .foregroundStyle(.white)
            // Fill the window and centre inside it. Capping the block at a fixed 640pt measure left
            // each child centring on its own ideal width rather than the window's, which put the
            // title, the ring and the status line noticeably right of the window's centre.
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .working(let status):
            VStack(spacing: 14) {
                ProgressRing(fraction: nil, lineWidth: 3, tint: .white)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(verbatim: status)
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .motion(Tokens.Motion.fade, value: status)
                    .accessibilityLabel(Text(verbatim: status))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        case .failed(let message):
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.marqueePlay)
                        .keyboardShortcut(.defaultAction)
                    Button(action: onClose) { Text("Close") }
                        .buttonStyle(.marqueeSecondary)
                }
            }
        }
    }
}

/// Glass card offered near the end of an episode: what is next, a countdown, Play Now / Cancel.
public struct PlayerUpNextCard: View {
    private let episode: PlayerEpisode
    private let secondsRemaining: Int?
    private let fractionRemaining: Double?
    private let onPlayNow: () -> Void
    private let onCancel: () -> Void

    public init(
        episode: PlayerEpisode, secondsRemaining: Int?, fractionRemaining: Double? = nil,
        onPlayNow: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        self.episode = episode
        self.secondsRemaining = secondsRemaining
        self.fractionRemaining = fractionRemaining
        self.onPlayNow = onPlayNow
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text("Up next")
                        .font(.system(size: 12, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.62))
                    Text(verbatim: episode.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                    Text(verbatim: episode.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let secondsRemaining {
                    ZStack {
                        ProgressRing(fraction: fractionRemaining, lineWidth: 3, tint: .white)
                        Text(verbatim: "\(secondsRemaining)")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                }
            }
            HStack(spacing: 10) {
                Button(action: onPlayNow) { Label("Play Now", systemImage: "play.fill") }
                    .buttonStyle(.marqueePlay)
                    .controlSize(.small)
                Button(action: onCancel) { Text("Cancel") }
                    .buttonStyle(.marqueeSecondary)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 400)
        .marqueeGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Up next: \(episode.title), \(episode.subtitle)"))
        .accessibilityValue(Text(secondsRemaining.map { "Starts in \($0) seconds" } ?? ""))
    }

    private var thumbnail: some View {
        Group {
            if let art = episode.artwork {
                ArtworkView(art, targetSize: CGSize(width: 128, height: 72))
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
