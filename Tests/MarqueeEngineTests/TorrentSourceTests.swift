import Foundation
import MarqueeCore
import Synchronization
import Testing
import TorrentEngine

@testable import MarqueeEngine

// MARK: - Support (torrentSource prefix; file-private so nothing collides)

// Minimal valid bencoded torrent payload (only the leading 'd' matters to validation).
private let torrentSourceGoodBytes = Data("d8:announce7:x.local4:infod6:lengthi1eee".utf8)
private let torrentSourceHash = "0123456789abcdef0123456789abcdef01234567"
private let torrentSourceMagnet = "magnet:?xt=urn:btih:\(torrentSourceHash)&dn=Show&x.pe=127.0.0.1:6881"

private func torrentSourceRelease(
    title: String = "Show.S01E01.1080p.WEB-DL-GRP",
    downloadURL: URL? = nil,
    magnetURL: URL? = nil,
    infoHash: String? = nil
) -> IndexerRelease {
    IndexerRelease(
        indexerID: UUID(), indexerName: "Test", title: title, guid: title,
        downloadURL: downloadURL, magnetURL: magnetURL, infoHash: infoHash,
        size: 1_500_000_000, seeders: 50, categories: [5040])
}

private func torrentSourceCatch(_ work: () async throws -> Void) async -> (any Error)? {
    do {
        try await work()
        return nil
    } catch {
        return error
    }
}

private final class TorrentSourceCounter: Sendable {
    private let count = Mutex(0)
    @Sendable func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private struct TorrentSourceStubSearch: ReleaseSearching {
    var releases: [IndexerRelease] = []
    func search(_ query: TorznabQuery) async -> CoordinatedSearchResult {
        CoordinatedSearchResult(releases: releases)
    }
    func enabledIndexerCount() async -> Int { 1 }
}

private final class TorrentSourceNeverController: StreamControlling {
    func start(
        source: TorrentSource, content: StreamContent, startEpisode: EpisodeRef?, mode: StreamMode,
        peers: [PeerEndpoint], corrections: [Int: [EpisodeRef]], episodeOrder: [EpisodeRef]?
    ) async throws -> StreamHandle { throw StreamControllerError.notStarted }
    func advance(to episode: EpisodeRef) async throws -> StreamHandle { throw StreamControllerError.notStarted }
    func setMediaDuration(_ seconds: Double) async {}
    func playheadMoved(to offset: Int64) async {}
    func stop(removeTorrent: Bool, deleteFiles: Bool) async {}
    nonisolated func statusUpdates() -> AsyncStream<StreamStatus> { AsyncStream { $0.finish() } }
    nonisolated func events() -> AsyncStream<StreamControllerEvent> { AsyncStream { $0.finish() } }
}

private struct TorrentSourceStubFactory: StreamControllerFactory {
    func makeController() -> any StreamControlling { TorrentSourceNeverController() }
}

private func torrentSourcePipeline(
    fetch: @escaping @Sendable (URL) async throws -> Data
) async throws -> PlayPipeline {
    let database = try AppDatabase.inMemory()
    return PlayPipeline(
        search: TorrentSourceStubSearch(), controllers: TorrentSourceStubFactory(),
        grabs: GRDBGrabRepository(database), blocklist: GRDBBlocklistRepository(database),
        history: GRDBHistoryRepository(database), fetchTorrentFile: fetch,
        configuration: { PlayPipelineConfiguration(readyTimeout: .seconds(5)) })
}

// MARK: - Validation (pure, no network)

@Suite("TorrentSourceValidation")
struct TorrentSourceValidationTests {
    @Test("bencoded bytes pass, HTML and junk are rejected")
    func validation() throws {
        try PlayPipeline.validateTorrentBytes(torrentSourceGoodBytes)
        #expect(throws: TorrentSourceError.notATorrent) {
            try PlayPipeline.validateTorrentBytes(Data("<html><body>Just a moment…</body></html>".utf8))
        }
        #expect(throws: TorrentSourceError.notATorrent) {
            try PlayPipeline.validateTorrentBytes(Data("not a torrent".utf8))
        }
        #expect(throws: TorrentSourceError.notATorrent) {
            try PlayPipeline.validateTorrentBytes(Data())
        }
    }

    @Test("oversized bodies are rejected at the 8 MiB limit")
    func tooLarge() throws {
        var justUnder = Data(count: PlayPipeline.maxTorrentBytes)
        justUnder[0] = UInt8(ascii: "d")
        try PlayPipeline.validateTorrentBytes(justUnder)
        #expect(throws: TorrentSourceError.tooLarge(limit: PlayPipeline.maxTorrentBytes)) {
            try PlayPipeline.validateTorrentBytes(Data(count: PlayPipeline.maxTorrentBytes + 1))
        }
    }

    @Test("every case has a specific message, not the generic engine failure")
    func messages() {
        #expect(PlayPipeline.reason(for: TorrentSourceError.httpStatus(404)).contains("HTTP 404"))
        #expect(PlayPipeline.reason(for: TorrentSourceError.notATorrent).contains("torrent file"))
        #expect(PlayPipeline.reason(for: TorrentSourceError.tooLarge(limit: 8)).contains("too large"))
        #expect(PlayPipeline.reason(for: TorrentSourceError.unsupportedScheme).contains("supported"))
        #expect(PlayPipeline.reason(for: TorrentSourceError.network(URLError(.timedOut))).contains("too long"))
        // ATS refuses a plain-http link before any bytes move; that must not read as a generic
        // "unexpected answer" (it hid the real cause of every LimeTorrents failure).
        #expect(
            PlayPipeline.reason(for: TorrentSourceError.network(URLError(.appTransportSecurityRequiresSecureConnection)))
                .contains("http"))
        // Anything still unclassified names its code rather than swallowing it.
        #expect(PlayPipeline.reason(for: TorrentSourceError.network(URLError(.badServerResponse)))
            .contains("\(URLError.Code.badServerResponse.rawValue)"))
        for error in [
            TorrentSourceError.httpStatus(404), .notATorrent, .unsupportedScheme,
            .tooLarge(limit: 8), .network(URLError(.timedOut)),
        ] as [TorrentSourceError] {
            #expect(!PlayPipeline.reason(for: error).contains("download engine"))
        }
    }

    @Test("magnet helpers spot magnets and synthesize them from hashes")
    func magnetHelpers() {
        #expect(IndexerRelease.isMagnetURI(torrentSourceMagnet))
        #expect(IndexerRelease.isMagnetURI("https://proxy.example/dl?xt=urn:btih:\(torrentSourceHash)"))
        #expect(!IndexerRelease.isMagnetURI("https://indexer.example/api?t=get&id=1"))
        let release = torrentSourceRelease(infoHash: torrentSourceHash)
        #expect(release.effectiveMagnetURI?.contains(torrentSourceHash) == true)
        #expect(torrentSourceRelease().effectiveMagnetURI == nil)
    }
}

