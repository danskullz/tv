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

            for score in ranked where !tried.contains(score.decision.id) {
                if attempts >= config.maxAttempts { break }
                try Task.checkCancellation()
                tried.insert(score.decision.id)
                attempts += 1
                emit(PlayStatus(
                    .choosing,
                    "Found \(found.releases.count) release\(found.releases.count == 1 ? "" : "s") · picked \(Self.summary(of: score.decision))",
                    attempt: attempts))
                do {
                    return try await attempt(
                        score, stage: stage, found: found, decisions: decisions, request: request, config: config,
                        attempt: attempts, emit: emit)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as AttemptFailure {
                    lastReason = failure.reason
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
        request: PlayRequest, config: PlayPipelineConfiguration, attempt number: Int,
        emit: @escaping @Sendable (PlayStatus) -> Void
    ) async throws -> PlayStream {
        let decision = score.decision
        let release = decision.candidate.release
        let grabID = UUID()
        await saveGrab(
            id: grabID, request: request, score: score, decisions: decisions, found: found, stage: stage,
            attempt: number, outcome: .grabbed, failure: nil)

        let controller = controllers.makeController()
        var infoHash = release.infoHash
        do {
            let (source, magnetPeers) = try await torrentSource(for: release)
            let (content, start) = Self.content(for: request, decision: decision)
            emit(PlayStatus(.connecting, "Connecting to peers…", attempt: number))
            let handle = try await controller.start(
                source: source, content: content, startEpisode: start, mode: config.streamMode,
                peers: magnetPeers + config.extraPeers, corrections: [:], episodeOrder: nil)
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
            await controller.stop(removeTorrent: true, deleteFiles: true)
            await saveGrab(
                id: grabID, request: request, score: score, decisions: decisions, found: found, stage: stage,
                attempt: number, outcome: .failed, failure: reason)
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
                        return .failed(reason.message)
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

    private func torrentSource(for release: IndexerRelease) async throws -> (TorrentSource, [PeerEndpoint]) {
        var magnet = release.magnetURL?.absoluteString
        if magnet == nil, let hash = release.infoHash {
            let name = release.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            magnet = "magnet:?xt=urn:btih:\(hash)&dn=\(name)"
        }
        if let url = release.downloadURL {
            do {
                let data = try await fetchTorrentFile(url)
                return (.torrentFile(data), magnet.map(Self.peers(inMagnet:)) ?? [])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if magnet == nil { throw error }
            }
        }
        guard let magnet else { throw AttemptFailure(reason: "The release has no download link.") }
        return (.magnet(magnet), Self.peers(inMagnet: magnet))
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
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 8 << 20,
            data.first == UInt8(ascii: "d")
        else { throw URLError(.badServerResponse) }
        return data
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
        found: CoordinatedSearchResult, stage: Stage, attempt: Int, outcome: Grab.Outcome, failure: String?
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

    private static func reason(for error: Error) -> String {
        switch error {
        case let e as AttemptFailure: e.reason
        case let e as StreamControllerError: e.plainLanguage
        case let e as PlayPipelineError: e.plainLanguage
        default: "The download engine could not start this release."
        }
    }
}

extension HistoryRepository {
    func appendQuietly(_ event: HistoryEvent) async {
        try? await append(event)
    }
}
