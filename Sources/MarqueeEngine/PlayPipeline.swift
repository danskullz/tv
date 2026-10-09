import Foundation
import MarqueeCore
import TorrentEngine

/// "Press Play" for a title with no local file: search the user's indexers, pick the best *streamable*
/// release, start it in streaming mode and hand back a playable URL.
///
/// Steps: build Torznab queries (ids first, then a text fallback) -> `IndexerSearchCoordinator` ->
/// parse -> `ReleaseDecisionEngine` with the title's profile -> `StreamabilityScorer` -> start the best
/// candidate with a ``StreamControlling``. When an attempt fails before it becomes playable (dead
/// torrent, metadata timeout, stall, bad file) the release is blocklisted and the next-best one is
/// tried, up to ``PlayPipelineConfiguration/maxAttempts`` times. Every pick is written to the grab log
/// with the reasoning, which is what the "Why this release?" panel shows.
public actor PlayPipeline {
    private let search: any ReleaseSearching
    private let controllers: any StreamControllerFactory
    private let grabs: any GrabRepository
    private let blocklist: any BlocklistRepository
    private let history: any HistoryRepository
    private let fetchTorrentFile: @Sendable (URL) async throws -> Data
    private let configuration: @Sendable () -> PlayPipelineConfiguration

    public init(
        search: any ReleaseSearching,
        controllers: any StreamControllerFactory,
        grabs: any GrabRepository,
        blocklist: any BlocklistRepository,
        history: any HistoryRepository,
        fetchTorrentFile: @escaping @Sendable (URL) async throws -> Data = PlayPipeline.downloadTorrentFile,
        configuration: @escaping @Sendable () -> PlayPipelineConfiguration = { PlayPipelineConfiguration() }
    ) {
        self.search = search
        self.controllers = controllers
        self.grabs = grabs
        self.blocklist = blocklist
        self.history = history
        self.fetchTorrentFile = fetchTorrentFile
        self.configuration = configuration
    }

    /// Starts a Play. Returns immediately; observe ``PlayOperation/statuses`` and await ``PlayOperation/stream()``.
    public nonisolated func begin(_ request: PlayRequest) -> PlayOperation {
        let (statuses, continuation) = AsyncStream<PlayStatus>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let task = Task<PlayStream, any Error> { [self] in
            defer { continuation.finish() }
            return try await run(request) { continuation.yield($0) }
        }
        return PlayOperation(statuses: statuses, task: task)
    }

    // MARK: Run

    private struct Stage {
        var query: TorznabQuery
        var wanted: WantedItem
        var label: String
    }

    private func run(_ request: PlayRequest, emit: @escaping @Sendable (PlayStatus) -> Void) async throws -> PlayStream {
        let config = configuration()
        let indexerCount = await search.enabledIndexerCount()
        guard indexerCount > 0 else {
            emit(PlayStatus(.failed, PlayPipelineError.noIndexers.plainLanguage))
            throw PlayPipelineError.noIndexers
        }

        var attempts = 0
        var tried = Set<String>()
        var failedHashes = Set<String>()
        var lastReason = ""
        var totalFound = 0
        var lastSummary = "nothing matched"
        var searched = 0, failedSearches = 0

        for stage in stages(for: request) {
            try Task.checkCancellation()
            if attempts >= config.maxAttempts { break }
            emit(PlayStatus(.searching, Self.searchingMessage(indexerCount), attempt: attempts + 1))
            let found = await search.search(stage.query)
            try Task.checkCancellation()
            searched = max(searched, found.outcomes.count)
            failedSearches = max(failedSearches, found.failedCount)
            totalFound += found.releases.count
            guard !found.releases.isEmpty else { continue }

            let blocked = await currentBlocklist(titleID: request.title.id)
            let candidates = found.releases.map { ReleaseCandidate(release: $0) }
            let context = DecisionContext(
                wanted: stage.wanted, profile: request.profile, formats: config.formats, blocklist: blocked,
                minimumSeeders: config.minimumSeeders, ignoreDelay: true, allowPacksForEpisodes: true)
            let decisions = ReleaseDecisionEngine.decide(candidates, in: context)
            let ranked = StreamabilityScorer.rank(
                decisions,
                input: StreamabilityInput(
                    wanted: stage.wanted, measuredThroughputBytesPerSecond: config.measuredThroughputBytesPerSecond))
            lastSummary = Self.rejectionSummary(decisions)

            // Resolve the top picks' download links concurrently before committing to attempt #1,
            // so a dead top pick is skipped without burning a full attempt timeout on it.
            let warmed = await warmSources(for: ranked, tried: tried, config: config)
            try Task.checkCancellation()

            for score in ranked where !tried.contains(score.decision.id) {
                if attempts >= config.maxAttempts { break }
                try Task.checkCancellation()
                let release = score.decision.candidate.release
                if let hash = Self.effectiveInfoHash(of: release), failedHashes.contains(hash) {
                    tried.insert(score.decision.id)
                    await saveGrab(
                        id: UUID(), request: request, score: score, decisions: decisions, found: found,
                        stage: stage, attempt: attempts + 1, outcome: .failed,
                        failure: "Skipped: the same download already failed on a higher-ranked release.")
                    continue
                }
                tried.insert(score.decision.id)
                attempts += 1
                emit(PlayStatus(
                    .choosing,
                    "Found \(found.releases.count) release\(found.releases.count == 1 ? "" : "s") · picked \(Self.summary(of: score.decision))",
                    attempt: attempts))
                do {
                    return try await attempt(
                        score, stage: stage, found: found, decisions: decisions, request: request, config: config,
                        attempt: attempts, warmed: warmed[score.decision.id], emit: emit)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as AttemptFailure {
                    lastReason = failure.reason
                    if let hash = Self.effectiveInfoHash(of: release) { failedHashes.insert(hash) }
                    if attempts < config.maxAttempts {
                        emit(PlayStatus(
                            .retrying, "That one isn't working. Trying the next best release…", attempt: attempts + 1))
                    }
                }
            }
        }

        let error: PlayPipelineError
        if attempts > 0 {
            error = .allAttemptsFailed(attempts: attempts, lastReason: lastReason)
        } else if totalFound > 0 {
            error = .nothingSuitable(found: totalFound, summary: lastSummary)
        } else {
            error = .noResults(indexersSearched: searched, indexersFailed: failedSearches)
        }
        emit(PlayStatus(.failed, error.plainLanguage, attempt: max(1, attempts)))
        throw error
    }

    // MARK: Queries

    private func stages(for request: PlayRequest) -> [Stage] {
        let t = request.title
        let runtime = t.runtimeMinutes
        switch request.scope {
        case .movie:
            let wanted = WantedItem.movie(t.name, year: t.year, runtimeMinutes: runtime, aliases: t.aliases)
            return [
                Stage(
                    query: .movie(title: t.name, year: t.year, imdbID: t.imdbID, tmdbID: t.tmdbID), wanted: wanted,
                    label: "movie by id"),
                Stage(query: .movie(title: t.name, year: t.year), wanted: wanted, label: "movie by title"),
            ]
        case .episode(let ref):
            let wanted = episodeWanted(request, ref)
            let seasonWanted = WantedItem.episode(
                t.name, season: ref.season, episodes: [ref.episode], runtimeMinutes: runtime,
                seasonEpisodeCount: seasonCount(request, ref.season), aliases: t.aliases)
            return [
                Stage(query: episodeQuery(t, ref, ids: true), wanted: wanted, label: "episode by id"),
                Stage(query: episodeQuery(t, ref, ids: false), wanted: wanted, label: "episode by title"),
                Stage(query: seasonQuery(t, ref.season, ids: true), wanted: seasonWanted, label: "season packs by id"),
                Stage(query: seasonQuery(t, ref.season, ids: false), wanted: seasonWanted, label: "season packs by title"),
            ]
        case .season(let season, let start):
            let pack = WantedItem.season(
                t.name, season: season, episodeCount: seasonCount(request, season), runtimeMinutes: runtime, aliases: t.aliases)
            let single = episodeWanted(request, start)
            return [
                Stage(query: seasonQuery(t, season, ids: true), wanted: pack, label: "season by id"),
                Stage(query: seasonQuery(t, season, ids: false), wanted: pack, label: "season by title"),
                Stage(query: episodeQuery(t, start, ids: true), wanted: single, label: "first episode by id"),
                Stage(query: episodeQuery(t, start, ids: false), wanted: single, label: "first episode by title"),
            ]
        }
    }

    private func episodeWanted(_ request: PlayRequest, _ ref: EpisodeRef) -> WantedItem {
        WantedItem.episode(
            request.title.name, season: ref.season, episodes: [ref.episode], runtimeMinutes: request.title.runtimeMinutes,
            seasonEpisodeCount: seasonCount(request, ref.season), aliases: request.title.aliases)
    }

    private func seasonCount(_ request: PlayRequest, _ season: Int) -> Int? {
        let n = request.episodes.filter { $0.ref.season == season }.count
        return n > 0 ? n : nil
    }

    private func episodeQuery(_ t: PlayTitle, _ ref: EpisodeRef, ids: Bool) -> TorznabQuery {
        .tv(
            title: t.name, season: ref.season, episode: ref.episode, imdbID: ids ? t.imdbID : nil,
            tvdbID: ids ? t.tvdbID : nil, tmdbID: ids ? t.tmdbID : nil)
    }

    private func seasonQuery(_ t: PlayTitle, _ season: Int, ids: Bool) -> TorznabQuery {
        .tv(
            title: t.name, season: season, imdbID: ids ? t.imdbID : nil, tvdbID: ids ? t.tvdbID : nil,
            tmdbID: ids ? t.tmdbID : nil)
    }

    // MARK: One attempt

    private struct AttemptFailure: Error {
        var reason: String
    }

    private func attempt(
        _ score: StreamabilityScore, stage: Stage, found: CoordinatedSearchResult, decisions: [ReleaseDecision],
        request: PlayRequest, config: PlayPipelineConfiguration, attempt number: Int, warmed: WarmSource?,
        emit: @escaping @Sendable (PlayStatus) -> Void
    ) async throws -> PlayStream {
        let decision = score.decision
        let release = decision.candidate.release
        let grabID = UUID()
        await saveGrab(
            id: grabID, request: request, score: score, decisions: decisions, found: found, stage: stage,
            attempt: number, outcome: .grabbed, failure: nil)

        let controller = controllers.makeController()
        let metadataTimeout = config.metadataTimeout(forAttempt: number)
        await controller.setMetadataTimeout(metadataTimeout)
        var infoHash = release.infoHash
        do {
            let (source, magnetPeers): (TorrentSource, [PeerEndpoint])
            switch warmed {
            case .resolved(let s, let p):
                (source, magnetPeers) = (s, p)
            case .failed(let reason):
                throw AttemptFailure(reason: reason)
            case nil:
                (source, magnetPeers) = try await resolveSource(for: release, timeout: config.linkFetchTimeout)
            }
            let (content, start) = Self.content(for: request, decision: decision)
            emit(PlayStatus(.connecting, "Connecting to peers…", attempt: number))
            let handle = try await Self.withTimeout(metadataTimeout) {
                try await controller.start(
                    source: source, content: content, startEpisode: start, mode: config.streamMode,
                    peers: magnetPeers + config.extraPeers, corrections: [:], episodeOrder: nil)
            }
            infoHash = infoHash ?? handle.torrent.hex

            let outcome = await awaitReady(
                handle, controller: controller, timeout: config.readyTimeout, attempt: number, emit: emit)
            try Task.checkCancellation()
            switch outcome {
            case .ready:
                break
            case .failed(let reason):
                throw AttemptFailure(reason: reason)
            }

            let explanation = score.explanation.text
            emit(PlayStatus(.ready, "Ready to play", attempt: number))
            await history.appendQuietly(HistoryEvent(
                type: .grabbed, entityType: .grab, entityUUID: grabID, titleId: request.title.id,
                payload: ["release": .string(release.title), "origin": .string(request.origin.rawValue)]))
            return PlayStream(
                url: handle.url, episodes: handle.episodes,
                release: ChosenRelease(
                    title: release.title, indexerName: release.indexerName, tier: decision.tier,
                    seeders: release.seeders, size: release.size, infoHash: infoHash, isPack: decision.isPack,
                    explanation: explanation, grabID: grabID),
                control: PlayStreamControl(controller: controller, torrent: handle.torrent))
        } catch is CancellationError {
            await controller.stop(removeTorrent: true, deleteFiles: true)
            throw CancellationError()
        } catch {
            let reason = Self.reason(for: error)
            let detail = Self.failureDetail(for: error, release: release)
            await controller.stop(removeTorrent: true, deleteFiles: true)
            await saveGrab(
                id: grabID, request: request, score: score, decisions: decisions, found: found, stage: stage,
                attempt: number, outcome: .failed, failure: reason, failureDetail: detail)
            await blocklistRelease(release, infoHash: infoHash, request: request, reason: reason)
            throw AttemptFailure(reason: reason)
        }
    }

    private enum ReadyOutcome: Sendable {
        case ready
        case failed(String)
    }

    private func awaitReady(
        _ handle: StreamHandle, controller: any StreamControlling, timeout: Duration, attempt: Int,
        emit: @escaping @Sendable (PlayStatus) -> Void
    ) async -> ReadyOutcome {
        let statuses = controller.statusUpdates()
        return await withTaskGroup(of: ReadyOutcome.self) { group in
            group.addTask {
                for await status in statuses {
                    switch status {
                    case .fetchingMetadata:
                        emit(PlayStatus(.connecting, "Fetching release details…", attempt: attempt, stream: status))
                    case .findingPeers:
                        emit(PlayStatus(.connecting, "Connecting to peers…", attempt: attempt, stream: status))
                    case .buffering(let seconds, _):
                        emit(PlayStatus(
                            .buffering, "Buffering \(Int(seconds.rounded(.down))) s ahead…", attempt: attempt, stream: status))
                    case .ready:
                        return .ready
                    case .stalled(let reason):
                        switch reason {
                        case .noPeers:
                            // Nobody is sharing: fail over now instead of waiting out the timeout.
                            return .failed(reason.message)
                        case .slowDownload:
                            // Peers exist but data is slow; it may still recover before the timeout.
                            emit(PlayStatus(
                                .buffering, "The download is slow. Still trying…", attempt: attempt, stream: status))
                        }
                    case .failed(let message):
                        return .failed(message)
                    }
                }
                return .failed("The stream ended before it could start.")
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failed("The release took too long to start.")
            }
            let first = await group.next() ?? .failed("The stream ended before it could start.")
            group.cancelAll()
            return first
        }
    }

    // MARK: Torrent source

    /// A pre-resolved download link from the parallel warm-up: either usable immediately or known
    /// dead, so the attempt fails over without spending another timeout on it.
    private enum WarmSource: Sendable {
        case resolved(TorrentSource, [PeerEndpoint])
        case failed(String)
    }

    /// Top-ranked candidates whose links are resolved concurrently per search stage.
    private static let warmupCount = 3

    /// Resolves download links for the top-ranked untried candidates concurrently, so attempt #1
    /// starts with its link (or its failure) already known. Link resolution only: libtorrent still
    /// runs a single torrent at a time.
    private func warmSources(
        for ranked: [StreamabilityScore], tried: Set<String>, config: PlayPipelineConfiguration
    ) async -> [String: WarmSource] {
        var out: [String: WarmSource] = [:]
        let top = ranked.filter { !tried.contains($0.decision.id) }.prefix(Self.warmupCount)
        await withTaskGroup(of: (String, WarmSource)?.self) { group in
            for score in top {
                let release = score.decision.candidate.release
                let id = score.decision.id
                let timeout = config.linkFetchTimeout
                group.addTask {
                    do {
                        let resolved = try await self.resolveSource(for: release, timeout: timeout)
                        return (id, .resolved(resolved.0, resolved.1))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return (id, .failed(Self.reason(for: error)))
                    }
                }
            }
            for await entry in group {
                if let (id, source) = entry { out[id] = source }
            }
        }
        return out
    }

    /// The torrent's identity for same-download dedup: the feed hash, else the magnet hash.
    static func effectiveInfoHash(of release: IndexerRelease) -> String? {
        if let hash = release.infoHash.flatMap(InfoHash.normalize) { return hash }
        if let magnet = release.effectiveMagnetURI { return InfoHash.fromMagnet(magnet) }
        return nil
    }

    /// Runs `body`, throwing ``TimeoutError`` when it takes longer than `timeout`. Cancellation
    /// still throws `CancellationError`.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    struct TimeoutError: Error {}

    /// Resolves how to start `release`: an explicit magnet link wins (no HTTP fetch, and Torznab
    /// `.torrent` proxy links are the flaky part), else the `.torrent` URL is downloaded with
    /// redirect handling (a `Location:` pointing at a magnet link resolves to that magnet), else
    /// a hash-derived magnet is the fallback so a dead proxy link still streams via DHT.
    func resolveSource(for release: IndexerRelease) async throws -> (TorrentSource, [PeerEndpoint]) {
        try await resolveSource(for: release, timeout: .seconds(15))
    }

    /// As above, but the `.torrent` download is bounded by `timeout`: a slow proxy link falls
    /// back to the magnet when there is one instead of stalling the attempt.
    func resolveSource(for release: IndexerRelease, timeout: Duration) async throws -> (TorrentSource, [PeerEndpoint]) {
        if let magnet = release.magnetURL?.absoluteString, IndexerRelease.isMagnetURI(magnet) {
            return (.magnet(magnet), Self.peers(inMagnet: magnet))
        }
        let fallback = release.effectiveMagnetURI
        if let url = release.downloadURL {
            do {
                let fetch = fetchTorrentFile
                let data = try await Self.withTimeout(timeout) { try await fetch(url) }
                return (.torrentFile(data), fallback.map(Self.peers(inMagnet:)) ?? [])
            } catch is CancellationError {
                throw CancellationError()
            } catch let redirect as TorrentSourceError where redirect.redirectedMagnet != nil {
                let magnet = redirect.redirectedMagnet!
                return (.magnet(magnet), Self.peers(inMagnet: magnet))
            } catch {
                if error is TimeoutError, fallback == nil {
                    throw AttemptFailure(reason: "The indexer's download link took too long to answer. Try another release.")
                }
                if let fallback { return (.magnet(fallback), Self.peers(inMagnet: fallback)) }
                throw error
            }
        }
        guard let fallback else { throw AttemptFailure(reason: "The release has no download link.") }
        return (.magnet(fallback), Self.peers(inMagnet: fallback))
    }

    private func torrentSource(for release: IndexerRelease) async throws -> (TorrentSource, [PeerEndpoint]) {
        try await resolveSource(for: release)
    }

    /// `x.pe=host:port` parameters of a magnet link (BEP 9).
    static func peers(inMagnet uri: String) -> [PeerEndpoint] {
        guard let question = uri.firstIndex(of: "?") else { return [] }
        var peers: [PeerEndpoint] = []
        for part in uri[uri.index(after: question)...].split(separator: "&") {
            guard let eq = part.firstIndex(of: "="), part[..<eq].lowercased() == "x.pe" else { continue }
            let raw = String(part[part.index(after: eq)...])
            let value = raw.removingPercentEncoding ?? raw
            guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), port > 0 else { continue }
            var host = String(value[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if !host.isEmpty { peers.append(PeerEndpoint(host: host, port: port)) }
        }
        return peers
    }

    public static let downloadTorrentFile: @Sendable (URL) async throws -> Data = { url in
        try await PlayPipeline.fetchTorrentData(from: url)
    }

    /// Largest accepted `.torrent` file (8 MiB; real ones are tens of KB).
    public static let maxTorrentBytes = 8 << 20

    /// Downloads a `.torrent` file, following HTTP -> HTTP redirects (up to 5 hops) manually so a
    /// Torznab proxy that redirects to a `magnet:` link surfaces as
    /// ``TorrentSourceError/redirectToMagnet(_:)`` instead of an opaque failure.
    public static func fetchTorrentData(from url: URL, maxRedirects: Int = 5) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TorrentSourceError.unsupportedScheme
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        let blocker = TorrentRedirectBlocker()
        let session = URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var current = url
        for _ in 0...max(0, maxRedirects) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: URLRequest(url: current))
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw TorrentSourceError.network(error)
            }
            guard let http = response as? HTTPURLResponse else { throw TorrentSourceError.notATorrent }
            if (300..<400).contains(http.statusCode) {
                let location = http.value(forHTTPHeaderField: "location")
                    ?? (http.allHeaderFields["Location"] as? String)
                    ?? (http.allHeaderFields["location"] as? String)
                guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty
                else { throw TorrentSourceError.httpStatus(http.statusCode) }
                if IndexerRelease.isMagnetURI(location) { throw TorrentSourceError.redirectToMagnet(location) }
                guard let next = URL(string: location, relativeTo: current)?.absoluteURL,
                    let nextScheme = next.scheme?.lowercased(), nextScheme == "http" || nextScheme == "https"
                else { throw TorrentSourceError.unsupportedScheme }
                current = next
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw TorrentSourceError.httpStatus(http.statusCode) }
            try Self.validateTorrentBytes(data)
            return data
        }
        throw TorrentSourceError.httpStatus(310)
    }

    /// Rejects proxy error pages (HTML/Cloudflare), oversized bodies and non-bencoded payloads.
    public static func validateTorrentBytes(_ data: Data) throws {
        guard data.count <= maxTorrentBytes else { throw TorrentSourceError.tooLarge(limit: maxTorrentBytes) }
        guard data.first == UInt8(ascii: "d") else { throw TorrentSourceError.notATorrent }
    }

    // MARK: Content

    private static func content(for request: PlayRequest, decision: ReleaseDecision) -> (StreamContent, EpisodeRef?) {
        switch request.scope {
        case .movie:
            return (.movie(title: request.title.name), nil)
        case .episode(let ref):
            return (.series(seriesContext(request, season: ref.season, including: ref)), ref)
        case .season(let season, let start):
            return (.series(seriesContext(request, season: season, including: start)), start)
        }
    }

    private static func seriesContext(_ request: PlayRequest, season: Int, including ref: EpisodeRef) -> PackSeriesContext {
        var episodes = request.episodes
        if !episodes.contains(where: { $0.ref == ref }) { episodes.append(PackEpisode(ref: ref)) }
        return PackSeriesContext(
            title: request.title.name, aliases: request.title.aliases, episodes: episodes, targetSeasons: [season])
    }

    // MARK: Decision log

    private func currentBlocklist(titleID: UUID) async -> ReleaseBlocklist {
        guard let entries = try? await blocklist.entries(titleId: titleID) else { return ReleaseBlocklist() }
        return ReleaseBlocklist(entries: entries)
    }

    private func blocklistRelease(_ release: IndexerRelease, infoHash: String?, request: PlayRequest, reason: String) async {
        let entry = BlocklistEntry(
            titleId: request.title.id, episodeId: request.episodeID, indexerId: nil, releaseTitle: release.title,
            infoHash: infoHash, reason: reason)
        try? await blocklist.add(entry)
        await history.appendQuietly(HistoryEvent(
            type: .blocklisted, entityType: .release, entityId: infoHash, titleId: request.title.id,
            payload: ["release": .string(release.title), "reason": .string(reason)]))
    }

    private func saveGrab(
        id: UUID, request: PlayRequest, score: StreamabilityScore, decisions: [ReleaseDecision],
        found: CoordinatedSearchResult, stage: Stage, attempt: Int, outcome: Grab.Outcome, failure: String?,
        failureDetail: String? = nil
    ) async {
        let decision = score.decision
        let release = decision.candidate.release
        var rejectionCounts: [String: JSONValue] = [:]
        for code in decisions.flatMap(\.rejections).map(\.code) {
            if case .int(let n)? = rejectionCounts[code] { rejectionCounts[code] = .int(n + 1) } else { rejectionCounts[code] = .int(1) }
        }
        var reason: [String: JSONValue] = [
            "headline": .string(score.explanation.headline),
            "summary": .string(Self.summary(of: decision)),
            "reasons": .array(score.explanation.reasons.map { .string($0) }),
            "engineExplanation": .string(decision.explanation.text),
            "streamabilityScore": .double(score.total),
            "streamability": .array(score.components.map {
                .object(["name": .string($0.name), "points": .double($0.points), "note": .string($0.note)])
            }),
            "profile": .string(request.profile.name),
            "quality": .string(decision.tier.displayName),
            "formatScore": .int(decision.formatScore),
            "engineRank": decision.rank.map { .int($0) } ?? .null,
            "isPack": .bool(decision.isPack),
            "attempt": .int(attempt),
            "stage": .string(stage.label),
            "indexer": .string(release.indexerName),
            "candidates": .object([
                "found": .int(found.releases.count),
                "accepted": .int(decisions.filter(\.isAccepted).count),
                "rejected": .int(decisions.filter { !$0.isAccepted }.count),
                "rejections": .object(rejectionCounts),
            ]),
        ]
        if let failure { reason["failure"] = .string(failure) }
        if let failureDetail { reason["failureDetail"] = .string(failureDetail) }
        let grab = Grab(
            id: id, titleId: request.title.id, episodeId: request.episodeID, releaseTitle: release.title,
            infoHash: release.infoHash, origin: request.origin, outcome: outcome, score: Int(score.total.rounded()),
            reason: .object(reason))
        try? await grabs.save(grab)
    }

    // MARK: Text

    static func searchingMessage(_ count: Int) -> String {
        "Searching \(count) indexer\(count == 1 ? "" : "s")…"
    }

    /// "1080p WEB-DL (312 seeders)".
    static func summary(of decision: ReleaseDecision) -> String {
        let seeders = decision.candidate.release.seeders
        let pack = decision.isPack ? " season pack" : ""
        guard let seeders else { return "\(decision.tier.displayName)\(pack)" }
        return "\(decision.tier.displayName)\(pack) (\(seeders) seeder\(seeders == 1 ? "" : "s"))"
    }

    static func rejectionSummary(_ decisions: [ReleaseDecision]) -> String {
        let counts = Dictionary(grouping: decisions.flatMap(\.rejections), by: \.code).mapValues(\.count)
        guard !counts.isEmpty else { return "nothing matched" }
        let readable: [String: String] = [
            "wrongTitle": "different title", "wrongEpisode": "different episode", "wrongYear": "different year",
            "qualityNotAllowed": "quality not allowed", "tooFewSeeders": "too few seeders", "sizeTooSmall": "too small",
            "sizeTooLarge": "too large", "blocklisted": "blocklisted", "sample": "samples", "packNotWanted": "season packs",
        ]
        return counts.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.value) \(readable[$0.key] ?? $0.key)" }.joined(separator: ", ")
    }

    static func reason(for error: Error) -> String {
        switch error {
        case let e as AttemptFailure: return e.reason
        case let e as StreamControllerError: return e.plainLanguage
        case let e as PlayPipelineError: return e.plainLanguage
        case let e as TorrentSourceError: return e.plainLanguage
        case let e as TorrentError: return reason(forTorrentError: e)
        case let e as StreamServerError: return reason(forStreamServerError: e)
        case let e as URLError: return reason(forURLError: e)
        case is TimeoutError: return StreamControllerError.metadataTimeout.plainLanguage
        default:
            let described = String(describing: error)
            let typeName = String(describing: type(of: error))
            let redacted = SecretRedactor.redact(described)
            // Link-resolution errors from the parallel work have no static dependency here;
            // match by type name so they still get a specific message with the detail attached.
            if typeName.contains("TorrentSource") || typeName.contains("LinkResolve")
                || described.contains("TorrentSourceError")
            {
                return "Couldn't get the download link for this release (\(redacted)). Try another release."
            }
            if !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "The download engine could not start this release (\(redacted)). Try another release."
            }
            return "The download engine could not start this release (\(SecretRedactor.redact(typeName))). Try another release."
        }
    }

    static func reason(forTorrentError error: TorrentError) -> String {
        switch error {
        case .timedOut:
            return "Timed out waiting for the download engine. Try another release."
        case .libtorrent(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "The download engine reported a problem. Try another release."
            }
            return "The download engine reported a problem (\(SecretRedactor.redact(trimmed))). Try another release."
        case .invalidArgument:
            return "The download request was invalid, so the engine refused it. Try another release."
        case .sessionClosed:
            return "The download engine had already closed, so this release couldn't start. Try playing again."
        case .notFound:
            return "The download disappeared before it could start. Try another release."
        case .noMetadata:
            return "Couldn't fetch the release details from the swarm. Try another release."
        }
    }

    static func reason(forStreamServerError error: StreamServerError) -> String {
        switch error {
        case .failedToStart(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Couldn't start the local streaming server. Try playing again."
            }
            return "Couldn't start the local streaming server (\(SecretRedactor.redact(trimmed))). Try playing again."
        case .notRunning:
            return "The local streaming server isn't running. Try playing again."
        }
    }

    static func reason(forURLError error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "The indexer's download link took too long to answer. Try another release."
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
            .dnsLookupFailed:
            return "Couldn't connect to the indexer's download link. Check your connection and try another release."
        default:
            return "The indexer's download link gave an unexpected answer. Try another release."
        }
    }

    /// Machine detail for the decision log: underlying error + release id + indexer + URL scheme.
    /// Never includes full URLs or query strings, so no API keys can leak.
    static func failureDetail(for error: Error, release: IndexerRelease) -> String {
        let underlying: String
        if let urlError = error as? URLError {
            underlying = "URLError(\(urlError.code.rawValue))"
        } else {
            underlying = SecretRedactor.redact(String(describing: error))
        }
        let scheme: String
        if let url = release.downloadURL { scheme = (url.scheme ?? "unknown").lowercased() }
        else if release.magnetURL != nil { scheme = "magnet" }
        else { scheme = "none" }
        let indexer = release.indexerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SecretRedactor.redact(
            "\(underlying) | release: \(release.id) | indexer: \(indexer.isEmpty ? "unknown" : indexer) | link: \(scheme)")
    }
}

