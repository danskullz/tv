import Foundation
import MarqueeCore
import Synchronization
import Testing
import TorrentEngine

@testable import MarqueeEngine

// MARK: - Test support (prefixed `pipeline` so it cannot collide with other files)

/// Serves the demo caps and a feed computed per query; records every search request.
private final class PipelineTransport: IndexerTransport, Sendable {
    private let releases: @Sendable (_ query: [String: String]) -> [DemoRelease]
    private let log = Mutex<[[String: String]]>([])

    init(releases: @escaping @Sendable ([String: String]) -> [DemoRelease]) { self.releases = releases }

    var searches: [[String: String]] { log.withLock { $0 } }

    func send(_ request: IndexerHTTPRequest) async throws -> IndexerHTTPResponse {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if query["t"] == "caps" { return IndexerHTTPResponse(statusCode: 200, body: Data(TorznabFixtureServer.capsXML.utf8)) }
        log.withLock { $0.append(query) }
        return IndexerHTTPResponse(statusCode: 200, body: Data(TorznabFixtureServer.feed(releases(query)).utf8))
    }
}

private func pipelineRelease(
    _ title: String, seeders: Int, size: Int64 = 1_500_000_000, season: Int? = 1, episode: Int? = 1
) -> DemoRelease {
    let hash = String(format: "%040x", abs(title.hashValue) & 0xFFFF_FFFF)
    return DemoRelease(
        kind: .tv, title: title, guid: title, infoHash: hash, size: size, seeders: seeders,
        magnet: "magnet:?xt=urn:btih:\(hash)&dn=\(title)&x.pe=127.0.0.1:6881", season: season, episode: episode)
}

private struct PipelineStart: Sendable {
    var source: TorrentSource
    var content: StreamContent
    var episode: EpisodeRef?
    var peers: [PeerEndpoint]
}

/// A controller whose behaviour is scripted per attempt.
private final class PipelineFakeController: StreamControlling, Sendable {
    enum Script: Sendable {
        case ready
        case failStart(StreamControllerError)
        case stall
    }

    let script: Script
    let onStart: @Sendable (PipelineStart) -> Void
    private let statuses = Broadcaster<StreamStatus>(replayLatest: true, policy: .unbounded)
    private let stops = Mutex<[Bool]>([])

    init(script: Script, onStart: @escaping @Sendable (PipelineStart) -> Void) {
        self.script = script
        self.onStart = onStart
    }

    var removedOnStop: Bool { stops.withLock { $0.last ?? false } }

    func start(
        source: TorrentSource, content: StreamContent, startEpisode: EpisodeRef?, mode: StreamMode,
        peers: [PeerEndpoint], corrections: [Int: [EpisodeRef]], episodeOrder: [EpisodeRef]?
    ) async throws -> StreamHandle {
        onStart(PipelineStart(source: source, content: content, episode: startEpisode, peers: peers))
        switch script {
        case .failStart(let error):
            throw error
        case .ready:
            statuses.send(.findingPeers)
            statuses.send(.buffering(secondsAhead: 2, bytesAhead: 1000))
            statuses.send(.ready)
        case .stall:
            statuses.send(.findingPeers)
            statuses.send(.stalled(.noPeers))
        }
        return StreamHandle(
            torrent: TorrentID(hex: String(repeating: "ab", count: 20)), episodes: startEpisode.map { [$0] } ?? [],
            fileIndex: 0, url: URL(string: "http://127.0.0.1:1/token/file.mkv")!, status: statuses.subscribe(), mapping: nil)
    }

    func advance(to episode: EpisodeRef) async throws -> StreamHandle { throw StreamControllerError.notStarted }
    func setMediaDuration(_ seconds: Double) async {}
    func playheadMoved(to offset: Int64) async {}
    func stop(removeTorrent: Bool, deleteFiles: Bool) async { stops.withLock { $0.append(removeTorrent) } }
    func statusUpdates() -> AsyncStream<StreamStatus> { statuses.subscribe() }
    func events() -> AsyncStream<StreamControllerEvent> { AsyncStream { $0.finish() } }
}

private final class PipelineFactory: StreamControllerFactory, Sendable {
    private let scripts: Mutex<[PipelineFakeController.Script]>
    let created = Mutex<[PipelineFakeController]>([])
    let starts = Mutex<[PipelineStart]>([])

