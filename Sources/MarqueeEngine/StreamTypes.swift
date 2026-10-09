import Foundation
import MarqueeCore
import Synchronization
import TorrentEngine

// MARK: - Status

/// Why playback cannot make progress right now. Plain language via ``message``.
public enum StallReason: Sendable, Equatable {
    /// Nobody is connected.
    case noPeers
    /// Connected, but data is arriving too slowly (or not at all) for this part of the file.
    case slowDownload

    public var message: String {
        switch self {
        case .noPeers: "Can't find anyone sharing this release right now."
        case .slowDownload: "The download is too slow to keep up. It may start again on its own."
        }
    }
}

/// What the player's buffering UI shows. Truthful and minimal ("Finding peers…", "Buffering 12 s ahead").
public enum StreamStatus: Sendable, Equatable {
    case fetchingMetadata
    case findingPeers
    /// `secondsAhead` is an estimate from the file's average bitrate (see
    /// ``StreamControllerConfiguration/assumedRuntime``); `bytesAhead` is exact.
    case buffering(secondsAhead: Double, bytesAhead: Int64)
    case ready
    case stalled(StallReason)
    /// Terminal. A message fit to show to the user, never a raw engine error.
    case failed(String)

    public var isTerminal: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Things other components (the importer, the UI) react to that are not buffering state.
public enum StreamControllerEvent: Sendable, Equatable {
    /// A file finished downloading and verified. `episodes` are the episodes the mapper assigned to it
    /// (empty for extras); the importer can pick it up from `path` (relative to the save path).
    case fileCompleted(torrent: TorrentID, fileIndex: Int, path: String, episodes: [EpisodeRef])
    /// Every wanted piece is on disk.
    case torrentFinished(TorrentID)
    /// A downloaded piece failed verification and will be fetched again.
    case pieceHashFailed(torrent: TorrentID, piece: Int)
}

// MARK: - Errors

public enum StreamControllerError: Error, Sendable, Equatable {
    case alreadyStarted
    case notStarted
    case metadataTimeout
    case noPlayableFile
    case episodeNotInPack(EpisodeRef)
    /// The episode lives in a multi-volume archive; streaming those needs the archive reader.
    case archiveStreamingUnsupported
    case engine(String)

    /// Plain-language text for the UI.
    public var plainLanguage: String {
        switch self {
        case .alreadyStarted: return "This stream is already running."
        case .notStarted: return "This stream hasn't started yet."
        case .metadataTimeout: return "Couldn't find anyone sharing this release. Try another version."
        case .noPlayableFile: return "This release doesn't seem to contain anything playable."
        case .episodeNotInPack(let e): return "This release doesn't include \(e)."
        case .archiveStreamingUnsupported: return "This release is packed in archives, which can't be played while downloading yet."
        case .engine(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "The download engine ran into a problem. Try another version." }
            return "The download engine ran into a problem (\(SecretRedactor.redact(trimmed))). Try another version."
        }
    }
}

// MARK: - Inputs

/// Where the torrent comes from.
public enum TorrentSource: Sendable {
    case magnet(String)
    case torrentFile(Data)
}

/// What the torrent is expected to contain.
public enum StreamContent: Sendable {
    /// A season pack, several seasons, a complete series or a single episode.
    case series(PackSeriesContext)
    /// One movie: the largest video file is played.
    case movie(title: String)

