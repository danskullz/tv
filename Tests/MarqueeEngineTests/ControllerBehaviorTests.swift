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
        #expect(byName[movie.name] == 6, "7 is reserved for deadline pieces")
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

    @Test("a torrent removed under a live controller says who removed it, and never goes silent")
    func removalIsReportedNotSwallowed() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let movie = try Self.makeMovie(in: seedDir)
        let seeder = try await engineMakeSeeder(torrent: movie.torrent, saveDirectory: seedDir)
        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let controller = StreamSessionController(
            session: leecher, server: server,
            configuration: StreamControllerConfiguration(
                savePath: downloadDir, stallTimeout: .milliseconds(700)))
        let statuses = EngineCollector<StreamStatus>()
        let statusTask = Task { for await s in controller.statusUpdates() { statuses.add(s) } }
        let handle = try await controller.start(
            source: .torrentFile(movie.torrent), content: .movie(title: "Movie Name"),
            peers: [PeerEndpoint(host: "127.0.0.1", port: seeder.port)])

        // Pull the torrent out from under the running controller. This is the shape of the bug
        // that made a failed attempt report "This download was removed." with nothing to go on:
        // the removal was never ours, but it read exactly like every other teardown.
        try await leecher.remove(handle.torrent, deleteFiles: true)

        try await engineEventually(.seconds(5), "a failed status naming the cause") {
            statuses.all.contains { if case .failed = $0 { return true } else { return false } }
        }
        guard case let .failed(message)? = await controller.currentStatus else {
            Issue.record("expected failed status")
            return
        }
        #expect(message.contains("Marquee's own cleanup"), "got: \(message)")
        #expect(!message.contains("requestedByApp"), "the raw enum must not reach the UI")

        // The reason is in the diagnostics bundle even though it is not on screen.
        let diagnostics = await controller.diagnostics
        #expect(diagnostics.contains("torrent removed: Marquee removed the download and deleted its files"))

        statusTask.cancel()
        await controller.stop()
        await server.stop()
        await leecher.shutdown()
        await seeder.session.shutdown()
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

    @Test("progressive window: only the most urgent pieces carry deadlines, refilled as pieces land")
    func progressiveWindow() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let pack = try EnginePack.make(in: seedDir)
        let leecher = try await engineMakeLeecher()
        let id = try await leecher.addTorrent(
            data: pack.torrent, savePath: try scratch.directory("download").path, options: .holdDownload)
        let metadata = try await leecher.metadata(id)
        let files = metadata.files.map { PackFile(index: $0.index, path: $0.path, size: $0.size, offset: $0.offset) }
        let mapping = PackFileMapper.map(files: files, series: EnginePack.series())
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: Int64(metadata.pieceLength))
        let plan = planner.makePlan(start: EpisodeRef(season: 1, episode: 1))
        let map = try #require(TorrentFileByteSource.pieceMap(for: metadata.files[plan.currentFiles[0]], in: metadata))
        let scheduler = TorrentDeadlineScheduler(
            session: leecher, torrent: id, plan: plan, have: PieceAvailability(pieceCount: metadata.pieceCount),
            deadlineBudgetBytes: 512 << 10)  // 8 pieces of 64 KiB

        await scheduler.start()
        let first = await scheduler.appliedDeadlines
        #expect(first.count == 8)
        let head = Set(map.pieceRange.prefix(8))
        #expect(Set(first.keys) == head, "the start of the file comes first")

        // Complete 5 of them: the set drops below half and is topped up with the next pieces.
        let sets = await scheduler.deadlineSetCount
        for p in map.pieceRange.prefix(5) { await scheduler.markHave(p) }
        let refilled = await scheduler.appliedDeadlines
        #expect(refilled.count >= 7, "topped up when it fell to half, then one more completed")
        #expect(await scheduler.deadlineSetCount > sets)
        #expect(refilled.keys.allSatisfy { $0 >= map.pieceRange.lowerBound + 4 })

        // After a seek the window at the new playhead goes ahead of the pending container pieces.
        await scheduler.movePlayhead(to: 8 << 20)
        let seeked = await scheduler.appliedDeadlines
        let target = map.pieceIndex(forFileOffset: 8 << 20)
        #expect(seeked[target] != nil)
        #expect(seeked.keys.filter { (target..<target + 8).contains($0) }.count == 8, "all budget goes to the new window")

        // A larger budget takes effect immediately.
        await scheduler.setBudget(2 << 20)
        #expect(await scheduler.appliedDeadlines.count == 32)
        await leecher.shutdown()
    }

    @Test("file priorities keep 7 for deadline pieces")
    func prioritiesReserveTop() throws {
        let files = PackFile.layout((1...3).map { ("Show.Name.S01E0\($0).1080p.mkv", Int64(100 << 20)) })
        let mapping = PackFileMapper.map(files: files, series: EnginePack.series())
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: 1 << 20).makePlan(start: EpisodeRef(season: 1, episode: 1))
        #expect(plan.priorities.values.map(\.rawValue).max() == 7)
        let vector = StreamSessionController.priorityVector(plan, fileCount: 3)
        #expect(vector == [6, 5, 4])
        #expect(StreamSessionController.priorityVector(plan, fileCount: 5).suffix(2) == [0, 0])
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

    @Test("cushion: high-bitrate files need seconds of playback buffered, small ones are unchanged")
    func readinessCushion() {
        // An 8 GiB movie at ~1.3 MB/s needs ~19.5 MB for a 15 s cushion, not just 6 MB.
        let legacy = FixedBufferReadinessPolicy(bytesAfterHead: 4 << 20)
        let cushioned = FixedBufferReadinessPolicy(bytesAfterHead: 4 << 20, cushionSeconds: 15)
        var input = ReadinessInput(
            fileLength: 8 << 30, playhead: 0, bytesAhead: 6 << 20, headComplete: true, tailComplete: true,
            headBytes: 2 << 20, downloadRate: 0, estimatedBytesPerSecond: 1_301_505)
        #expect(legacy.isReady(input), "legacy policy still starts on the fixed buffer")
        #expect(!cushioned.isReady(input), "6 MB is only ~5 s at this bitrate")
        input.bytesAhead = 20 << 20
        #expect(cushioned.isReady(input))
        // A small episode: the 15 s cushion (~70 KB) is below the fixed buffer, so no later start.
        input = ReadinessInput(
            fileLength: 12 << 20, playhead: 0, bytesAhead: 6 << 20, headComplete: true, tailComplete: true,
            headBytes: 2 << 20, downloadRate: 0, estimatedBytesPerSecond: 4_800)
        #expect(cushioned.isReady(input))
        // Near EOF the cushion is capped by what remains.
        input = ReadinessInput(
            fileLength: 8 << 30, playhead: (8 << 30) - (1 << 20), bytesAhead: 1 << 20, headComplete: true,
            tailComplete: true, headBytes: 2 << 20, downloadRate: 0, estimatedBytesPerSecond: 1_301_505)
        #expect(cushioned.isReady(input))
        input.headComplete = false
        #expect(!cushioned.isReady(input))
    }

    @Test("stream controller defaults: 15 s cushion on, 20 s watchdog, 2 s budget growth")
    func controllerTuningDefaults() throws {
        let scratch = try EngineScratch()
        let config = StreamControllerConfiguration(savePath: try scratch.directory("download"))
        #expect(config.readyCushionSeconds == 15)
        #expect(config.requirePlaybackCushion)
        #expect(config.stallTimeout == .seconds(20))
        #expect(config.deadlineBudgetSeconds == 2)
        #expect(config.deadlineBudgetBytes == 1 << 20)
    }

    @Test("throughput sampler: windows accumulate, then an EWMA of arrival rate")
    func throughputSampler() {
        var sampler = ThroughputSampler()
        let t0 = ContinuousClock.now
        func check(_ actual: Double?, _ expected: Double, _ what: String = "") {
            #expect(actual != nil, "estimate present \(what)")
            #expect(abs((actual ?? 0) - expected) < max(1, expected / 1_000_000), "estimate ≈ \(expected) \(what)")
        }
        #expect(sampler.estimate == nil)
        sampler.add(bytes: 32_000, at: t0)
        #expect(sampler.estimate == nil, "a partial window is not a sample yet")
        sampler.add(bytes: 32_000, at: t0 + .milliseconds(250))
        check(sampler.estimate, 256_000, "first window")
        sampler.add(bytes: 16_000, at: t0 + .milliseconds(500))
        let second = 0.7 * 256_000 + 0.3 * 64_000
        check(sampler.estimate, second, "EWMA moves toward the new rate")
        // A 10 ms burst accumulates instead of spiking; the next full window samples it.
        sampler.add(bytes: 16_000, at: t0 + .milliseconds(510))
        check(sampler.estimate, second, "partial window leaves the estimate alone")
        sampler.add(bytes: 16_000, at: t0 + .milliseconds(750))
        check(sampler.estimate, 0.7 * second + 0.3 * 128_000, "burst averaged over its window")
        sampler.add(bytes: 0, at: t0 + .seconds(5))
        check(sampler.estimate, 0.7 * second + 0.3 * 128_000, "empty pieces are ignored")
    }

    @Test("deadline scheduler puts the head and tail ahead of the window")
    func headAndTailFirst() async throws {
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
        let map = try #require(TorrentFileByteSource.pieceMap(for: metadata.files[plan.currentFiles[0]], in: metadata))
        let container = Set(map.pieces(forFileRange: 0..<options.headBytes))
            .union(map.pieces(forFileRange: (map.fileLength - options.tailBytes)..<map.fileLength))
        let scheduler = TorrentDeadlineScheduler(
            session: leecher, torrent: id, plan: plan, have: PieceAvailability(pieceCount: metadata.pieceCount),
            deadlineBudgetBytes: Int64(container.count) * Int64(metadata.pieceLength))

        await scheduler.start()
        let applied = await scheduler.appliedDeadlines
        #expect(Set(applied.keys) == container, "a tight budget carries exactly the head and tail")
        await leecher.shutdown()
    }

    @Test("advance keeps the prefetched head and pre-warms the next episode")
    func advanceKeepsPrefetchedHead() async throws {
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
        let e1 = EpisodeRef(season: 1, episode: 1)
        let e2 = EpisodeRef(season: 1, episode: 2)
        let e3 = EpisodeRef(season: 1, episode: 3)
        let plan = planner.makePlan(start: e1)
        let scheduler = TorrentDeadlineScheduler(
            session: leecher, torrent: id, plan: plan, have: PieceAvailability(pieceCount: metadata.pieceCount))
        await scheduler.start()
        func map(of episode: EpisodeRef) throws -> PieceMap {
            let p = planner.makePlan(start: episode)
            return try #require(TorrentFileByteSource.pieceMap(for: metadata.files[p.currentFiles[0]], in: metadata))
        }
        let e1Map = try map(of: e1)
        let e2Map = try map(of: e2)
        let e3Map = try map(of: e3)
        let e2Head = e2Map.pieces(forFileRange: 0..<options.headBytes)

        // Far from the end of E01, E02's head is not requested.
        let initial = await scheduler.appliedDeadlines
        #expect(e2Head.allSatisfy { initial[$0] == nil })

        // Near the end, rollover pulls E02's head and tail in.
        await scheduler.movePlayhead(to: e1Map.fileLength - (1 << 20))
        var applied = await scheduler.appliedDeadlines
        #expect(e2Head.allSatisfy { applied[$0] != nil })

        // Advancing keeps E02's head (now current) instead of clearing it.
        let clears = await scheduler.deadlineClearCount
        await scheduler.setPlan(planner.makePlan(start: e2))
        #expect(await scheduler.playhead == 0)
        applied = await scheduler.appliedDeadlines
        #expect(e2Head.allSatisfy { applied[$0] != nil }, "prefetched head survives the switch")
        #expect(e2Map.pieceIndex(forFileOffset: 0) == e2Head.lowerBound)
        #expect(applied[e2Map.pieceIndex(forFileOffset: 0)] != nil)
        #expect(await scheduler.deadlineClearCount > clears, "E01's window behind was cleared")

        // Near the end of E02, E03's head joins: the new current pre-warms its successor.
        await scheduler.movePlayhead(to: e2Map.fileLength - (1 << 20))
        applied = await scheduler.appliedDeadlines
        let e3Head = e3Map.pieces(forFileRange: 0..<options.headBytes)
        #expect(e3Head.allSatisfy { applied[$0] != nil })
        await leecher.shutdown()
    }
}