// MARK: - HTTP download (loopback, no live network)

@Suite("TorrentDownload")
struct TorrentDownloadTests {
    private func torrentSourceServer(_ handler: @escaping @Sendable (LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response)
        async throws -> (LoopbackHTTPServer, URL)
    {
        let server = LoopbackHTTPServer(handler: handler)
        let port = try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    @Test("a magnet redirect surfaces as redirectToMagnet instead of failing")
    func redirectToMagnet() async throws {
        let (server, base) = try await torrentSourceServer { _ in .redirect(to: torrentSourceMagnet) }
        defer { server.stop() }
        let error = await torrentSourceCatch {
            _ = try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("file.torrent"))
        }
        #expect((error as? TorrentSourceError) == .redirectToMagnet(torrentSourceMagnet))
    }

    @Test("an https Location carrying xt=urn:btih is also a magnet redirect")
    func redirectWithHashParam() async throws {
        let target = "https://other.example.invalid/r?xt=urn:btih:\(torrentSourceHash)&dn=x"
        let (server, base) = try await torrentSourceServer { _ in .redirect(to: target) }
        defer { server.stop() }
        let error = await torrentSourceCatch {
            _ = try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("file.torrent"))
        }
        #expect((error as? TorrentSourceError) == .redirectToMagnet(target))
    }

