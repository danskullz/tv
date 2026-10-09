import Foundation
import MarqueeCore
import TorrentEngine

/// Drives one "press Play" from torrent to playable URL.
///
/// Flow of ``start(source:content:startEpisode:mode:peers:corrections:episodeOrder:)``:
/// add the torrent held (`.holdDownload`) -> wait for metadata -> map files to episodes
/// (`PackFileMapper`) -> build the ordered `StreamPlan` -> apply file priorities and the head, tail and
/// window deadlines -> start the download -> register the episode with the ``StreamServer``.
///
/// From then on it is event driven. Piece-finished events from the engine update buffering state; the
/// server's `prioritize(offset:length:)` calls (one per request and one per few MB read) move the
/// playhead, which re-runs `StreamPlan.replan` through a ``TorrentDeadlineScheduler`` that sends only
/// changed deadlines. A seek is just a request at a new offset, so it takes effect immediately. The
/// only timer is a single stall watchdog that runs while the buffer is not satisfied.
///
/// One controller serves one torrent; create a new one for the next stream.
public actor StreamSessionController {
    // MARK: State

    private struct Item {
        var episodes: [EpisodeRef]
        var fileIndex: Int
        var map: PieceMap
        var url: URL
    }

    private let session: TorrentSession
    private let server: StreamServer
    private let config: StreamControllerConfiguration
    private let statusHub = Broadcaster<StreamStatus>(replayLatest: true, policy: .bufferingNewest(32))
    private let eventHub = Broadcaster<StreamControllerEvent>(
        replayLatest: false, policy: .unbounded, replayLimit: 100_000,
        shouldReplay: { if case .fileCompleted = $0 { true } else { false } })
    private let playheadUpdates: AsyncStream<PlayheadUpdate>
    private let playheadContinuation: AsyncStream<PlayheadUpdate>.Continuation

    private var torrent: TorrentID?
    private var started = false
    private var metadata: TorrentMetadata?
    private var mapping: PackMappingResult?
    private var planner: PackStreamPlanner?
    private var plan: StreamPlan?
    private var mode: StreamMode = .streamFromStart
    private var isMovie = false
    private var scheduler: TorrentDeadlineScheduler?
    private var current: Item?
    private var registeredTokens: [String] = []

    private var have = PieceAvailability(pieceCount: 0)
    private var playhead: Int64 = 0
    private var mediaDuration: Double?
    private var downloadRate = 0
    private var rateSampledAt: ContinuousClock.Instant?

    private var lastStatus: StreamStatus?
    private var lastStatusAt: ContinuousClock.Instant?
    private var lastProgress = ContinuousClock.now
    private var watchdog: Task<Void, Never>?
    private var eventLoop: Task<Void, Never>?
    private var playheadLoop: Task<Void, Never>?
    private var stopped = false

    /// Raw engine messages, for the diagnostics bundle. Never shown to the user.
    public private(set) var diagnostics: [String] = []

    public init(session: TorrentSession, server: StreamServer, configuration: StreamControllerConfiguration) {
        self.session = session
        self.server = server
        self.config = configuration
        (playheadUpdates, playheadContinuation) = AsyncStream<PlayheadUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        eventLoop?.cancel()
        playheadLoop?.cancel()
        watchdog?.cancel()
        playheadContinuation.finish()
    }

    // MARK: Observation

    /// Buffering state, latest value first. Available before `start`, so "Fetching metadata" is visible.
    public nonisolated func statusUpdates() -> AsyncStream<StreamStatus> { statusHub.subscribe() }

    /// File-completed and similar events for the importer.
    public nonisolated func events() -> AsyncStream<StreamControllerEvent> { eventHub.subscribe() }

    public var currentStatus: StreamStatus? { lastStatus }
    public var isReadyToPlay: Bool { lastStatus == .ready }
    public var torrentID: TorrentID? { torrent }
    public var pieceAvailability: PieceAvailability { have }
    public var currentEpisodes: [EpisodeRef] { current?.episodes ?? [] }

    /// Current deadline bookkeeping, for tests and the diagnostics view.
    public struct DeadlineState: Sendable {
        public var playhead: Int64
        public var deadlines: [Int: Int]
        public var setCalls: Int
        public var clearCalls: Int
        public var replans: Int
    }

    public func deadlineState() async -> DeadlineState? {
        guard let scheduler else { return nil }
        return DeadlineState(
            playhead: await scheduler.playhead, deadlines: await scheduler.appliedDeadlines,
            setCalls: await scheduler.deadlineSetCount, clearCalls: await scheduler.deadlineClearCount,
            replans: await scheduler.replanCount)
    }

    /// Suspends until the buffer policy says playback may begin.
    public func waitUntilReady() async throws {
        for await status in statusHub.subscribe() {
            switch status {
            case .ready: return
            case .failed(let message): throw StreamControllerError.engine(message)
            default: continue
            }
        }
        throw CancellationError()
    }

    // MARK: Start

    /// - Parameters:
    ///   - startEpisode: Where playback begins. `nil` = first playable episode in watch order (or the movie).
    ///   - peers: Peers to connect to directly (tracker/DHT discovery is the session's business).
    ///   - corrections: The user's file -> episode corrections, applied before planning.
    ///   - episodeOrder: Overrides the playback order (default: season/episode order, specials last).
    public func start(
        source: TorrentSource,
        content: StreamContent,
        startEpisode: EpisodeRef? = nil,
        mode: StreamMode = .streamFromStart,
        peers: [PeerEndpoint] = [],
        corrections: [Int: [EpisodeRef]] = [:],
        episodeOrder: [EpisodeRef]? = nil
    ) async throws -> StreamHandle {
        guard !started, !stopped else { throw StreamControllerError.alreadyStarted }
        started = true
        do {
            return try await performStart(
                source: source, content: content, startEpisode: startEpisode, mode: mode, peers: peers,
                corrections: corrections, episodeOrder: episodeOrder)
        } catch {
            let wrapped = Self.wrap(error)
            if case .engine(let raw) = wrapped { diagnostics.append(raw) }
            publish(.failed(wrapped.plainLanguage))
            throw wrapped
        }
    }

    private func performStart(
        source: TorrentSource, content: StreamContent, startEpisode: EpisodeRef?, mode: StreamMode,
        peers: [PeerEndpoint], corrections: [Int: [EpisodeRef]], episodeOrder: [EpisodeRef]?
    ) async throws -> StreamHandle {
        let events = session.events()  // before the add, so no event can slip past the loop
        await applyTuning()
        let id: TorrentID
        switch source {
        case .magnet(let uri):
            publish(.fetchingMetadata)
            id = try await session.addMagnet(uri, savePath: config.savePath.path, options: [.holdDownload, .sequential])
        case .torrentFile(let data):
            publish(.findingPeers)
            id = try await session.addTorrent(data: data, savePath: config.savePath.path, options: [.holdDownload, .sequential])
        }
        torrent = id
        for peer in peers { try? await session.connectPeer(id, host: peer.host, port: peer.port) }

        let metadata: TorrentMetadata
        do {
            metadata = try await session.waitForMetadata(id, timeout: config.metadataTimeout)
        } catch TorrentError.timedOut {
            throw StreamControllerError.metadataTimeout
        }
        self.metadata = metadata
        publish(.findingPeers)

        // Which file plays which episode.
        let files = metadata.files.map { PackFile(index: $0.index, path: $0.path, size: $0.size, offset: $0.offset) }
        var fileCorrections = corrections
        let series: PackSeriesContext
        switch content {
        case .series(let context):
            series = context
        case .movie(let title):
            isMovie = true
            series = PackSeriesContext(
                title: title, episodes: [PackEpisode(ref: StreamContent.movieEpisode)], targetSeasons: [1])
            if let main = Self.mainVideoFile(in: files) { fileCorrections[main] = [StreamContent.movieEpisode] }
        }
        let mapping = PackFileMapper.map(files: files, series: series, corrections: fileCorrections)
        self.mapping = mapping
        let planner = PackStreamPlanner(
            mapping: mapping, pieceLength: Int64(metadata.pieceLength), order: episodeOrder, options: config.planOptions)
        self.planner = planner
        self.mode = mode

        let first: EpisodeRef
        if isMovie {
            first = StreamContent.movieEpisode
        } else if let startEpisode {
            guard planner.playableEpisodes.contains(startEpisode) else {
                throw StreamControllerError.episodeNotInPack(startEpisode)
            }
            first = startEpisode
        } else if let e = planner.playableEpisodes.first {
            first = e
        } else {
            throw StreamControllerError.noPlayableFile
        }
        let plan = planner.makePlan(start: first, mode: mode)
        guard plan.currentEpisodes.contains(first) else { throw StreamControllerError.noPlayableFile }
        self.plan = plan

        // Priorities and deadlines first, then let the engine request pieces.
        try await session.setFilePriorities(id, Self.priorityVector(plan, fileCount: metadata.files.count))
        let bits = try await session.havePieces(id)
        var have = PieceAvailability(pieceCount: metadata.pieceCount)
        for p in 0..<min(metadata.pieceCount, bits.pieceCount) where bits[p] { have.insert(p) }
        self.have = have

        let scheduler = TorrentDeadlineScheduler(
            session: session, torrent: id, plan: plan, have: have, deadlineBudgetBytes: config.deadlineBudgetBytes)
        self.scheduler = scheduler
        try await session.startDownload(id)
        await scheduler.start(playhead: 0)

        let handle = try await register(plan: plan, torrent: id, metadata: metadata)
        lastProgress = .now
        startLoops(events: events, torrent: id)
        evaluateStatus()
        return handle
    }

    // MARK: Episodes

    /// Moves playback to another episode: re-plans priorities around it, registers its file and returns
    /// the URL. Head and tail of the next episode are normally already downloaded by the rollover
    /// logic, so the diff sent to the engine is small and playback starts without a buffering gap.
    public func advance(to episode: EpisodeRef) async throws -> StreamHandle {
        guard started, !stopped, let id = torrent, let metadata, let planner, let scheduler else {
            throw StreamControllerError.notStarted
        }
        guard planner.playableEpisodes.contains(episode) else { throw StreamControllerError.episodeNotInPack(episode) }
        let newPlan = planner.makePlan(start: episode, mode: mode)
        guard newPlan.currentEpisodes.contains(episode) else { throw StreamControllerError.noPlayableFile }

        try await session.setFilePriorities(id, Self.priorityVector(newPlan, fileCount: metadata.files.count))
        plan = newPlan
        playhead = 0
        lastProgress = .now
        await scheduler.setPlan(newPlan, playhead: 0)
        let handle = try await register(plan: newPlan, torrent: id, metadata: metadata)
        evaluateStatus()
        return handle
    }

    /// The player knows where it is about to read (e.g. after a scrub, before the HTTP request).
    public func playheadMoved(to offset: Int64) async {
        guard let item = current else { return }
        await applyPlayhead(fileIndex: item.fileIndex, offset: offset)
    }

    /// Once the player knows the real duration, "seconds ahead" uses the file's true average bitrate.
    public func setMediaDuration(_ seconds: Double) {
        mediaDuration = seconds > 0 ? seconds : nil
        evaluateStatus()
    }

    /// Stops serving. The torrent keeps downloading (a stream is just a download being watched) unless
    /// `removeTorrent` is set; deadlines are cleared either way so the rest downloads at normal priority.
    public func stop(removeTorrent: Bool = false, deleteFiles: Bool = false) async {
        guard !stopped else { return }
        stopped = true
        eventLoop?.cancel()
        playheadLoop?.cancel()
        watchdog?.cancel()
        eventLoop = nil
        playheadLoop = nil
        watchdog = nil
        playheadContinuation.finish()
        await restoreTuning()
        for token in registeredTokens { await server.revoke(token: token) }
        registeredTokens.removeAll()
        if let scheduler { await scheduler.clearAll() }
        if removeTorrent, let id = torrent { try? await session.remove(id, deleteFiles: deleteFiles) }
        statusHub.finish()
        eventHub.finish()
    }

    // MARK: Registration

    private func register(plan: StreamPlan, torrent id: TorrentID, metadata: TorrentMetadata) async throws -> StreamHandle {
        guard plan.currentFiles.count == 1, let fileIndex = plan.currentFiles.first else {
            // Seam: multi-volume archives need an archive-aware byte source over the stored segments.
            throw plan.currentFiles.isEmpty ? StreamControllerError.noPlayableFile : .archiveStreamingUnsupported
        }
        let file = metadata.files[fileIndex]
        guard let map = TorrentFileByteSource.pieceMap(for: file, in: metadata) else {
            throw StreamControllerError.noPlayableFile
        }
        let relay = PlayheadRelay(continuation: playheadContinuation)
        let source = TorrentFileByteSource(
            savePath: config.savePath, file: file, pieceMap: map,
            availability: TorrentPieceAvailability(
                session: session, torrent: id, fileIndex: fileIndex, pieceMap: map, observer: relay))
        let endpoint = try await server.register(source, filename: (file.path as NSString).lastPathComponent)
        registeredTokens.append(endpoint.token)
        let item = Item(episodes: plan.currentEpisodes, fileIndex: fileIndex, map: map, url: endpoint.url)
        current = item
        return StreamHandle(
            torrent: id, episodes: item.episodes, fileIndex: fileIndex, url: endpoint.url,
            status: statusHub.subscribe(), mapping: isMovie ? nil : mapping)
    }

    // MARK: Event handling

    private func startLoops(events: AsyncStream<TorrentEvent>, torrent id: TorrentID) {
        eventLoop = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, torrent: id)
            }
        }
        let updates = playheadUpdates
        playheadLoop = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                await self.applyPlayhead(fileIndex: update.fileIndex, offset: update.offset)
            }
        }
    }

    private func handle(_ event: TorrentEvent, torrent id: TorrentID) async {
        switch event {
        case .pieceFinished(let t, let piece) where t == id:
            have.insert(piece)
            lastProgress = .now
            await scheduler?.markHave(piece)
            await refreshRateIfStale()
            evaluateStatus()
        case .hashFailed(let t, let piece) where t == id:
            eventHub.send(.pieceHashFailed(torrent: t, piece: piece))
        case .fileCompleted(let t, let file) where t == id:
            let assignment = mapping?.assignments.first { $0.fileIndex == file }
            eventHub.send(.fileCompleted(
                torrent: t, fileIndex: file, path: metadata?.files[safe: file]?.path ?? assignment?.path ?? "",
                episodes: assignment?.isPreferred == true ? assignment?.episodes ?? [] : []))
        case .finished(let t) where t == id:
            eventHub.send(.torrentFinished(t))
            await restoreTuning()  // nothing left to fetch: back to libtorrent's cheap idle cadence
        case .error(let t, let message) where t == id:
            diagnostics.append(message)
            publish(.failed("The download ran into a problem. Try another version."))
        case .fileError(let t, _, let message) where t == id:
            diagnostics.append(message)
            publish(.failed("Couldn't save the download to disk. Check that there is free space and try again."))
        case .metadataFailed(let t, let message) where t == id:
            diagnostics.append(message)
            publish(.failed(StreamControllerError.metadataTimeout.plainLanguage))
        case .removed(let t) where t == id:
            publish(.failed("This download was removed."))
        default:
            break
        }
    }

    private func applyPlayhead(fileIndex: Int, offset: Int64) async {
        guard let item = current, item.fileIndex == fileIndex, let scheduler else { return }  // stale source
        playhead = min(max(0, offset), item.map.fileLength)
        if lastStatus == .ready { lastProgress = .now }
        await scheduler.movePlayhead(to: playhead)
        evaluateStatus()
    }

    private func refreshRateIfStale() async {
        let now = ContinuousClock.now
        if let at = rateSampledAt, now - at < .seconds(1) { return }
        rateSampledAt = now
        if let id = torrent, let status = try? await session.status(id) { downloadRate = status.downloadRate }
        if let floor = config.deadlineBudgetBytes {
            let wanted = Int64(Double(downloadRate) * config.deadlineBudgetSeconds)
            await scheduler?.setBudget(min(max(floor, wanted), max(floor, config.planOptions.windowBytes)))
        }
    }

    // MARK: Status

    private func evaluateStatus() {
        guard let item = current, !stopped, lastStatus?.isTerminal != true else { return }
        let map = item.map
        let length = map.fileLength
        let head = config.planOptions.headBytes
        let playhead = min(self.playhead, length)
        let ahead = have.contiguousBytes(from: playhead, in: map)
        let headDone = have.containsAll(map.pieces(forFileRange: 0..<min(head, length)))
        let tailDone = have.containsAll(map.pieces(forFileRange: max(0, length - config.planOptions.tailBytes)..<length))
        let bps = estimatedBytesPerSecond(length: length, episodes: item.episodes.count)
        let input = ReadinessInput(
            fileLength: length, playhead: playhead, bytesAhead: ahead, headComplete: headDone, tailComplete: tailDone,
            headBytes: head, downloadRate: downloadRate, estimatedBytesPerSecond: bps)

        if config.readinessPolicy.isReady(input) {
            publish(.ready)
        } else if have.count == 0 {
            publish(.findingPeers)
            armWatchdog()
        } else {
            publish(.buffering(secondsAhead: Double(ahead) / bps, bytesAhead: ahead))
            armWatchdog()
        }
    }

    private func estimatedBytesPerSecond(length: Int64, episodes: Int) -> Double {
        if let mediaDuration { return max(1, Double(length) / mediaDuration) }
        let runtime = isMovie ? config.assumedMovieRuntime : config.assumedEpisodeRuntime
        let seconds = Double(runtime.components.seconds) * Double(max(1, episodes))
        return max(1, Double(length) / max(1, seconds))
    }

    private func publish(_ status: StreamStatus) {
        if stopped || lastStatus?.isTerminal == true || status == lastStatus { return }
        let now = ContinuousClock.now
        if case .buffering = status, case .buffering? = lastStatus, let at = lastStatusAt,
           now - at < config.minimumBufferingUpdateInterval {
            return
        }
        lastStatus = status
        lastStatusAt = now
        statusHub.send(status)
    }

    // MARK: Stall watchdog

    /// One sleeping task while data is awaited: wakes when `stallTimeout` has passed since the last
    /// piece, reports the stall once and exits. A new piece or playhead move re-arms it.
    private func armWatchdog() {
        guard watchdog == nil, !stopped else { return }
        watchdog = Task { [weak self] in await self?.watchdogLoop() }
    }

    private func watchdogLoop() async {
        defer { watchdog = nil }
        while !Task.isCancelled, !stopped {
            let due = lastProgress + config.stallTimeout
            if ContinuousClock.now < due {
                try? await Task.sleep(until: due)
                continue
            }
            guard lastStatus != .ready, lastStatus?.isTerminal != true else { return }
            var peers = 0
            if let id = torrent, let status = try? await session.status(id) { peers = status.peerCount }
            publish(.stalled(peers == 0 ? .noPeers : .slowDownload))
            return
        }
    }

    // MARK: Engine tuning

    private var tuningApplied = false

    private func applyTuning() async {
        guard !tuningApplied else { return }
        tuningApplied = true
        if let tick = config.tuning.activeTickInterval { try? await session.setInt("tick_interval", tick) }
        if config.tuning.priorityFirstPicking { try? await session.setInt("initial_picker_threshold", 0) }
    }

    private func restoreTuning() async {
        guard tuningApplied else { return }
        tuningApplied = false
        if config.tuning.activeTickInterval != nil { try? await session.setInt("tick_interval", config.tuning.idleTickInterval) }
        if config.tuning.priorityFirstPicking { try? await session.setInt("initial_picker_threshold", 4) }
    }

    // MARK: Helpers

    private static func wrap(_ error: Error) -> StreamControllerError {
        switch error {
        case let e as StreamControllerError: e
        case TorrentError.timedOut: .metadataTimeout
        default: .engine(String(describing: error))
        }
    }

    /// File priorities for libtorrent, shifted down one step (7 -> 6, ... , floor 1; 0 stays 0).
    ///
    /// libtorrent forces every piece that has a deadline to its top priority (7) and, in sequential
    /// mode, picks all top-priority pieces in an arbitrary order and only the lower ones in index order.
    /// If the current episode were also priority 7, all of it would count as "deadline" pieces and the
    /// first request wave would scatter across the whole file. Keeping 7 for the deadline window alone
    /// lets everything else follow in playback order.
    static func priorityVector(_ plan: StreamPlan, fileCount: Int) -> [UInt8] {
        (0..<fileCount).map { index -> UInt8 in
            let p = plan.priorities[index]?.rawValue ?? 0
            return p == 0 ? 0 : UInt8(max(1, p - 1))
        }
    }

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "wmv", "mpg", "mpeg", "webm", "m2ts", "ts", "ogm", "divx",
    ]

    /// The largest non-sample video file: the movie.
    private static func mainVideoFile(in files: [PackFile]) -> Int? {
        let videos = files.filter {
            videoExtensions.contains(($0.path as NSString).pathExtension.lowercased())
        }
        let real = videos.filter { !$0.path.lowercased().contains("sample") }
        return (real.isEmpty ? videos : real).max { $0.size < $1.size }?.index
    }
}

/// Hands playhead positions to the controller without blocking the HTTP response that reported them.
/// The stream keeps only the newest position, so a burst of scrubs collapses into the last one.
struct PlayheadUpdate: Sendable {
    var fileIndex: Int
    var offset: Int64
}

private struct PlayheadRelay: PlayheadObserver {
    let continuation: AsyncStream<PlayheadUpdate>.Continuation
    init(continuation: AsyncStream<PlayheadUpdate>.Continuation) {
        self.continuation = continuation
    }
    func playheadMoved(fileIndex: Int, offset: Int64) async {
        continuation.yield(PlayheadUpdate(fileIndex: fileIndex, offset: offset))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
