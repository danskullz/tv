import Foundation
import MarqueeCore
import TorrentEngine

// MARK: - Request

/// The title Play was pressed on, as the library knows it.
public struct PlayTitle: Sendable, Hashable {
    /// Library title id (grab records and the blocklist hang off it).
    public var id: UUID
    public var kind: TitleKind
    public var name: String
    public var year: Int?
    public var tmdbID: Int?
    public var tvdbID: Int?
    public var imdbID: String?
    public var aliases: [String]
    /// Movie runtime, or the typical episode runtime (drives size limits and the bitrate estimate).
    public var runtimeMinutes: Double?

    public init(
        id: UUID, kind: TitleKind, name: String, year: Int? = nil, tmdbID: Int? = nil, tvdbID: Int? = nil,
        imdbID: String? = nil, aliases: [String] = [], runtimeMinutes: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.year = year
        self.tmdbID = tmdbID
        self.tvdbID = tvdbID
        self.imdbID = imdbID
        self.aliases = aliases
        self.runtimeMinutes = runtimeMinutes
    }
}

/// What to play.
public enum PlayScope: Sendable, Hashable {
    case movie
    /// One episode. A healthy season pack is still acceptable if single episodes are scarce.
    case episode(EpisodeRef)
    /// A whole season beginning at `startingAt`; prefers a healthy complete pack so the next episodes
    /// are already arriving while the first plays.
    case season(Int, startingAt: EpisodeRef)

    public var startEpisode: EpisodeRef? {
        switch self {
        case .movie: nil
        case .episode(let e): e
        case .season(_, let e): e
        }
    }
}

public struct PlayRequest: Sendable {
    public var title: PlayTitle
    public var scope: PlayScope
    /// The title's quality profile.
    public var profile: QualityProfileConfig
    /// Every known episode of the series (library context for the file mapper and pack sizing).
    public var episodes: [PackEpisode]
    /// The library episode this Play belongs to, for the decision log.
    public var episodeID: UUID?
    public var origin: Grab.Origin

    public init(
        title: PlayTitle, scope: PlayScope, profile: QualityProfileConfig = .balanced,
        episodes: [PackEpisode] = [], episodeID: UUID? = nil, origin: Grab.Origin = .stream
    ) {
        self.title = title
        self.scope = scope
        self.profile = profile
        self.episodes = episodes
        self.episodeID = episodeID
        self.origin = origin
    }
}

// MARK: - Configuration

public struct PlayPipelineConfiguration: Sendable {
    /// Releases tried before giving up.
    public var maxAttempts: Int
    public var minimumSeeders: Int
    /// A `.torrent` link download that takes longer than this falls back to the magnet link when
    /// there is one, else fails the attempt. Bounds one slow indexer, not the whole Play.
    public var linkFetchTimeout: Duration
    /// Controller start (metadata fetch) bound for the first attempt: the top pick is usually
    /// healthy, so a dead one should fail over in seconds.
    public var metadataTimeoutFirstAttempt: Duration
    /// Controller start bound for later attempts.
    public var metadataTimeoutLaterAttempts: Duration
    /// An attempt that has not become playable after this long counts as failed.
    public var readyTimeout: Duration
    /// Peers every attempt connects to directly, on top of any a magnet link carries (`x.pe`).
    public var extraPeers: [PeerEndpoint]
    /// Sustained download speed measured for this user, if known.
    public var measuredThroughputBytesPerSecond: Double?
    public var formats: [CustomFormatConfig]
    public var streamMode: StreamMode

    public init(
        maxAttempts: Int = 4, minimumSeeders: Int = 1, readyTimeout: Duration = .seconds(60),
        extraPeers: [PeerEndpoint] = [], measuredThroughputBytesPerSecond: Double? = nil,
        formats: [CustomFormatConfig] = BuiltInFormats.all, streamMode: StreamMode = .streamFromStart,
        linkFetchTimeout: Duration = .seconds(15), metadataTimeoutFirstAttempt: Duration = .seconds(20),
        metadataTimeoutLaterAttempts: Duration = .seconds(30)
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.minimumSeeders = minimumSeeders
        self.readyTimeout = readyTimeout
        self.extraPeers = extraPeers
        self.measuredThroughputBytesPerSecond = measuredThroughputBytesPerSecond
        self.formats = formats
        self.streamMode = streamMode
        self.linkFetchTimeout = linkFetchTimeout
        self.metadataTimeoutFirstAttempt = metadataTimeoutFirstAttempt
        self.metadataTimeoutLaterAttempts = metadataTimeoutLaterAttempts
    }

