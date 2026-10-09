import Foundation

/// What the streaming pipeline is doing before and during playback. The pipeline yields these on an
/// `AsyncStream`; the player turns them into one calm, truthful status line. Mirrors the streaming
/// engine's own states without depending on it.
public enum PlayerBufferingStatus: Sendable, Equatable {
    /// Looking for sources of the data.
    case findingPeers
    /// Connected; reading the file list and layout.
    case fetchingMetadata
    /// Enough is arriving; this much is ready ahead of the playhead.
    case buffering(secondsAhead: TimeInterval)
    /// Buffer threshold met; the first frame is on its way.
    case ready
    /// Playback cannot continue right now (slow or no sources). Recoverable; the pipeline keeps trying.
    case stalled(message: String)
    /// The pipeline gave up. Plain language, never a raw error.
    case failed(message: String)

    /// The line shown under the title.
    public var statusLine: String {
        switch self {
        case .findingPeers: String(localized: "Finding peers…")
        case .fetchingMetadata: String(localized: "Getting the file ready…")
        case .buffering(let ahead):
            ahead >= 1
                ? String(localized: "Buffering · \(Int(ahead.rounded())) s ahead")
                : String(localized: "Buffering…")
        case .ready: String(localized: "Starting…")
        case .stalled(let message), .failed(let message): message
        }
    }

    public var failureMessage: String? {
        if case .failed(let message) = self { message } else { nil }
    }

    public var isStalled: Bool {
        if case .stalled = self { true } else { false }
    }
}

/// Clock strings for the transport: "4:07", "1:02:33", "−12:40".
public enum PlayerTime {
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func remaining(_ seconds: TimeInterval) -> String {
        "\u{2212}" + clock(seconds.rounded(.up))
    }

    /// Spoken form for VoiceOver: "1 hour, 2 minutes, 33 seconds".
    public static func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(max(0, seconds.isFinite ? seconds : 0)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, zeroValueUnits: .hide))
    }
}
