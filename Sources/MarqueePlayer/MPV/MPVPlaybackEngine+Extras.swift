import Foundation

/// Point-in-time diagnostics for the `I` stats overlay. Read on demand (never observed), so it costs nothing unless shown.
public struct PlaybackStats: Sendable, Equatable {
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var videoFormat: String?
    /// Active decode path as reported by mpv: "videotoolbox", "videotoolbox-copy", or "no" (software).
    public var hwdec: String?
    /// Bits per second.
    public var videoBitrate: Double?
    public var audioBitrate: Double?
    public var audioCodec: String?
    public var framesPerSecond: Double?
    public var droppedFrames: Int = 0
    public var decoderDroppedFrames: Int = 0
    public var colorSummary: String?

    public init() {}

    public var isHardwareDecoding: Bool { hwdec.map { $0 != "no" && !$0.isEmpty } ?? false }
}

extension MPVPlaybackEngine {
    /// Silences or restores audio without touching the volume level.
    public func setMuted(_ muted: Bool) { setPropertyValue("mute", muted ? "yes" : "no") }

    /// Subtitle timing offset in seconds (positive shows subtitles later).
    public func setSubtitleDelay(_ seconds: TimeInterval) {
        setPropertyValue("sub-delay", String(format: "%.3f", seconds))
    }

    /// Shape of the picture as it should be displayed (pixel aspect and rotation applied), once a video
    /// frame has been decoded. `nil` before that and for audio-only media.
    public func displaySize() -> CGSize? {
        guard let w = property("video-params/dw").flatMap(Double.init), let h = property("video-params/dh").flatMap(Double.init),
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Lifts subtitles clear of the transport controls (`true`) or puts them back at the bottom edge.
    public func setSubtitlesRaised(_ raised: Bool) { setPropertyValue("sub-pos", raised ? "76" : "100") }

    /// Reads the diagnostics properties. Cheap; call at most about once a second.
    public func stats() -> PlaybackStats {
        func number(_ name: String) -> Double? { property(name).flatMap(Double.init) }
        func text(_ name: String) -> String? {
            guard let v = property(name), !v.isEmpty else { return nil }
            return v
        }
        var s = PlaybackStats()
        s.videoWidth = number("video-params/w").map(Int.init)
        s.videoHeight = number("video-params/h").map(Int.init)
        s.videoFormat = text("video-format")
        s.hwdec = text("hwdec-current")
        s.videoBitrate = number("video-bitrate")
        s.audioBitrate = number("audio-bitrate")
        s.audioCodec = text("audio-codec-name")
        s.framesPerSecond = number("estimated-vf-fps") ?? number("container-fps")
        s.droppedFrames = number("frame-drop-count").map(Int.init) ?? 0
        s.decoderDroppedFrames = number("decoder-frame-drop-count").map(Int.init) ?? 0
        let parts = ["video-params/primaries", "video-params/gamma"].compactMap { text($0) }
        s.colorSummary = parts.isEmpty ? nil : parts.joined(separator: " / ")
        return s
    }
}