    /// Metadata bound for attempt `number` (1-based): tight on the top pick, looser afterwards.
    public func metadataTimeout(forAttempt number: Int) -> Duration {
        number <= 1 ? metadataTimeoutFirstAttempt : metadataTimeoutLaterAttempts
    }
}

// MARK: - Seams

/// The slice of the indexer coordinator the pipeline uses.
public protocol ReleaseSearching: Sendable {
    func search(_ query: TorznabQuery) async -> CoordinatedSearchResult
    func enabledIndexerCount() async -> Int
}

/// ``ReleaseSearching`` backed by the real coordinator.
public struct CoordinatorSearcher: ReleaseSearching {
    public let coordinator: IndexerSearchCoordinator
    public init(_ coordinator: IndexerSearchCoordinator) { self.coordinator = coordinator }

    public func search(_ query: TorznabQuery) async -> CoordinatedSearchResult {
        await coordinator.search(query)
    }

    public func enabledIndexerCount() async -> Int {
        await coordinator.indexers.filter(\.enabled).count
    }
}

/// One running stream (a ``StreamSessionController`` in production).
public protocol StreamControlling: Sendable {
    func start(
        source: TorrentSource, content: StreamContent, startEpisode: EpisodeRef?, mode: StreamMode,
        peers: [PeerEndpoint], corrections: [Int: [EpisodeRef]], episodeOrder: [EpisodeRef]?
    ) async throws -> StreamHandle
    func advance(to episode: EpisodeRef) async throws -> StreamHandle
    func setMediaDuration(_ seconds: Double) async
    func playheadMoved(to offset: Int64) async
    func stop(removeTorrent: Bool, deleteFiles: Bool) async
    /// Per-attempt metadata bound, applied before `start`. Controllers that cannot honor it
    /// ignore the hint; the pipeline also enforces its own bound around `start`.
    func setMetadataTimeout(_ timeout: Duration) async
    nonisolated func statusUpdates() -> AsyncStream<StreamStatus>
    nonisolated func events() -> AsyncStream<StreamControllerEvent>
}

extension StreamControlling {
    public func setMetadataTimeout(_ timeout: Duration) async {}
}

extension StreamSessionController: StreamControlling {}

/// Creates one controller per attempt.
public protocol StreamControllerFactory: Sendable {
    func makeController() -> any StreamControlling
}

/// Builds ``StreamSessionController``s on a shared torrent session and stream server.
public struct SessionControllerFactory: StreamControllerFactory {
    private let session: TorrentSession
    private let server: StreamServer
    private let configuration: @Sendable () -> StreamControllerConfiguration

    /// `configuration` is evaluated per attempt, so a changed download folder applies to the next Play.
    public init(
        session: TorrentSession, server: StreamServer, configuration: @escaping @Sendable () -> StreamControllerConfiguration
    ) {
        self.session = session
        self.server = server
        self.configuration = configuration
    }

    public func makeController() -> any StreamControlling {
        StreamSessionController(session: session, server: server, configuration: configuration())
    }
}

// MARK: - Output

/// Plain-language progress of a Play, shown while the player is still opening.
public struct PlayStatus: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case searching, choosing, connecting, buffering, ready, retrying, failed
    }

    public var phase: Phase
    public var message: String
    /// 1-based attempt number (which release is being tried).
    public var attempt: Int
    /// The stream's own state while connecting and buffering (nil for search and selection lines).
    public var stream: StreamStatus?

    public init(_ phase: Phase, _ message: String, attempt: Int = 1, stream: StreamStatus? = nil) {
        self.phase = phase
        self.message = message
        self.attempt = attempt
        self.stream = stream
    }
}