    init(_ scripts: [PipelineFakeController.Script]) { self.scripts = Mutex(scripts) }

    func makeController() -> any StreamControlling {
        let script = scripts.withLock { $0.isEmpty ? .failStart(.metadataTimeout) : $0.removeFirst() }
        let controller = PipelineFakeController(script: script) { [self] start in
            starts.withLock { $0.append(start) }
        }
        created.withLock { $0.append(controller) }
        return controller
    }
}

private struct PipelineRig {
    let pipeline: PlayPipeline
    let transport: PipelineTransport
    let factory: PipelineFactory
    let database: AppDatabase
    let title: Title
}

private func pipelineRig(
    scripts: [PipelineFakeController.Script], indexers: Int = 1, maxAttempts: Int = 4,
    releases: @escaping @Sendable ([String: String]) -> [DemoRelease]
) async throws -> PipelineRig {
    let database = try AppDatabase.inMemory()
    let title = try await GRDBLibraryRepository(database).add(
        Title(kind: .series, tvdbId: 99_000_001, title: "Marquee Test Pattern", year: 2026), seasons: [])
    let transport = PipelineTransport(releases: releases)
    let definitions = (0..<indexers).map { i in
        IndexerDefinition(
            name: "Indexer \(i)", baseURL: URL(string: "https://indexer\(i).example.invalid")!, rateLimit: .unlimited)
    }
    let secrets = InMemorySecretStore()
    for d in definitions { try secrets.set("k", account: d.apiKeyAccount) }
    let coordinator = IndexerSearchCoordinator(secrets: secrets, transport: transport)
    await coordinator.setIndexers(definitions)
    let factory = PipelineFactory(scripts)
    let pipeline = PlayPipeline(
        search: CoordinatorSearcher(coordinator), controllers: factory, grabs: GRDBGrabRepository(database),
        blocklist: GRDBBlocklistRepository(database), history: GRDBHistoryRepository(database),
        fetchTorrentFile: { _ in throw URLError(.badURL) },
        configuration: { PlayPipelineConfiguration(maxAttempts: maxAttempts, readyTimeout: .seconds(5)) })
    return PipelineRig(pipeline: pipeline, transport: transport, factory: factory, database: database, title: title)
}

private func pipelineRequest(_ title: Title, scope: PlayScope = .episode(EpisodeRef(season: 1, episode: 1))) -> PlayRequest {
    PlayRequest(
        title: PlayTitle(id: title.id, kind: .series, name: title.title, year: 2026, tvdbID: 99_000_001),
        scope: scope, profile: .balanced,
        episodes: (1...3).map { PackEpisode(ref: EpisodeRef(season: 1, episode: $0)) })
}

private func pipelineCollect(_ operation: PlayOperation) -> Task<[PlayStatus], Never> {
    Task {
        var all: [PlayStatus] = []
        for await s in operation.statuses { all.append(s) }
        return all
    }
}

private let pipelineTop = "Marquee.Test.Pattern.S01E01.1080p.WEB-DL.H264-AAA"
private let pipelineSecond = "Marquee.Test.Pattern.S01E01.720p.WEB-DL.H264-BBB"

private let pipelineCatalogue: @Sendable ([String: String]) -> [DemoRelease] = { _ in
    [
        pipelineRelease(pipelineSecond, seeders: 40),
        pipelineRelease(pipelineTop, seeders: 312),
        pipelineRelease("Marquee.Test.Pattern.S01E01.480p.HDTV.x264-JUNK", seeders: 900),
    ]
}

// MARK: - Tests