    @Test("http-to-http redirects are followed")
    func redirectChain() async throws {
        let (server, base) = try await torrentSourceServer { request in
            request.path == "/b"
                ? LoopbackHTTPServer.Response(status: 200, contentType: "application/x-bittorrent", body: torrentSourceGoodBytes)
                : .redirect(to: "/b")
        }
        defer { server.stop() }
        let data = try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("a"))
        #expect(data == torrentSourceGoodBytes)
    }

    @Test("redirects stop after the hop budget")
    func redirectBudget() async throws {
        let (server, base) = try await torrentSourceServer { request in .redirect(to: request.path + "/x") }
        defer { server.stop() }
        let error = await torrentSourceCatch {
            _ = try await PlayPipeline.fetchTorrentData(from: base.appendingPathComponent("a"), maxRedirects: 1)
        }
        #expect((error as? TorrentSourceError) == .httpStatus(310))
    }

    @Test("an HTML page is rejected, not passed off as a torrent")
    func htmlRejected() async throws {
        let (server, base) = try await torrentSourceServer { _ in
            LoopbackHTTPServer.Response(
                status: 200, contentType: "text/html",
                body: Data("<html><body>Checking your browser…</body></html>".utf8))
        }
        defer { server.stop() }
        await #expect(throws: TorrentSourceError.notATorrent) {
            try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("file.torrent"))
        }
    }

    /// The ATS retry is driven by a real transport refusal, which a loopback server cannot
    /// reproduce; what this pins down is that a plain-http URL is still fetched directly rather
    /// than being rewritten, so http-only indexers keep working.
    @Test("a plain-http torrent link is fetched over http, not rewritten")
    func httpLinkIsNotRewritten() async throws {
        let (server, base) = try await torrentSourceServer { _ in
            LoopbackHTTPServer.Response(
                status: 200, contentType: "application/x-bittorrent", body: torrentSourceGoodBytes)
        }
        defer { server.stop() }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        #expect(components != nil)
        components?.scheme = "http"
        let httpBase = components?.url ?? base
        let data = try await PlayPipeline.downloadTorrentFile(httpBase.appendingPathComponent("file.torrent"))
        #expect(data == torrentSourceGoodBytes)
    }

    @Test("error statuses are typed")
    func statuses() async throws {
        let (server, base) = try await torrentSourceServer { request in
            switch request.path {
            case "/missing": LoopbackHTTPServer.Response(status: 404, contentType: "text/plain", body: Data("no".utf8))
            case "/junk": LoopbackHTTPServer.Response(status: 200, contentType: "text/plain", body: Data("junk".utf8))
            default: LoopbackHTTPServer.Response(status: 200, contentType: "application/x-bittorrent", body: torrentSourceGoodBytes)
            }
        }
        defer { server.stop() }
        await #expect(throws: TorrentSourceError.httpStatus(404)) {
            try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("missing"))
        }
        await #expect(throws: TorrentSourceError.notATorrent) {
            try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("junk"))
        }
        let data = try await PlayPipeline.downloadTorrentFile(base.appendingPathComponent("ok"))
        #expect(data == torrentSourceGoodBytes)
    }

    @Test("non-http schemes and unreachable hosts are typed")
    func schemesAndNetwork() async throws {
        await #expect(throws: TorrentSourceError.unsupportedScheme) {
            try await PlayPipeline.downloadTorrentFile(URL(string: torrentSourceMagnet)!)
        }
        await #expect(throws: TorrentSourceError.unsupportedScheme) {
            try await PlayPipeline.downloadTorrentFile(URL(string: "ftp://example.invalid/file.torrent")!)
        }
        let error = await torrentSourceCatch {
            _ = try await PlayPipeline.downloadTorrentFile(URL(string: "http://127.0.0.1:1/file.torrent")!)
        }
        guard case .network = (error as? TorrentSourceError) else {
            Issue.record("expected .network, got \(String(describing: error))")
            return
        }
    }
}

// MARK: - resolveSource preference and fallback

@Suite("ResolveSource")
struct ResolveSourceTests {
    @Test("a magnet-only release never touches HTTP")
    func magnetOnly() async throws {
        let counter = TorrentSourceCounter()
        let pipeline = try await torrentSourcePipeline { _ in
            counter.increment()
            throw URLError(.badURL)
        }
        let release = torrentSourceRelease(magnetURL: URL(string: torrentSourceMagnet))
        let (source, peers) = try await pipeline.resolveSource(for: release)
        guard case .magnet(let uri) = source else {
            Issue.record("expected magnet, got \(source)")
            return
        }
        #expect(uri == torrentSourceMagnet)
        #expect(peers == [PeerEndpoint(host: "127.0.0.1", port: 6881)])
        #expect(counter.value == 0)
    }

