import Foundation
import MarqueeCore
import Testing
import TorrentEngine

@testable import MarqueeEngine

@Suite("StreamSessionController behaviour", .serialized)
struct ControllerBehaviorTests {
    private static func makeMovie(in seedDir: URL) throws -> (torrent: Data, content: Data, name: String) {
        let folder = "Movie.Name.2019.1080p.BluRay-GRP"
        let root = seedDir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sample"), withIntermediateDirectories: true)
        let name = "\(folder).mkv"
        let content = enginePayload(count: 3 * 1_048_576 + 4_321, seed: 55)
        try content.write(to: root.appendingPathComponent(name))
        try enginePayload(count: 300_000, seed: 56).write(to: root.appendingPathComponent("Sample/movie.name.2019.sample.mkv"))
        try Data("nfo".utf8).write(to: root.appendingPathComponent("\(folder).nfo"))
        return (try TorrentCreator.createTorrent(at: root, pieceLength: 16 * 1024), content, name)
    }

    @Test("a magnet for a movie: metadata comes from the peer, the main file plays, status goes to ready")
    func magnetMovie() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let movie = try Self.makeMovie(in: seedDir)
        let seeder = try await engineMakeSeeder(torrent: movie.torrent, saveDirectory: seedDir)
        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let controller = StreamSessionController(
            session: leecher, server: server, configuration: StreamControllerConfiguration(savePath: downloadDir))
        let statuses = EngineCollector<StreamStatus>()
        let statusTask = Task { for await s in controller.statusUpdates() { statuses.add(s) } }

        let handle = try await controller.start(
            source: .magnet("magnet:?xt=urn:btih:\(seeder.id.hex)"), content: .movie(title: "Movie Name"),
            peers: [PeerEndpoint(host: "127.0.0.1", port: seeder.port)])
        #expect(handle.torrent == seeder.id)
        #expect(handle.episodes == [StreamContent.movieEpisode])
        #expect(handle.mapping == nil)
        #expect(handle.url.lastPathComponent == movie.name)

        try await controller.waitUntilReady()
        #expect(await controller.isReadyToPlay)

        let http = engineSession()
        let whole = try await engineFetch(handle.url, session: http)
        #expect(whole.status == 200)
        #expect(whole.data == movie.content)

        // Priorities: the sample and nfo are skipped, the movie is not.
        let metadata = try await leecher.metadata(handle.torrent)
        let byName = Dictionary(uniqueKeysWithValues: metadata.files.map { (($0.path as NSString).lastPathComponent, $0.priority) })
        #expect(byName[movie.name] == 7)
        #expect(byName["movie.name.2019.sample.mkv"] == 0)