@Suite("PlayPipeline")
struct PlayPipelineTests {
    @Test("picks the best streamable release, reports plain-language progress and logs the decision")
    func picksBest() async throws {
        let rig = try await pipelineRig(scripts: [.ready], releases: pipelineCatalogue)
        let op = rig.pipeline.begin(pipelineRequest(rig.title))
        let statuses = pipelineCollect(op)
        let stream = try await op.stream()
        let messages = await statuses.value.map(\.message)

        #expect(stream.release.title == pipelineTop)
        #expect(stream.release.tier == .webDL1080p)
        #expect(stream.url.lastPathComponent == "file.mkv")
        #expect(messages.first == "Searching 1 indexer…")
        #expect(messages.contains("Found 3 releases · picked 1080p WEB-DL (312 seeders)"), "\(messages)")
        #expect(messages.contains("Connecting to peers…"))
        #expect(messages.last == "Ready to play")

        let grabs = try await GRDBGrabRepository(rig.database).grabs(titleId: rig.title.id, limit: 10)
        #expect(grabs.count == 1)
        let grab = try #require(grabs.first)
        #expect(grab.id == stream.release.grabID)
        #expect(grab.outcome == .grabbed && grab.origin == .stream)
        #expect(grab.releaseTitle == pipelineTop)
        #expect(grab.reason["headline"] == "Best to stream")
        #expect(grab.reason["profile"] == "Balanced")
        #expect(grab.reason["attempt"] == 1)
        if case .array(let parts)? = grab.reason["streamability"] {
            #expect(!parts.isEmpty)
        } else {
            Issue.record("no streamability breakdown")
        }
        #expect(grab.reason["candidates"]?["found"] == 3)
        #expect(grab.reason["candidates"]?["rejections"]?["qualityNotAllowed"] == 1, "the 480p release is rejected by the profile")
    }

    @Test("sends the magnet's peer hint and a series context to the controller")
    func startsController() async throws {
        let rig = try await pipelineRig(scripts: [.ready], releases: pipelineCatalogue)
        _ = try await rig.pipeline.begin(pipelineRequest(rig.title)).stream()
        let start = try #require(rig.factory.starts.withLock { $0.first })
        guard case .magnet(let uri) = start.source else {
            Issue.record("expected a magnet")
            return
        }
        #expect(uri.contains("x.pe=127.0.0.1:6881"))
        if case .series = start.content {} else { Issue.record("expected series content") }
        #expect(start.episode == EpisodeRef(season: 1, episode: 1))
        #expect(start.peers == [PeerEndpoint(host: "127.0.0.1", port: 6881)])
    }

    @Test("a dead release is blocklisted and the next best is tried automatically")
    func fallsBack() async throws {
        let rig = try await pipelineRig(scripts: [.failStart(.metadataTimeout), .ready], releases: pipelineCatalogue)
        let op = rig.pipeline.begin(pipelineRequest(rig.title))
        let statuses = pipelineCollect(op)
        let stream = try await op.stream()
        let messages = await statuses.value.map(\.message)

        #expect(stream.release.title == pipelineSecond)
        #expect(messages.contains { $0.contains("Trying the next best release") }, "\(messages)")
        #expect(messages.contains("Found 3 releases · picked 720p WEB-DL (40 seeders)"), "\(messages)")

        let blocked = try await GRDBBlocklistRepository(rig.database).entries(titleId: rig.title.id)
        #expect(blocked.map(\.releaseTitle) == [pipelineTop])
        #expect(blocked.first?.reason == StreamControllerError.metadataTimeout.plainLanguage)
        let grabs = try await GRDBGrabRepository(rig.database).grabs(titleId: rig.title.id, limit: 10)
        #expect(Set(grabs.map(\.outcome)) == [.failed, .grabbed])
        let failed = try #require(grabs.first { $0.outcome == .failed })
        #expect(failed.releaseTitle == pipelineTop)
        #expect(failed.reason["failure"] != nil)
        #expect(rig.factory.created.withLock { $0.first?.removedOnStop } == true, "the failed torrent is removed")
    }

    @Test("a stall before the stream is ready counts as a failure")
    func stallFails() async throws {
        let rig = try await pipelineRig(scripts: [.stall, .ready], releases: pipelineCatalogue)
        let stream = try await rig.pipeline.begin(pipelineRequest(rig.title)).stream()
        #expect(stream.release.title == pipelineSecond)
        let blocked = try await GRDBBlocklistRepository(rig.database).entries(titleId: rig.title.id)
        #expect(blocked.first?.reason == StallReason.noPeers.message)
    }