    @Test("an explicit magnet wins over a .torrent URL")
    func prefersMagnet() async throws {
        let counter = TorrentSourceCounter()
        let pipeline = try await torrentSourcePipeline { _ in
            counter.increment()
            return torrentSourceGoodBytes
        }
        let release = torrentSourceRelease(
            downloadURL: URL(string: "https://indexer.example.invalid/file.torrent"),
            magnetURL: URL(string: torrentSourceMagnet))
        let (source, _) = try await pipeline.resolveSource(for: release)
        guard case .magnet(let uri) = source else {
            Issue.record("expected magnet, got \(source)")
            return
        }
        #expect(uri == torrentSourceMagnet)
        #expect(counter.value == 0)
    }

    @Test("a torrent-only release downloads the file")
    func torrentOnly() async throws {
        let pipeline = try await torrentSourcePipeline { _ in torrentSourceGoodBytes }
        let release = torrentSourceRelease(downloadURL: URL(string: "https://indexer.example.invalid/file.torrent"))
        let (source, peers) = try await pipeline.resolveSource(for: release)
        guard case .torrentFile(let data) = source else {
            Issue.record("expected torrentFile, got \(source)")
            return
        }
        #expect(data == torrentSourceGoodBytes)
        #expect(peers.isEmpty)
    }

    @Test("a magnet redirect from the fetch becomes the source")
    func redirectBecomesMagnet() async throws {
        let pipeline = try await torrentSourcePipeline { _ in throw TorrentSourceError.redirectToMagnet(torrentSourceMagnet) }
        let release = torrentSourceRelease(downloadURL: URL(string: "https://indexer.example.invalid/file.torrent"))
        let (source, peers) = try await pipeline.resolveSource(for: release)
        guard case .magnet(let uri) = source else {
            Issue.record("expected magnet, got \(source)")
            return
        }
        #expect(uri == torrentSourceMagnet)
        #expect(peers == [PeerEndpoint(host: "127.0.0.1", port: 6881)])
    }

    @Test("a dead proxy link falls back to the hash-derived magnet")
    func fallsBackToHash() async throws {
        let pipeline = try await torrentSourcePipeline { _ in throw TorrentSourceError.httpStatus(404) }
        let release = torrentSourceRelease(
            downloadURL: URL(string: "https://indexer.example.invalid/file.torrent"), infoHash: torrentSourceHash)
        let (source, _) = try await pipeline.resolveSource(for: release)
        guard case .magnet(let uri) = source else {
            Issue.record("expected fallback magnet, got \(source)")
            return
        }
        #expect(uri.contains(torrentSourceHash))
    }

    @Test("with no fallback the typed error propagates")
    func propagatesTypedError() async throws {
        let pipeline = try await torrentSourcePipeline { _ in throw TorrentSourceError.httpStatus(404) }
        let release = torrentSourceRelease(downloadURL: URL(string: "https://indexer.example.invalid/file.torrent"))
        let error = await torrentSourceCatch { _ = try await pipeline.resolveSource(for: release) }
        #expect((error as? TorrentSourceError) == .httpStatus(404))
        #expect(PlayPipeline.reason(for: error!).contains("HTTP 404"))
    }

    @Test("a release with no link at all still throws")
    func noLink() async throws {
        let pipeline = try await torrentSourcePipeline { _ in torrentSourceGoodBytes }
        await #expect(throws: (any Error).self) {
            try await pipeline.resolveSource(for: torrentSourceRelease())
        }
    }
}

// MARK: - End to end (search stub -> real HTTP download -> controller)

private final class TorrentSourceBox: Sendable {
    private let sources = Mutex<[TorrentSource]>([])
    func append(_ source: TorrentSource) { sources.withLock { $0.append(source) } }
    var all: [TorrentSource] { sources.withLock { $0 } }
}

private final class TorrentSourceReadyController: StreamControlling {
    let box: TorrentSourceBox
    init(box: TorrentSourceBox) { self.box = box }
    func start(
        source: TorrentSource, content: StreamContent, startEpisode: EpisodeRef?, mode: StreamMode,
        peers: [PeerEndpoint], corrections: [Int: [EpisodeRef]], episodeOrder: [EpisodeRef]?
    ) async throws -> StreamHandle {
        box.append(source)
        let (stream, continuation) = AsyncStream<StreamStatus>.makeStream()
        continuation.yield(.ready)
        continuation.finish()
        return StreamHandle(
            torrent: TorrentID(hex: String(repeating: "ab", count: 20)), episodes: [],
            fileIndex: 0, url: URL(string: "http://127.0.0.1:1/token/file.mkv")!, status: stream, mapping: nil)
    }
    func advance(to episode: EpisodeRef) async throws -> StreamHandle { throw StreamControllerError.notStarted }
    func setMediaDuration(_ seconds: Double) async {}
    func playheadMoved(to offset: Int64) async {}
    func stop(removeTorrent: Bool, deleteFiles: Bool) async {}
    nonisolated func statusUpdates() -> AsyncStream<StreamStatus> {
        let (stream, continuation) = AsyncStream<StreamStatus>.makeStream()
        continuation.yield(.ready)
        continuation.finish()
        return stream
    }
    nonisolated func events() -> AsyncStream<StreamControllerEvent> { AsyncStream { $0.finish() } }
}