/// The release that was picked, for the "Why this release?" panel.
public struct ChosenRelease: Sendable {
    public var title: String
    public var indexerName: String
    public var tier: QualityTier
    public var seeders: Int?
    public var size: Int64?
    public var infoHash: String?
    public var isPack: Bool
    /// One-line explanation ("Best to stream: 720p WEB-DL; 12 seeders; ...").
    public var explanation: String
    /// The decision-log entry, see ``GrabRepository``.
    public var grabID: UUID
}

/// A stream that is ready to play.
public struct PlayStream: Sendable {
    public let url: URL
    /// Episodes inside the file being served.
    public let episodes: [EpisodeRef]
    public let release: ChosenRelease
    public let control: PlayStreamControl

    public init(url: URL, episodes: [EpisodeRef], release: ChosenRelease, control: PlayStreamControl) {
        self.url = url
        self.episodes = episodes
        self.release = release
        self.control = control
    }
}

/// Operations on a running stream after Play succeeded.
public struct PlayStreamControl: Sendable {
    private let controller: any StreamControlling
    public let torrent: TorrentID

    init(controller: any StreamControlling, torrent: TorrentID) {
        self.controller = controller
        self.torrent = torrent
    }

    /// Latest buffering state first, then every change.
    public func statusUpdates() -> AsyncStream<StreamStatus> { controller.statusUpdates() }
    public func events() -> AsyncStream<StreamControllerEvent> { controller.events() }
    /// Moves to another episode of the same torrent (season packs).
    public func advance(to episode: EpisodeRef) async throws -> StreamHandle { try await controller.advance(to: episode) }
    public func setMediaDuration(_ seconds: Double) async { await controller.setMediaDuration(seconds) }
    public func playheadMoved(to offset: Int64) async { await controller.playheadMoved(to: offset) }
    /// Stops serving. The download keeps going unless `removeTorrent` is set.
    public func stop(removeTorrent: Bool = false, deleteFiles: Bool = false) async {
        await controller.stop(removeTorrent: removeTorrent, deleteFiles: deleteFiles)
    }
}

/// A Play in flight: status lines while it works, then the stream or a plain-language failure.
public struct PlayOperation: Sendable {
    public let statuses: AsyncStream<PlayStatus>
    private let task: Task<PlayStream, any Error>

    init(statuses: AsyncStream<PlayStatus>, task: Task<PlayStream, any Error>) {
        self.statuses = statuses
        self.task = task
    }

    /// Waits for the stream. Throws ``PlayPipelineError`` (or `CancellationError`).
    public func stream() async throws -> PlayStream { try await task.value }

    /// Abandons the Play; anything already started is torn down.
    public func cancel() { task.cancel() }
}

// MARK: - Errors

public enum PlayPipelineError: Error, Sendable, Equatable {
    case noIndexers
    case noResults(indexersSearched: Int, indexersFailed: Int)
    /// Releases exist but none passed the quality profile (or all were already tried).
    case nothingSuitable(found: Int, summary: String)
    case allAttemptsFailed(attempts: Int, lastReason: String)

    /// Never a raw engine error.
    public var plainLanguage: String {
        switch self {
        case .noIndexers:
            "Add an indexer in Settings so Marquee has somewhere to look."
        case .noResults(let searched, let failed):
            failed > 0 && failed == searched
                ? "Your indexers didn't answer. Check them in Settings and try again."
                : "Couldn't find anything to play. Your indexers returned no releases for this title."
        case .nothingSuitable(let found, let summary):
            "Found \(found) release\(found == 1 ? "" : "s"), but none matched this episode (\(summary)). Try adjusting the quality profile or picking a release from search."
        case .allAttemptsFailed(let attempts, let lastReason):
            Self.attemptsFailedMessage(attempts: attempts, lastReason: lastReason)
        }
    }

    /// When every attempt failed the same way, that reason (e.g. the packs don't include this
    /// episode) is more useful than a generic "try again". Mixed failures keep the generic.
    static func attemptsFailedMessage(attempts: Int, lastReason: String) -> String {
        let base = "Tried \(attempts) release\(attempts == 1 ? "" : "s") but none of them could be played right now."
        if lastReason.isEmpty { return base + " Try again later or choose another quality." }
        return base + " \(lastReason)"
    }
}

extension PlayPipelineError: LocalizedError {
    public var errorDescription: String? { plainLanguage }
}