    /// A movie is mapped as this single "episode".
    public static let movieEpisode = EpisodeRef(season: 1, episode: 1)
}

public struct PeerEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// What ``StreamSessionController`` hands the player.
public struct StreamHandle: Sendable {
    public let torrent: TorrentID
    /// Episodes in the file being played (several for multi-episode files).
    public let episodes: [EpisodeRef]
    public let fileIndex: Int
    public let url: URL
    /// Latest status first, then every change.
    public let status: AsyncStream<StreamStatus>
    /// The pack mapping, for the review table and gap handling. `nil` for movies.
    public let mapping: PackMappingResult?
}

// MARK: - Readiness (adaptive start seam)

/// Everything a start policy may look at.
public struct ReadinessInput: Sendable {
    public var fileLength: Int64
    public var playhead: Int64
    /// Bytes available without a gap from the playhead.
    public var bytesAhead: Int64
    public var headComplete: Bool
    public var tailComplete: Bool
    public var headBytes: Int64
    /// Payload bytes per second right now.
    public var downloadRate: Int
    /// Average bitrate estimate in bytes per second.
    public var estimatedBytesPerSecond: Double
    public var remainingBytes: Int64 { max(0, fileLength - playhead) }
}

/// Decides when playback may begin. The fixed-buffer policy below is the Phase 0 behaviour; the
/// probabilistic stall model ("P(no stall for the remaining runtime) >= threshold", SCOPE.md §4.5)
/// plugs in here by implementing this protocol and reading `downloadRate` and the bitrate estimate.
public protocol StreamReadinessPolicy: Sendable {
    func isReady(_ input: ReadinessInput) -> Bool
}

/// Ready once the container head and tail are in and `bytesAfterHead` more bytes follow the head.
///
/// When `cushionSeconds` is set, readiness additionally requires that many seconds of the
/// estimated bitrate buffered ahead (capped by the bytes remaining), so starting playback means
/// a real time cushion, not just a fixed byte count. `nil` (the default) keeps the legacy
/// fixed-buffer behaviour.
public struct FixedBufferReadinessPolicy: StreamReadinessPolicy {
    public var bytesAfterHead: Int64
    public var cushionSeconds: Double?
    public init(bytesAfterHead: Int64 = 4 << 20, cushionSeconds: Double? = nil) {
        self.bytesAfterHead = bytesAfterHead
        self.cushionSeconds = cushionSeconds
    }

    public func isReady(_ input: ReadinessInput) -> Bool {
        guard input.headComplete, input.tailComplete else { return false }
        var need = input.headBytes + bytesAfterHead
        if let cushionSeconds, cushionSeconds > 0 {
            let cushionBytes = input.estimatedBytesPerSecond * cushionSeconds
            need = max(need, Int64(min(cushionBytes, Double(Int64.max))))
        }
        return input.bytesAhead >= min(need, input.remainingBytes)
    }
}

// MARK: - Configuration

/// Session settings that make libtorrent react quickly while something is being watched. They are
/// applied when the stream starts and put back when it stops or the torrent finishes, so an idle app
/// keeps libtorrent's cheap defaults (SCOPE.md §5.6: idle CPU ~0).
public struct StreamingTuning: Sendable, Equatable {
    /// `tick_interval` (ms) while streaming. libtorrent runs unchoke bookkeeping, time-critical piece
    /// requests and bandwidth quota refills on this tick, so it bounds how soon a new deadline turns
    /// into a request. `nil` leaves the setting alone.
    public var activeTickInterval: Int? = 100
    /// Value restored afterwards (libtorrent's default).
    public var idleTickInterval = 500
    /// While streaming, pick pieces by file priority from the very first request. libtorrent's default
    /// (`initial_picker_threshold` 4) picks the first pieces at random across the whole torrent,
    /// ignoring file priorities, which sends the first wave of requests to the wrong episodes.
    public var priorityFirstPicking = true

    public init() {}
    public static let disabled: StreamingTuning = {
        var t = StreamingTuning()
        t.activeTickInterval = nil
        t.priorityFirstPicking = false
        return t
    }()
}

public struct StreamControllerConfiguration: Sendable {
    /// Where libtorrent writes (the incomplete-downloads folder).
    public var savePath: URL
    public var planOptions: StreamPlanOptions
    public var readinessPolicy: any StreamReadinessPolicy
    /// How much incomplete data may carry piece deadlines at once (refilled as pieces land); `nil` = the
    /// whole plan window at once.
    public var deadlineBudgetBytes: Int64?
    /// Once the download rate is known, the budget grows to this many seconds of it (capped by the plan's
    /// window), so fast connections keep a deeper deadline window than the starting budget.
    public var deadlineBudgetSeconds: Double
    /// Seconds of estimated playback that must be buffered ahead before `.ready` (on top of the
    /// readiness policy's fixed buffer), so starting means a time cushion, not just a byte count.
    /// Applies when the policy is a ``FixedBufferReadinessPolicy`` without its own cushion and
    /// `requirePlaybackCushion` is true.
    public var readyCushionSeconds: Double
    /// When true (default), the controller requires the `readyCushionSeconds` cushion even though
    /// the readiness policy alone would allow starting sooner. Set to false for the legacy
    /// fixed-buffer behaviour.
    public var requirePlaybackCushion: Bool
    public var tuning: StreamingTuning
    public var metadataTimeout: Duration
    /// No piece for this long while waiting for data reports ``StreamStatus/stalled(_:)``.
    public var stallTimeout: Duration
    /// Used to turn bytes into "seconds ahead" until the player reports the real duration
    /// (``StreamSessionController/setMediaDuration(_:)``).
    public var assumedEpisodeRuntime: Duration
    public var assumedMovieRuntime: Duration
    /// Buffering updates closer together than this are dropped (state changes are never dropped).
    public var minimumBufferingUpdateInterval: Duration

