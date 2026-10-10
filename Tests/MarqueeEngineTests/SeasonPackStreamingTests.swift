import Foundation
import MarqueeCore
import Testing
import TorrentEngine

@testable import MarqueeEngine

/// Phase 0 exit criterion at the data level: stream a season pack's first episode while it downloads
/// from a throttled loopback swarm, seek, roll into the next episode, and end with every file on disk.
@Suite("Season pack streaming (loopback swarm)", .serialized)
struct SeasonPackStreamingTests {
    private static let uploadLimit = 2_000_000  // bytes/s: the whole pack takes ~15 s, E01's first MB ~0.5 s

    private func hasPieces(_ pieces: Range<Int>, in state: StreamSessionController.DeadlineState?, have: PieceAvailability) -> Bool {
        pieces.allSatisfy { have.contains($0) || state?.deadlines[$0] != nil }
    }

    @Test("plays E01 while downloading, seeks, rolls into E02 and completes the pack")
    func streamsSeasonPackThrottled() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let pack = try EnginePack.make(in: seedDir)
        let seeder = try await engineMakeSeeder(torrent: pack.torrent, saveDirectory: seedDir, uploadLimit: Self.uploadLimit)

        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        var options = StreamPlanOptions()
        options.rolloverBytes = 2 << 20  // only the last 2 MB of an episode pulls the next one in
        let controller = StreamSessionController(
            session: leecher, server: server,
            configuration: StreamControllerConfiguration(
                savePath: downloadDir, planOptions: options, stallTimeout: .seconds(30)))

        // Observe from the very beginning.
        let statuses = EngineCollector<StreamStatus>()
        let statusTask = Task { for await s in controller.statusUpdates() { statuses.add(s) } }
        let controllerEvents = EngineCollector<StreamControllerEvent>()
        let eventTask = Task { for await e in controller.events() { controllerEvents.add(e) } }

        let t0 = ContinuousClock.now
        let handle = try await controller.start(
            source: .torrentFile(pack.torrent), content: .series(EnginePack.series()),
            startEpisode: EpisodeRef(season: 1, episode: 1), mode: .streamFromStart,
            peers: [PeerEndpoint(host: "127.0.0.1", port: seeder.port)])
        let startLatency = ContinuousClock.now - t0
        let id = handle.torrent
        let metadata = try await leecher.metadata(id)
        func index(of name: String) throws -> Int {
            try #require(metadata.files.first { $0.path.hasSuffix(name) }?.index)
        }
        let e1 = try index(of: pack.episodeNames[0])
        let e2 = try index(of: pack.episodeNames[1])
        let e3 = try index(of: pack.episodeNames[2])
        let sampleIndex = try index(of: "Show.Name.S01E01.sample.mkv")
        let nfoIndex = try index(of: pack.nfoName)

        // (a) The URL is E01 and the extras are skipped.
        #expect(handle.episodes == [EpisodeRef(season: 1, episode: 1)])
        #expect(handle.fileIndex == e1)
        #expect(handle.url.lastPathComponent == pack.episodeNames[0])
        #expect(handle.mapping?.gaps.isEmpty == true)
        #expect(metadata.files[sampleIndex].priority == 0, "sample is skipped")
        #expect(metadata.files[nfoIndex].priority == 0, "nfo is skipped")
        let prios = [e1, e2, e3].map { metadata.files[$0].priority }
        #expect(prios[0] == 6 && prios[0] > prios[1] && prios[1] > prios[2] && prios[2] > 0, "descending gradient: \(prios)")
        let initial = try #require(await controller.deadlineState())
        #expect(!initial.deadlines.isEmpty && initial.setCalls > 0, "head, tail and window deadlines set before the download starts")