        await controller.stop()
        statusTask.cancel()
        #expect(statuses.all.first == .fetchingMetadata)
        #expect(statuses.all.contains(.ready))
        await server.stop()
        await leecher.shutdown()
        await seeder.session.shutdown()
    }

    @Test("a magnet nobody answers fails with a plain-language status, not a raw error")
    func metadataTimeout() async throws {
        let scratch = try EngineScratch()
        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let controller = StreamSessionController(
            session: leecher, server: server,
            configuration: StreamControllerConfiguration(
                savePath: try scratch.directory("download"), metadataTimeout: .milliseconds(800)))
        await #expect(throws: StreamControllerError.metadataTimeout) {
            _ = try await controller.start(
                source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "ab", count: 20))"),
                content: .movie(title: "Nothing"))
        }
        guard case .failed(let message)? = await controller.currentStatus else {
            Issue.record("expected failed status")
            return
        }
        #expect(message == StreamControllerError.metadataTimeout.plainLanguage)
        #expect(!message.contains("libtorrent"))
        await controller.stop()
        await server.stop()
        await leecher.shutdown()
    }

    @Test("with no peers the watchdog reports a stall once, and only while waiting for data")
    func stallWatchdog() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let movie = try Self.makeMovie(in: seedDir)
        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let controller = StreamSessionController(
            session: leecher, server: server,
            configuration: StreamControllerConfiguration(
                savePath: try scratch.directory("download"), stallTimeout: .milliseconds(700)))
        let statuses = EngineCollector<StreamStatus>()
        let statusTask = Task { for await s in controller.statusUpdates() { statuses.add(s) } }
        _ = try await controller.start(source: .torrentFile(movie.torrent), content: .movie(title: "Movie Name"))
        try await engineEventually(.seconds(5), "stalled status") { statuses.all.contains(.stalled(.noPeers)) }
        #expect(statuses.all.first == .findingPeers)
        #expect(statuses.all.filter { $0 == .stalled(.noPeers) }.count == 1)
        statusTask.cancel()
        await controller.stop(removeTorrent: true)
        await server.stop()
        await leecher.shutdown()
    }

    @Test("availability provider: snapshot, piece events, byte-source reads and playhead hints")
    func availabilityAndByteSource() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let movie = try Self.makeMovie(in: seedDir)
        let seeder = try await engineMakeSeeder(torrent: movie.torrent, saveDirectory: seedDir)
        let leecher = try await engineMakeLeecher()

        let id = try await leecher.addTorrent(data: movie.torrent, savePath: downloadDir.path, options: .holdDownload)
        let metadata = try await leecher.metadata(id)
        let file = try #require(metadata.files.first { $0.path.hasSuffix(".mkv") && !$0.path.contains("ample") })
        let map = try #require(TorrentFileByteSource.pieceMap(for: file, in: metadata))

        final class Recorder: PlayheadObserver {
            let hints = EngineCollector<[Int64]>()
            func playheadMoved(fileIndex: Int, offset: Int64) async { hints.add([Int64(fileIndex), offset]) }
        }
        let recorder = Recorder()
        let availability = TorrentPieceAvailability(
            session: leecher, torrent: id, fileIndex: file.index, pieceMap: map, observer: recorder)
        let source = TorrentFileByteSource(savePath: downloadDir, file: file, pieceMap: map, availability: availability)
        #expect(source.length == file.size)
        #expect(source.contentType == "video/x-matroska")

        // Nothing yet.
        #expect(await availability.snapshot().count == 0)
        let pieces = availability.completedPieces()
        let collected = EngineCollector<Int>()
        let collector = Task { for await p in pieces { collected.add(p) } }

        // A read parks until the pieces arrive; the hint carries the piece-aligned file offset.
        let readTask = Task { try await source.read(offset: 1_000_000, length: 100_000) }
        await source.prioritize(offset: 1_000_000, length: 100_000)
        #expect(recorder.hints.all == [[Int64(file.index), 1_000_000 / 16_384 * 16_384]])

        try await leecher.connectPeer(id, host: "127.0.0.1", port: seeder.port)
        try await leecher.startDownload(id)
        let data = try await readTask.value
        #expect(data == movie.content.subdata(in: 1_000_000..<1_100_000))

        try await engineEventually(.seconds(20), "all pieces reported") {
            Set(collected.all).isSuperset(of: Set(map.pieceRange))
        }
        let snapshot = await availability.snapshot()
        #expect(snapshot.containsAll(map.pieceRange))
        let tail = try await source.read(offset: file.size - 10, length: 100)
        #expect(tail == movie.content.suffix(10))
        collector.cancel()
        await leecher.shutdown()
        await seeder.session.shutdown()
    }

    @Test("deadline scheduler sends only the difference when the playhead moves")
    func schedulerDiffs() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let pack = try EnginePack.make(in: seedDir)
        let leecher = try await engineMakeLeecher()
        let id = try await leecher.addTorrent(
            data: pack.torrent, savePath: try scratch.directory("download").path, options: .holdDownload)
        let metadata = try await leecher.metadata(id)
        let files = metadata.files.map { PackFile(index: $0.index, path: $0.path, size: $0.size, offset: $0.offset) }
        let mapping = PackFileMapper.map(files: files, series: EnginePack.series())
        var options = StreamPlanOptions()
        options.rolloverBytes = 2 << 20
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: Int64(metadata.pieceLength), options: options)
        let plan = planner.makePlan(start: EpisodeRef(season: 1, episode: 1))
        let scheduler = TorrentDeadlineScheduler(
            session: leecher, torrent: id, plan: plan, have: PieceAvailability(pieceCount: metadata.pieceCount))

        await scheduler.start()
        let initial = await scheduler.appliedDeadlines
        let sets0 = await scheduler.deadlineSetCount
        #expect(sets0 == initial.count && sets0 > 0)
        #expect(await scheduler.deadlineClearCount == 0)

        // Same playhead again: the plan is identical, so nothing goes to the engine.
        await scheduler.movePlayhead(to: 0)
        #expect(await scheduler.deadlineSetCount == sets0)
        #expect(await scheduler.deadlineClearCount == 0)

        // A seek far ahead: the old window is cleared and the new one set.
        await scheduler.movePlayhead(to: 8 << 20)
        let moved = await scheduler.appliedDeadlines
        #expect(await scheduler.deadlineClearCount > 0)
        #expect(await scheduler.deadlineSetCount > sets0)
        let e1 = plan.currentFiles[0]
        let map = try #require(TorrentFileByteSource.pieceMap(for: metadata.files[e1], in: metadata))
        let behind = map.pieces(forFileRange: (2 << 20)..<(7 << 20))
        #expect(behind.allSatisfy { moved[$0] == nil }, "pieces well behind the playhead lost their deadline")
        #expect(moved[map.pieceIndex(forFileOffset: 8 << 20)] != nil)

        // Completed pieces drop out of the bookkeeping.
        let probe = try #require(moved.keys.first)
        await scheduler.markHave(probe)
        #expect(await scheduler.appliedDeadlines[probe] == nil)

        // Advancing re-plans around the next episode; the stale-source guard ignores E01 afterwards.
        let next = planner.makePlan(start: EpisodeRef(season: 1, episode: 2))
        await scheduler.setPlan(next)
        #expect(await scheduler.playhead == 0)
        let afterSwitch = await scheduler.appliedDeadlines
        let e2Map = try #require(TorrentFileByteSource.pieceMap(for: metadata.files[next.currentFiles[0]], in: metadata))
        #expect(afterSwitch[e2Map.pieceIndex(forFileOffset: 0)] != nil)
        await scheduler.playheadMoved(fileIndex: e1, offset: 5 << 20)
        #expect(await scheduler.playhead == 0, "a hint from the previous episode's source is ignored")
        await leecher.shutdown()
    }

    @Test("fixed-buffer readiness needs head, tail and the buffer after the head")
    func readinessPolicy() {
        let policy = FixedBufferReadinessPolicy(bytesAfterHead: 4 << 20)
        var input = ReadinessInput(
            fileLength: 100 << 20, playhead: 0, bytesAhead: 6 << 20, headComplete: true, tailComplete: true,
            headBytes: 2 << 20, downloadRate: 0, estimatedBytesPerSecond: 1_000_000)
        #expect(policy.isReady(input))
        input.tailComplete = false
        #expect(!policy.isReady(input))
        input.tailComplete = true
        input.bytesAhead = 5 << 20
        #expect(!policy.isReady(input))
        input.playhead = 98 << 20  // only 2 MB left in the file: everything remaining is enough
        input.bytesAhead = 2 << 20
        #expect(policy.isReady(input))
    }
}