    public init(
        savePath: URL,
        planOptions: StreamPlanOptions = StreamPlanOptions(),
        readinessPolicy: any StreamReadinessPolicy = FixedBufferReadinessPolicy(),
        deadlineBudgetBytes: Int64? = 1 << 20,
        deadlineBudgetSeconds: Double = 2,
        readyCushionSeconds: Double = 15,
        requirePlaybackCushion: Bool = true,
        tuning: StreamingTuning = StreamingTuning(),
        metadataTimeout: Duration = .seconds(60),
        stallTimeout: Duration = .seconds(20),
        assumedEpisodeRuntime: Duration = .seconds(45 * 60),
        assumedMovieRuntime: Duration = .seconds(110 * 60),
        minimumBufferingUpdateInterval: Duration = .milliseconds(100)
    ) {
        self.savePath = savePath
        self.planOptions = planOptions
        self.readinessPolicy = readinessPolicy
        self.deadlineBudgetBytes = deadlineBudgetBytes
        self.deadlineBudgetSeconds = deadlineBudgetSeconds
        self.readyCushionSeconds = readyCushionSeconds
        self.requirePlaybackCushion = requirePlaybackCushion
        self.tuning = tuning
        self.metadataTimeout = metadataTimeout
        self.stallTimeout = stallTimeout
        self.assumedEpisodeRuntime = assumedEpisodeRuntime
        self.assumedMovieRuntime = assumedMovieRuntime
        self.minimumBufferingUpdateInterval = minimumBufferingUpdateInterval
    }
}

// MARK: - Fan-out helper

/// Multi-subscriber broadcast of values. Optionally replays the most recent value to new subscribers.
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
        var latest: Element?
        var replay: [Element] = []
        var finished = false
    }

    private let state = Mutex(State())
    private let replayLatest: Bool
    private let replayLimit: Int
    private let shouldReplay: @Sendable (Element) -> Bool
    private let policy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(
        replayLatest: Bool, policy: AsyncStream<Element>.Continuation.BufferingPolicy,
        replayLimit: Int = 0, shouldReplay: @escaping @Sendable (Element) -> Bool = { _ in true }
    ) {
        self.replayLatest = replayLatest
        self.policy = policy
        self.replayLimit = max(0, replayLimit)
        self.shouldReplay = shouldReplay
    }

    func subscribe() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: policy)
        let alreadyFinished = state.withLock { s -> Bool in
            if s.finished { return true }
            if replayLimit > 0 {
                for value in s.replay { continuation.yield(value) }
            } else if replayLatest, let latest = s.latest {
                continuation.yield(latest)
            }
            s.subscribers[id] = continuation
            return false
        }
        if alreadyFinished {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ value: Element) {
        let targets = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            s.latest = value
            if replayLimit > 0, shouldReplay(value) {
                s.replay.append(value)
                if s.replay.count > replayLimit { s.replay.removeFirst(s.replay.count - replayLimit) }
            }
            return Array(s.subscribers.values)
        }
        for t in targets { t.yield(value) }
    }

    func finish() {
        let targets = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            s.finished = true
            defer { s.subscribers.removeAll() }
            return Array(s.subscribers.values)
        }
        for t in targets { t.finish() }
    }
}