        let http = engineSession()
        let e1Data = pack.episodes[0]
        let e1Length = Int64(e1Data.count)
        let e2Map = try #require(TorrentFileByteSource.pieceMap(for: metadata.files[e2], in: metadata))
        let e2Head = e2Map.pieces(forFileRange: 0..<(2 << 20))
        #expect(
            e2Head.allSatisfy { initial.deadlines[$0] == nil },
            "E02's head is not requested while the playhead is far from the end of E01")

        // (b) First MB, while the torrent is still far from complete.
        let first = try await engineFetch(handle.url, range: 0..<(1 << 20), session: http)
        #expect(first.status == 206)
        #expect(first.data == e1Data.prefix(1 << 20))
        let ttfb = ContinuousClock.now - t0
        #expect(ttfb < .seconds(15), "Phase 0: stream starts in under 15 s (took \(ttfb))")
        #expect(first.firstByte < .seconds(3), "first byte follows the request promptly (\(first.firstByte))")
        let afterFirst = try await leecher.status(id)
        #expect(afterFirst.piecesHave < afterFirst.pieceCount / 2, "playing while downloading, not after")

        // (c) Seek 60 % into E01: completes, matches, and the deadline window moved with it.
        let seekOffset = (e1Length * 6 / 10) / 65_536 * 65_536 + 1000
        let seek = try await engineFetch(handle.url, range: seekOffset..<(seekOffset + (1 << 20)), session: http)
        #expect(seek.status == 206)
        let seekExpected = e1Data.subdata(in: Int(seekOffset)..<Int(seekOffset) + (1 << 20))
        #expect(seek.data == seekExpected)
        var moved: StreamSessionController.DeadlineState?
        try await engineEventually(.seconds(5), "playhead moved") {
            moved = await controller.deadlineState()
            return (moved?.playhead ?? 0) >= seekOffset - 65_536
        }
        let seekedState = try #require(moved)
        #expect(seekedState.clearCalls > 0, "deadlines behind the new playhead were cleared")
        #expect(seekedState.replans >= 3)
        let map1 = try #require(TorrentFileByteSource.pieceMap(for: metadata.files[e1], in: metadata))
        let probe = map1.pieces(forFileRange: (seekOffset + 200_000)..<(seekOffset + 200_001))
        let haveNow = await controller.pieceAvailability
        #expect(hasPieces(probe, in: seekedState, have: haveNow), "the window ahead of the seek has deadlines")

        // (d) Read the end of E01: E02's head and tail are requested before E02 is registered.
        let tailStart = e1Length - (1_500_000)
        let tailRead = try await engineFetch(handle.url, range: tailStart..<e1Length, session: http)
        #expect(tailRead.data == e1Data.suffix(1_500_000))
        var rolled: StreamSessionController.DeadlineState?
        try await engineEventually(.seconds(5), "rollover deadlines") {
            rolled = await controller.deadlineState()
            let have = await controller.pieceAvailability
            return e2Head.allSatisfy { have.contains($0) || rolled?.deadlines[$0] != nil }
                && e2Head.contains { rolled?.deadlines[$0] != nil || have.contains($0) }
        }
        let stillHave = await controller.pieceAvailability
        #expect(hasPieces(e2Head, in: rolled, have: stillHave), "E02 head requested ahead of advance")
        #expect(!stillHave.containsAll(e2Map.pieces(forFileRange: 0..<e2Map.fileLength)), "E02 is not simply complete")

        // Let E02's head land, then advance.
        try await engineEventually(.seconds(20), "E02 head downloaded") {
            await controller.pieceAvailability.containsAll(e2Head)
        }
        let advanceStart = ContinuousClock.now
        let next = try await controller.advance(to: EpisodeRef(season: 1, episode: 2))

        // (e) E02's URL works and its first bytes match, without waiting on the network.
        #expect(next.fileIndex == e2)
        #expect(next.url != handle.url)
        #expect(next.url.lastPathComponent == pack.episodeNames[1])
        let e2Data = pack.episodes[1]
        let rollover = try await engineFetch(next.url, range: 0..<(1 << 20), session: http)
        let rolloverLatency = ContinuousClock.now - advanceStart
        #expect(rollover.status == 206)
        #expect(rollover.data == e2Data.prefix(1 << 20))
        #expect(rollover.firstByte < .seconds(1), "head was prefetched: no buffering gap (\(rollover.firstByte))")
        let after = try await engineFetch(next.url, range: 3_000_000..<3_100_000, session: http)
        #expect(after.data == e2Data.subdata(in: 3_000_000..<3_100_000))

        // (f) The rest of the pack arrives and every file reports completion.
        try await engineEventually(.seconds(45), "all files complete") {
            let done = controllerEvents.all.compactMap { event -> Int? in
                if case let .fileCompleted(_, index, _, _) = event { return index }
                return nil
            }
            return Set(done).isSuperset(of: [e1, e2, e3])
        }
        let completed = controllerEvents.all.compactMap { event -> (Int, [EpisodeRef])? in
            if case let .fileCompleted(_, index, _, episodes) = event { return (index, episodes) }
            return nil
        }
        #expect(completed.first { $0.0 == e1 }?.1 == [EpisodeRef(season: 1, episode: 1)])
        #expect(completed.first { $0.0 == e3 }?.1 == [EpisodeRef(season: 1, episode: 3)])
        for (i, name) in pack.episodeNames.enumerated() {
            let onDisk = try Data(contentsOf: downloadDir.appendingPathComponent(EnginePack.folder).appendingPathComponent(name))
            #expect(onDisk == pack.episodes[i], "\(name) matches the seed")
        }
        let sampleProgress = try await leecher.fileProgress(id, fileCount: metadata.files.count)[sampleIndex]
        #expect(sampleProgress < metadata.files[sampleIndex].size, "the sample was never fetched")
        #expect(statuses.all.contains(.ready))
        #expect(!statuses.all.contains { $0.isTerminal })

        print("""
            [engine-e2e] start() returned in \(String(format: "%.0f", startLatency.engineMilliseconds)) ms; \
            first byte of E01 from start: \(String(format: "%.0f", first.firstByte.engineMilliseconds)) ms after request \
            (1 MB read done \(String(format: "%.0f", ttfb.engineMilliseconds)) ms after start); \
            seek first byte: \(String(format: "%.0f", seek.firstByte.engineMilliseconds)) ms, 1 MB: \(String(format: "%.0f", seek.total.engineMilliseconds)) ms; \
            rollover first byte: \(String(format: "%.0f", rollover.firstByte.engineMilliseconds)) ms (advance+1MB \(String(format: "%.0f", rolloverLatency.engineMilliseconds)) ms)
            """)

        await controller.stop()
        statusTask.cancel()
        eventTask.cancel()
        await server.stop()
        await leecher.shutdown()
        await seeder.session.shutdown()
    }

    @Test("a second controller start is rejected, and an episode outside the pack is reported plainly")
    func rejectsBadRequests() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let pack = try EnginePack.make(in: seedDir, sizes: [200_000, 200_000, 200_000], pieceLength: 16 * 1024)
        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let controller = StreamSessionController(
            session: leecher, server: server, configuration: StreamControllerConfiguration(savePath: downloadDir))

        await #expect(throws: StreamControllerError.notStarted) {
            _ = try await controller.advance(to: EpisodeRef(season: 1, episode: 2))
        }
        await #expect(throws: StreamControllerError.episodeNotInPack(EpisodeRef(season: 1, episode: 9))) {
            _ = try await controller.start(
                source: .torrentFile(pack.torrent), content: .series(EnginePack.series()),
                startEpisode: EpisodeRef(season: 1, episode: 9))
        }
        if case .failed(let message)? = await controller.currentStatus {
            #expect(message.contains("S01E09"), "plain-language failure: \(message)")
        } else {
            Issue.record("expected a failed status")
        }
        await #expect(throws: StreamControllerError.alreadyStarted) {
            _ = try await controller.start(source: .torrentFile(pack.torrent), content: .series(EnginePack.series()))
        }
        await controller.stop()
        await server.stop()
        await leecher.shutdown()
    }
}

