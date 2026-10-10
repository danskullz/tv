import Foundation
import Testing

@testable import TorrentEngine

/// End-to-end tests of the libtorrent wrapper over the loopback interface. Two in-process sessions
/// form the whole swarm: DHT, LSD, UPnP and NAT-PMP are off and peers are connected by hand, so
/// nothing touches the network beyond 127.0.0.1.
@Suite("TorrentEngine loopback swarm", .serialized)
struct LoopbackSwarmTests {
    private static let pieceLength = 16 * 1024

    // MARK: Fixtures

    /// Deterministic, incompressible-looking bytes so a wrong piece cannot hash correctly by luck.
    private static func payload(count: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 0, count: count)
        for i in stride(from: 0, to: count, by: 8) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            for j in 0..<min(8, count - i) { bytes[i + j] = UInt8(truncatingIfNeeded: z >> (8 * UInt64(j))) }
        }
        return Data(bytes)
    }

    private final class Scratch {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-torrent-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func directory(_ name: String) throws -> URL {
            let d = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
    }

    /// Polls until `condition` holds. Tests only; the engine itself never polls.
    private static func eventually(
        _ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met within \(timeout)")
        throw TorrentError.timedOut
    }

    /// Consumes `stream` until `done` returns true or the timeout passes.
    private static func consume(
        _ stream: AsyncStream<TorrentEvent>, timeout: Duration = .seconds(30),
        until done: @escaping @Sendable (TorrentEvent) -> Bool
    ) async throws -> [TorrentEvent] {
        try await withThrowingTaskGroup(of: [TorrentEvent].self) { group in
            group.addTask {
                var seen: [TorrentEvent] = []
                for await event in stream {
                    seen.append(event)
                    if done(event) { return seen }
                }
                throw TorrentError.sessionClosed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TorrentError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Starts a seeder session holding `seedURL` (already complete on disk) and waits for it to
    /// finish checking.
    private static func makeSeeder(
        torrent: Data, saveDirectory: URL, encryption: EncryptionMode
    ) async throws -> (session: TorrentSession, id: TorrentID, port: Int) {
        let session = try TorrentSession(configuration: .loopbackOnly(encryption: encryption))
        try await session.setBool("allow_multiple_connections_per_ip", true)
        let id = try await session.addTorrent(data: torrent, savePath: saveDirectory.path)
        try await eventually { try await session.status(id).state == .seeding }
        return (session, id, try await session.tcpListenPort())
    }

    // MARK: Tests

    @Test("downloads a torrent from a loopback seeder; every piece is reported; bytes match",
          arguments: [EncryptionMode.preferred, EncryptionMode.required])
    func downloadsFromSeeder(encryption: EncryptionMode) async throws {
        let scratch = try Scratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let content = Self.payload(count: 1_048_576 + 5_000, seed: 1)  // ragged last piece
        try content.write(to: seedDir.appendingPathComponent("payload.bin"))
        let torrent = try TorrentCreator.createTorrent(
            at: seedDir.appendingPathComponent("payload.bin"), pieceLength: Self.pieceLength)

        let seeder = try await Self.makeSeeder(torrent: torrent, saveDirectory: seedDir, encryption: encryption)
        let leecher = try TorrentSession(configuration: .loopbackOnly(encryption: encryption))
        try await leecher.setBool("allow_multiple_connections_per_ip", true)

        let events = leecher.events()  // subscribe before adding so nothing is missed
        let id = try await leecher.addTorrent(data: torrent, savePath: downloadDir.path)
        #expect(id == seeder.id, "same torrent must get the same id in both sessions")
        try await leecher.connectPeer(id, host: "127.0.0.1", port: seeder.port)

        let seen = try await Self.consume(events) { event in
            if case .finished = event { return true }
            return false
        }
        var finishedPieces = Set<Int>()
        for case let .pieceFinished(eventID, piece) in seen where eventID == id { finishedPieces.insert(piece) }

        let metadata = try await leecher.metadata(id)
        #expect(metadata.files.count == 1)
        #expect(metadata.files.first?.path.hasSuffix("payload.bin") == true)
        #expect(metadata.files.first?.size == Int64(content.count))
        #expect(metadata.files.first?.offset == 0)
        #expect(metadata.pieceLength == Self.pieceLength)
        #expect(metadata.pieceCount == (content.count + Self.pieceLength - 1) / Self.pieceLength)

        #expect(finishedPieces == Set(0..<metadata.pieceCount), "a piece-finished event for every piece")
        let have = try await leecher.havePieces(id)
        #expect(have.isComplete && have.pieceCount == metadata.pieceCount)

        let status = try await leecher.status(id)
        #expect(status.progress == 1.0)
        #expect(status.totalWantedDone == Int64(content.count))
        #expect([TorrentState.finished, .seeding].contains(status.state))

        let downloaded = try Data(contentsOf: downloadDir.appendingPathComponent(metadata.files[0].path))
        #expect(downloaded == content)

        await leecher.shutdown()
        await seeder.session.shutdown()
    }

    @Test("magnet metadata exchange, file priorities, piece deadlines and piece reads")
    func magnetPriorityAndDeadlines() async throws {
        let scratch = try Scratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let root = seedDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Three "episodes", each a whole number of pieces so no piece spans two files.
        let fileSize = 16 * Self.pieceLength
        var contents: [Data] = []
        for (i, name) in ["e01.bin", "e02.bin", "e03.bin"].enumerated() {
            let data = Self.payload(count: fileSize, seed: UInt64(10 + i))
            contents.append(data)
            try data.write(to: root.appendingPathComponent(name))
        }
        let torrent = try TorrentCreator.createTorrent(at: root, pieceLength: Self.pieceLength)

        let seeder = try await Self.makeSeeder(torrent: torrent, saveDirectory: seedDir, encryption: .preferred)
        let leecher = try TorrentSession(configuration: .loopbackOnly())
        try await leecher.setBool("allow_multiple_connections_per_ip", true)

        // Magnet with only the info-hash: metadata must come from the peer. Hold the download so
        // priorities can be chosen before any piece is requested.
        let id = try await leecher.addMagnet(
            "magnet:?xt=urn:btih:\(seeder.id.hex)", savePath: downloadDir.path, options: .holdDownload)
        #expect(id == seeder.id)
        try await leecher.connectPeer(id, host: "127.0.0.1", port: seeder.port)

        let metadata = try await leecher.waitForMetadata(id, timeout: .seconds(20))
        #expect(metadata.files.map(\.size) == [Int64](repeating: Int64(fileSize), count: 3))
        #expect(metadata.files.map(\.offset) == [0, Int64(fileSize), Int64(2 * fileSize)])
        #expect(metadata.files.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["e01.bin", "e02.bin", "e03.bin"])
        #expect(metadata.pieceCount == 48)
        #expect(try await leecher.status(id).piecesHave == 0, "nothing is downloaded while held")

        // Want only the middle file, and ask for its pieces with deadlines in playback order.
        let events = leecher.events()
        try await leecher.setFilePriorities(id, [0, 7, 0])
        try await leecher.startDownload(id)
        for (n, piece) in (16..<32).enumerated() {
            try await leecher.setPieceDeadline(id, piece: piece, deadline: .milliseconds(200 + 50 * n))
        }
        _ = try await Self.consume(events) { event in
            if case .fileCompleted(_, 1) = event { return true }
            return false
        }

        let have = try await leecher.havePieces(id)
        #expect((0..<48).allSatisfy { have[$0] == (16..<32).contains($0) }, "only the wanted file's pieces")
        #expect(try await leecher.fileProgress(id, fileCount: 3) == [0, Int64(fileSize), 0])

        let piece = try await leecher.readPiece(id, piece: 20)
        #expect(piece == contents[1].subdata(in: 4 * Self.pieceLength..<5 * Self.pieceLength))
        let onDisk = try Data(contentsOf: downloadDir.appendingPathComponent(metadata.files[1].path))
        #expect(onDisk == contents[1])

        try await leecher.clearAllPieceDeadlines(id)
        await leecher.shutdown()
        await seeder.session.shutdown()
    }

    @Test("resume data restores a torrent, including its metadata")
    func resumeDataRoundTrip() async throws {
        let scratch = try Scratch()
        let seedDir = try scratch.directory("seed")
        let file = seedDir.appendingPathComponent("clip.bin")
        try Self.payload(count: 6 * Self.pieceLength, seed: 99).write(to: file)
        let torrent = try TorrentCreator.createTorrent(at: file, pieceLength: Self.pieceLength)

        let first = try await Self.makeSeeder(torrent: torrent, saveDirectory: seedDir, encryption: .preferred)
        let resume = try await first.session.saveResumeData(first.id)
        #expect(!resume.isEmpty)
        try await first.session.remove(first.id)
        await first.session.shutdown()

        let second = try TorrentSession(configuration: .loopbackOnly())
        let id = try await second.addResumeData(resume)  // save path comes from the resume data
        #expect(id == first.id)
        try await Self.eventually { try await second.status(id).state == .seeding }
        #expect(try await second.metadata(id).pieceCount == 6)
        #expect(try await second.havePieces(id).isComplete)
        await second.shutdown()
    }

    @Test("required encryption refuses a plaintext-only peer (so the encrypted run above is real)")
    func requiredEncryptionRejectsPlaintextPeer() async throws {
        let scratch = try Scratch()
        let seedDir = try scratch.directory("seed")
        let downloadDir = try scratch.directory("download")
        let file = seedDir.appendingPathComponent("clip.bin")
        try Self.payload(count: 8 * Self.pieceLength, seed: 7).write(to: file)
        let torrent = try TorrentCreator.createTorrent(at: file, pieceLength: Self.pieceLength)

        let seeder = try await Self.makeSeeder(torrent: torrent, saveDirectory: seedDir, encryption: .disabled)
        let leecher = try TorrentSession(configuration: .loopbackOnly(encryption: .required))
        try await leecher.setBool("allow_multiple_connections_per_ip", true)
        let id = try await leecher.addTorrent(data: torrent, savePath: downloadDir.path)
        try await leecher.connectPeer(id, host: "127.0.0.1", port: seeder.port)

        try await Task.sleep(for: .seconds(2))
        let status = try await leecher.status(id)
        #expect(status.piecesHave == 0)
        #expect(status.peerCount == 0)
        await leecher.shutdown()
        await seeder.session.shutdown()
    }

    @Test("operations on unknown torrents and closed sessions fail cleanly")
    func errorHandling() async throws {
        let session = try TorrentSession(configuration: .loopbackOnly())
        let bogus = TorrentID(hex: String(repeating: "ab", count: 20))
        await #expect(throws: TorrentError.notFound) { try await session.status(bogus) }
        await #expect(throws: TorrentError.invalidArgument) { try await session.setBool("no_such_setting", true) }
        await session.shutdown()
        await #expect(throws: TorrentError.sessionClosed) { try await session.status(bogus) }
    }

    @Test("remove returns only once the torrent is really gone, and re-adding the same download survives")
    func removeIsSynchronousWithTheEngine() async throws {
        let scratch = try Scratch()
        let directory = try scratch.directory("download")
        let file = directory.appendingPathComponent("clip.bin")
        try Self.payload(count: 8 * Self.pieceLength, seed: 11).write(to: file)
        let torrent = try TorrentCreator.createTorrent(at: file, pieceLength: Self.pieceLength)

        let session = try TorrentSession(configuration: .loopbackOnly())
        // The Play pipeline's shape: tear one attempt down, then immediately start the next one on
        // the same download. libtorrent keys torrents by info-hash and, while a removal is still
        // queued, hands back the *old* torrent for a new add -- which then vanishes underneath the
        // new attempt as "the download was removed".
        for round in 1...15 {
            let id = try await session.addTorrent(data: torrent, savePath: directory.path)
            try await session.remove(id, deleteFiles: true)

            // The torrent really is gone: `remove` did not return early.
            await #expect(throws: TorrentError.notFound) { try await session.status(id) }

            let events = session.events()  // subscribed after the removal we just caused
            let again = try await session.addTorrent(data: torrent, savePath: directory.path)
            #expect(again == id)
            let removals = await Self.collectRemovals(events, for: id, window: .milliseconds(300))
            #expect(removals.isEmpty, "round \(round): the replacement was handed the dying torrent")
            try await session.remove(again)
        }
        await session.shutdown()
    }

    @Test("a removal Marquee requested is reported as such, not as the engine dropping it")
    func removalEventNamesItsCause() async throws {
        let scratch = try Scratch()
        let directory = try scratch.directory("download")
        let file = directory.appendingPathComponent("clip.bin")
        try Self.payload(count: 4 * Self.pieceLength, seed: 13).write(to: file)
        let torrent = try TorrentCreator.createTorrent(at: file, pieceLength: Self.pieceLength)

        let session = try TorrentSession(configuration: .loopbackOnly())
        let events = session.events()
        let id = try await session.addTorrent(data: torrent, savePath: directory.path)
        try await session.remove(id)

        let seen = await Self.collectRemovals(events, for: id, window: .seconds(5))
        #expect(seen == [.requestedByApp])
        await session.shutdown()
    }

    /// Reasons reported for `id` during the next `window`. Empty means the torrent was left alone.
    private static func collectRemovals(
        _ stream: AsyncStream<TorrentEvent>, for id: TorrentID, window: Duration
    ) async -> [TorrentRemovalReason] {
        let collector = Task { () -> [TorrentRemovalReason] in
            var reasons: [TorrentRemovalReason] = []
            for await event in stream {
                if case let .removed(t, reason) = event, t == id { reasons.append(reason) }
            }
            return reasons
        }
        try? await Task.sleep(for: window)
        collector.cancel()  // ends the stream iteration
        return await collector.value
    }
}