// MARK: - Torrent link resolution

/// Typed failures from `.torrent` link resolution, so the pipeline can tell a dead proxy link
/// (try the next release) from a blocked indexer (tell the user) instead of one generic message.
public enum TorrentSourceError: Error, Sendable, Equatable {
    /// Not an `http(s)` URL (e.g. a `magnet:` link passed to the file downloader).
    case unsupportedScheme
    /// The server answered with a non-2xx status (after following redirects).
    case httpStatus(Int)
    /// The body is not a torrent: an HTML error/Cloudflare page or other non-bencoded payload.
    case notATorrent
    /// The body is larger than any real `.torrent` file.
    case tooLarge(limit: Int)
    /// The `.torrent` URL redirects to a magnet link: start this instead of downloading.
    case redirectToMagnet(String)
    /// The host could not be reached at all.
    case network(URLError)

    /// The magnet link when this error is a magnet redirect, else nil.
    public var redirectedMagnet: String? {
        if case .redirectToMagnet(let uri) = self { return uri }
        return nil
    }

    /// Plain-language text for the UI and blocklist log.
    public var plainLanguage: String {
        switch self {
        case .unsupportedScheme:
            return "The release link isn't a supported download link. Try another release."
        case .httpStatus(let code):
            return "The indexer's download link failed (HTTP \(code)). Try another release."
        case .notATorrent:
            return "The indexer's download wasn't a torrent file — it may need login or be blocked. Try another release."
        case .tooLarge:
            return "The indexer's download was too large to be a torrent file. Try another release."
        case .redirectToMagnet:
            return "The indexer's download link points at a magnet link. Try another release."
        case .network(let error):
            return PlayPipeline.reason(forURLError: error)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unsupportedScheme, .unsupportedScheme): return true
        case (.httpStatus(let a), .httpStatus(let b)): return a == b
        case (.notATorrent, .notATorrent): return true
        case (.tooLarge(let a), .tooLarge(let b)): return a == b
        case (.redirectToMagnet(let a), .redirectToMagnet(let b)): return a == b
        case (.network(let a), .network(let b)): return a.code == b.code
        default: return false
        }
    }
}

/// Blocks URLSession's automatic redirect following so `fetchTorrentData` sees each 3xx itself.
final class TorrentRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension HistoryRepository {
    func appendQuietly(_ event: HistoryEvent) async {
        try? await append(event)
    }
}