private struct TorrentSourceReadyFactory: StreamControllerFactory {
    let box: TorrentSourceBox
    func makeController() -> any StreamControlling { TorrentSourceReadyController(box: box) }
}

private func torrentSourceLivePipeline(releases: [IndexerRelease], box: TorrentSourceBox) async throws -> PlayPipeline {
    let database = try AppDatabase.inMemory()
    return PlayPipeline(
        search: TorrentSourceStubSearch(releases: releases), controllers: TorrentSourceReadyFactory(box: box),
        grabs: GRDBGrabRepository(database), blocklist: GRDBBlocklistRepository(database),
        history: GRDBHistoryRepository(database), fetchTorrentFile: PlayPipeline.downloadTorrentFile,
        configuration: { PlayPipelineConfiguration(readyTimeout: .seconds(5)) })
}

private func torrentSourcePlayRequest() -> PlayRequest {
    PlayRequest(
        title: PlayTitle(id: UUID(), kind: .series, name: "Marquee Test Pattern", year: 2026, tvdbID: 99_000_001),
        scope: .episode(EpisodeRef(season: 1, episode: 1)), profile: .balanced,
        episodes: (1...3).map { PackEpisode(ref: EpisodeRef(season: 1, episode: $0)) })
}

@Suite("TorrentSourceLive")
struct TorrentSourceLiveTests {
    @Test("a .torrent URL release downloads over HTTP and starts")
    func liveTorrent() async throws {
        let server = LoopbackHTTPServer { request in
            request.path == "/file.torrent"
                ? LoopbackHTTPServer.Response(
                    status: 200, contentType: "application/x-bittorrent", body: torrentSourceGoodBytes)
                : LoopbackHTTPServer.Response(status: 404, contentType: "text/plain", body: Data("no".utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let release = IndexerRelease(
            indexerID: UUID(), indexerName: "Test", title: "Marquee.Test.Pattern.S01E01.1080p.WEB-DL.H264-AAA",
            guid: "live-torrent", downloadURL: URL(string: "http://127.0.0.1:\(port)/file.torrent"),
            size: 1_500_000_000, seeders: 50, categories: [5040])
        let box = TorrentSourceBox()
        let pipeline = try await torrentSourceLivePipeline(releases: [release], box: box)
        let stream = try await pipeline.begin(torrentSourcePlayRequest()).stream()
        #expect(stream.release.title == release.title)
        let first = try #require(box.all.first)
        guard case .torrentFile(let data) = first else {
            Issue.record("expected torrentFile, got \(first)")
            return
        }
        #expect(data == torrentSourceGoodBytes)
    }

    @Test("a .torrent URL that redirects to a magnet starts from the magnet")
    func liveRedirect() async throws {
        let server = LoopbackHTTPServer { request in
            request.path == "/dl" ? .redirect(to: torrentSourceMagnet)
                : LoopbackHTTPServer.Response(status: 404, contentType: "text/plain", body: Data("no".utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let release = IndexerRelease(
            indexerID: UUID(), indexerName: "Test", title: "Marquee.Test.Pattern.S01E01.1080p.WEB-DL.H264-AAA",
            guid: "live-redirect", downloadURL: URL(string: "http://127.0.0.1:\(port)/dl"),
            size: 1_500_000_000, seeders: 50, categories: [5040])
        let box = TorrentSourceBox()
        let pipeline = try await torrentSourceLivePipeline(releases: [release], box: box)
        let stream = try await pipeline.begin(torrentSourcePlayRequest()).stream()
        #expect(stream.release.title == release.title)
        let first = try #require(box.all.first)
        guard case .magnet(let uri) = first else {
            Issue.record("expected magnet, got \(first)")
            return
        }
        #expect(uri == torrentSourceMagnet)
    }
}
