import Foundation

/// High-level playback state, derived from the engine's low-level flags.
public enum PlaybackState: Sendable, Equatable {
    /// Nothing loaded.
    case idle
    /// A file was requested and is opening (demuxing / probing).
    case loading
    /// Loaded but not advancing: network stall, cache underrun, or a seek in flight.
    case buffering
    case playing
    case paused
    /// Reached the end of the media (the last frame stays on screen).
    case ended
    /// Playback failed; the message is plain language, never a raw error code.
    case failed(String)
}

public struct MediaTrack: Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case video, audio, subtitle }

    /// Engine track id (stable for the lifetime of the loaded file). Pass to `select…Track`.
    public let id: Int
    public let kind: Kind
    public let title: String?
    /// ISO 639 language code as tagged in the file.
    public let language: String?
    public let codec: String?
    public let channelCount: Int?
    public let isDefault: Bool
    public let isForced: Bool
    public let isExternal: Bool

    public init(id: Int, kind: Kind, title: String? = nil, language: String? = nil, codec: String? = nil,
                channelCount: Int? = nil, isDefault: Bool = false, isForced: Bool = false, isExternal: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.language = language; self.codec = codec
        self.channelCount = channelCount; self.isDefault = isDefault; self.isForced = isForced; self.isExternal = isExternal
    }
}

/// Everything the UI needs, as a value. `PlaybackEngine.snapshot` always returns the latest one.
public struct PlaybackSnapshot: Sendable, Equatable {
    public var state: PlaybackState = .idle
    /// Seconds from the start of the media.
    public var position: TimeInterval = 0
    public var duration: TimeInterval?
    /// Seconds of media buffered ahead of `position`, when the engine can tell.
    public var bufferedAhead: TimeInterval?
    public var audioTracks: [MediaTrack] = []
    public var subtitleTracks: [MediaTrack] = []
    public var selectedAudioTrack: Int?
    public var selectedSubtitleTrack: Int?
    /// 0...1 (the engine may allow >1 later for software gain).
    public var volume: Double = 1
    public var speed: Double = 1
    public var isSeekable: Bool = false

    public init() {}
}

/// Change notifications. Position updates are coalesced by the engine (a few per second) so a playing
/// video costs the UI a handful of wakeups, and a paused or idle one costs none.
public enum PlaybackEvent: Sendable, Equatable {
    case state(PlaybackState)
    case position(TimeInterval)
    case duration(TimeInterval?)
    case bufferedAhead(TimeInterval?)
    case tracks(audio: [MediaTrack], subtitle: [MediaTrack], selectedAudio: Int?, selectedSubtitle: Int?)
    case volume(Double)
    case speed(Double)
    case seekable(Bool)
}

/// One interface over every playback backend (libmpv now; an AVPlayer fast path later).
public protocol PlaybackEngine: AnyObject, Sendable {
    /// Change stream. Single consumer; finishes when the engine shuts down.
    var events: AsyncStream<PlaybackEvent> { get }
    /// Latest state, safe to read from any thread.
    var snapshot: PlaybackSnapshot { get }

    /// Opens `url` (file or http) and starts playing. Replaces anything already loaded.
    func load(_ url: URL, startAt: TimeInterval?)
    func play()
    func pause()
    func togglePause()
    /// Seeks to an absolute position. `exact: false` snaps to the nearest keyframe (faster).
    func seek(to position: TimeInterval, exact: Bool)
    func seek(by delta: TimeInterval)
    /// `nil` disables the track (subtitles) or leaves audio muted (audio).
    func selectAudioTrack(_ id: Int?)
    func selectSubtitleTrack(_ id: Int?)
    /// 0...1.
    func setVolume(_ volume: Double)
    /// 1.0 = normal; pitch is corrected.
    func setSpeed(_ speed: Double)
    /// Unloads the current file but keeps the engine usable.
    func stop()
    /// Releases the backend. The engine is unusable afterwards; `events` finishes.
    func shutdown()
}

public extension PlaybackEngine {
    func load(_ url: URL) { load(url, startAt: nil) }
    func seek(to position: TimeInterval) { seek(to: position, exact: true) }
}