    @Test("gives up after the attempt budget with a plain-language error")
    func allFail() async throws {
        let rig = try await pipelineRig(scripts: [], maxAttempts: 2, releases: pipelineCatalogue)
        let op = rig.pipeline.begin(pipelineRequest(rig.title))
        let statuses = pipelineCollect(op)
        await #expect(
            throws: PlayPipelineError.allAttemptsFailed(
                attempts: 2, lastReason: StreamControllerError.metadataTimeout.plainLanguage)
        ) {
            _ = try await op.stream()
        }
        let last = await statuses.value.last
        #expect(last?.phase == .failed)
        #expect(last?.message.contains("Tried 2 releases") == true)
        #expect(rig.factory.created.withLock { $0.count } == 2)
    }

    @Test("blocklisted releases are skipped on the next Play")
    func blocklistPersists() async throws {
        let rig = try await pipelineRig(scripts: [], maxAttempts: 1, releases: pipelineCatalogue)
        _ = try? await rig.pipeline.begin(pipelineRequest(rig.title)).stream()
        _ = try? await rig.pipeline.begin(pipelineRequest(rig.title)).stream()
        let titles = try await GRDBBlocklistRepository(rig.database).entries(titleId: rig.title.id).map(\.releaseTitle)
        #expect(titles.contains(pipelineTop) && titles.contains(pipelineSecond), "second Play moved on to the next release: \(titles)")
    }

    @Test("without indexers it says so")
    func noIndexers() async throws {
        let rig = try await pipelineRig(scripts: [.ready], indexers: 0, releases: pipelineCatalogue)
        await #expect(throws: PlayPipelineError.noIndexers) { _ = try await rig.pipeline.begin(pipelineRequest(rig.title)).stream() }
    }

    @Test("an empty search is reported with every query variant tried")
    func noResults() async throws {
        let rig = try await pipelineRig(scripts: [.ready]) { _ in [] }
        let op = rig.pipeline.begin(pipelineRequest(rig.title))
        await #expect(throws: PlayPipelineError.noResults(indexersSearched: 1, indexersFailed: 0)) { _ = try await op.stream() }
        // Episode scope: id query, title query, then both season-pack queries.
        #expect(rig.transport.searches.count == 4)
    }

    @Test("ids are tried first and the title text is the fallback")
    func queryStages() async throws {
        let rig = try await pipelineRig(scripts: [.ready]) { query in
            // Only the text query finds anything.
            query["tvdbid"] == nil ? [pipelineRelease(pipelineTop, seeders: 50)] : []
        }
        let stream = try await rig.pipeline.begin(pipelineRequest(rig.title)).stream()
        #expect(stream.release.title == pipelineTop)
        let searches = rig.transport.searches
        #expect(searches.count == 2)
        #expect(
            searches[0]["t"] == "tvsearch" && searches[0]["tvdbid"] == "99000001" && searches[0]["season"] == "1"
                && searches[0]["ep"] == "1")
        #expect(searches[1]["q"] == "Marquee Test Pattern" && searches[1]["tvdbid"] == nil)
    }

    @Test("a season request prefers a healthy complete pack and starts at the chosen episode")
    func seasonPrefersPack() async throws {
        let packName = "Marquee.Test.Pattern.S01.720p.WEB-DL.H264-PACK"
        let rig = try await pipelineRig(scripts: [.ready]) { query in
            query["ep"] == nil
                ? [
                    pipelineRelease(packName, seeders: 60, size: 900_000_000, season: 1, episode: nil),
                    pipelineRelease(pipelineTop, seeders: 70),
                ] : []
        }
        let request = pipelineRequest(rig.title, scope: .season(1, startingAt: EpisodeRef(season: 1, episode: 2)))
        let stream = try await rig.pipeline.begin(request).stream()
        #expect(stream.release.title == packName)
        #expect(stream.release.isPack)
        let start = try #require(rig.factory.starts.withLock { $0.first })
        #expect(start.episode == EpisodeRef(season: 1, episode: 2))
    }

    @Test("magnet x.pe peers are parsed")
    func magnetPeers() {
        let peers = PlayPipeline.peers(inMagnet: "magnet:?xt=urn:btih:abc&x.pe=127.0.0.1:6881&x.pe=%5B%3A%3A1%5D:7000&dn=x")
        #expect(peers == [PeerEndpoint(host: "127.0.0.1", port: 6881), PeerEndpoint(host: "::1", port: 7000)])
    }

    @Test("cancelling stops the Play")
    func cancel() async throws {
        let rig = try await pipelineRig(scripts: [.stall], releases: pipelineCatalogue)
        let op = rig.pipeline.begin(pipelineRequest(rig.title))
        op.cancel()
        await #expect(throws: (any Error).self) { _ = try await op.stream() }
    }
}