@Suite("Stream attach (loopback swarm)", .serialized)
struct StreamAttachTests {
    @Test("attach serves a still-downloading torrent after its controller stopped")
    func attachServesOrphanedTorrent() async throws {
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let pack = try EnginePack.make(in: seedDir)
        let seeder = try await engineMakeSeeder(torrent: pack.torrent, saveDirectory: seedDir)

        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let configuration = StreamControllerConfiguration(savePath: downloadDir)
        let first = StreamSessionController(session: leecher, server: server, configuration: configuration)
        let handle = try await first.start(
            source: .torrentFile(pack.torrent), content: .series(EnginePack.series()),
            startEpisode: EpisodeRef(season: 1, episode: 1),
            peers: [PeerEndpoint(host: "127.0.0.1", port: seeder.port)])
        let id = handle.torrent
        // The player closed: serving stops, the download continues.
        await first.stop(removeTorrent: false)

        // A later Play attaches instead of searching for a new source.
        let second = StreamSessionController(session: leecher, server: server, configuration: configuration)
        let attached = try await second.attach(
            to: id, content: .series(EnginePack.series()),
            startEpisode: EpisodeRef(season: 1, episode: 1),
            peers: [PeerEndpoint(host: "127.0.0.1", port: seeder.port)])
        #expect(attached.torrent == id)
        #expect(attached.episodes == [EpisodeRef(season: 1, episode: 1)])

        // Same bytes as the episode file.
        let http = engineSession()
        let firstMB = try await engineFetch(attached.url, range: 0..<(1 << 20), session: http)
        #expect(firstMB.status == 206)
        #expect(firstMB.data == pack.episodes[0].prefix(1 << 20))

        // Gone torrents still fail (the app falls back to a fresh search).
        await second.stop(removeTorrent: true, deleteFiles: true)
        let third = StreamSessionController(session: leecher, server: server, configuration: configuration)
        await #expect(throws: Error.self) {
            _ = try await third.attach(
                to: id, content: .series(EnginePack.series()),
                startEpisode: EpisodeRef(season: 1, episode: 1))
        }
        await third.stop()
        await server.stop()
        await leecher.shutdown()
    }
}
