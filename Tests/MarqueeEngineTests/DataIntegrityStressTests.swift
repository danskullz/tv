import Foundation
import MarqueeCore
import Testing
import TorrentEngine

@testable import MarqueeEngine

/// Hammers `TorrentFileByteSource` with reads that land exactly when pieces complete, and with random
/// seeks, and compares every byte with the seeded content.
///
/// Background: libtorrent 2.0's mmap disk I/O keeps freshly received blocks in a store buffer and may
/// hash (and so report `piece_finished`) before the write job has put them into the file. A reader that
/// trusts the event alone can read zeros. These tests guard the fix for that.
///
/// The default run is short; set `MARQUEE_STRESS=1` for a long soak.
@Suite("Data integrity under load", .serialized)
struct DataIntegrityStressTests {
    private static var soak: Bool { ProcessInfo.processInfo.environment["MARQUEE_STRESS"] == "1" }

    enum Tuning: CaseIterable, CustomStringConvertible {
        case defaults
        case smallRequestQueue
        /// libtorrent's parallel disk pool: reproduces the original bug (zeros right after piece_finished).
        case parallelDisk
        var description: String {
            switch self {
            case .defaults: "default settings"
            case .smallRequestQueue: "small request queue"
            case .parallelDisk: "parallel disk pool (unsafe)"
            }
        }
        static var safe: [Tuning] { [.defaults, .smallRequestQueue] }
    }

    private static let pieceLength = 16 * 1024

    private static func makeSwarm(
        scratch: EngineScratch, size: Int, seed: UInt64, uploadLimit: Int?, tuning: Tuning
    ) async throws -> (content: Data, torrent: Data, seeder: (session: TorrentSession, id: TorrentID, port: Int), leecher: TorrentSession, download: URL, name: String) {
        let seedDir = try scratch.directory("seed-\(seed)")
        let download = try scratch.directory("download-\(seed)")
        let name = "clip-\(seed).mkv"
        let content = enginePayload(count: size, seed: seed)
        try content.write(to: seedDir.appendingPathComponent(name))
        let torrent = try TorrentCreator.createTorrent(at: seedDir.appendingPathComponent(name), pieceLength: pieceLength)
        let seeder = try await engineMakeSeeder(torrent: torrent, saveDirectory: seedDir, uploadLimit: uploadLimit)
        let leecher = try await engineMakeLeecher(orderedDiskIO: tuning != .parallelDisk)
        if tuning == .smallRequestQueue {
            try await leecher.setInt("max_out_request_queue", 24)
            try await leecher.setInt("request_queue_time", 1)
        }
        return (content, torrent, seeder, leecher, download, name)
    }

    /// Reads every piece the moment it is reported complete (the race window), in parallel with random
    /// unaligned reads that straddle piece boundaries.
    fileprivate static func hammer(iterations: Int, size: Int, uploadLimit: Int?, tuning: Tuning, readers: Int) async throws -> (reads: Int, mismatches: [String]) {
        var reads = 0
        var mismatches: [String] = []
        for iteration in 0..<iterations {
            let scratch = try EngineScratch()
            let swarm = try await makeSwarm(
                scratch: scratch, size: size, seed: UInt64(1000 + iteration), uploadLimit: uploadLimit, tuning: tuning)
            let id = try await swarm.leecher.addTorrent(
                data: swarm.torrent, savePath: swarm.download.path, options: .holdDownload)
            let metadata = try await swarm.leecher.metadata(id)
            let file = metadata.files[0]
            let map = try #require(TorrentFileByteSource.pieceMap(for: file, in: metadata))
            let availability = TorrentPieceAvailability(
                session: swarm.leecher, torrent: id, fileIndex: 0, pieceMap: map)
            let source = TorrentFileByteSource(savePath: swarm.download, file: file, pieceMap: map, availability: availability)
            let content = swarm.content

            // Event-driven reader: every completed piece is read back immediately.
            let events = swarm.leecher.events()
            let followed = EngineCollector<String>()
            let followedCount = EngineCollector<Int>()
            let follower = Task {
                await withTaskGroup(of: Void.self) { group in
                    for await event in events {
                        guard case let .pieceFinished(t, piece) = event, t == id else { continue }
                        group.addTask {
                            let range = map.fileByteRange(ofPiece: piece)
                            guard let data = try? await source.read(offset: range.lowerBound, length: Int(range.count)) else {
                                followed.add("piece \(piece): read failed")
                                return
                            }
                            followedCount.add(1)
                            if data != content.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) {
                                let zeros = data.filter { $0 == 0 }.count
                                followed.add("piece \(piece) mismatch right after piece_finished (\(zeros) zero bytes of \(data.count))")
                            }
                        }
                    }
                }
            }

            // Random unaligned reads, many at once.
            let randomMismatches = EngineCollector<String>()
            let randomCount = EngineCollector<Int>()
            var generator = SeededGenerator(seed: UInt64(iteration) &+ 77)
            let jobs: [(Int64, Int)] = (0..<(readers * 4)).map { _ in
                let length = Int.random(in: 1...(5 * pieceLength), using: &generator)
                let offset = Int64.random(in: 0...(Int64(size - length)), using: &generator)
                return (offset, length)
            }
            try await leecher(swarm.leecher, connect: id, port: swarm.seeder.port)
            await withTaskGroup(of: Void.self) { group in
                for (offset, length) in jobs {
                    group.addTask {
                        guard let data = try? await source.read(offset: offset, length: length) else {
                            randomMismatches.add("read \(offset)+\(length) failed")
                            return
                        }
                        randomCount.add(1)
                        if data != content.subdata(in: Int(offset)..<Int(offset) + length) {
                            randomMismatches.add("random read \(offset)+\(length) mismatched")
                        }
                    }
                }
            }
            try await engineEventually(.seconds(60), "download complete") { try await swarm.leecher.status(id).progress == 1 }
            try await Task.sleep(for: .milliseconds(100))
            follower.cancel()
            reads += followedCount.all.count + randomCount.all.count
            mismatches += followed.all + randomMismatches.all
            await swarm.leecher.shutdown()
            await swarm.seeder.session.shutdown()
        }
        return (reads, mismatches)
    }

    private static func leecher(_ session: TorrentSession, connect id: TorrentID, port: Int) async throws {
        try await session.connectPeer(id, host: "127.0.0.1", port: port)
        try await session.startDownload(id)
    }

    @Test("pieces read the instant they are reported are intact (unthrottled loopback)", arguments: Tuning.safe)
    func readAfterPieceFinished(tuning: Tuning) async throws {
        let result = try await Self.hammer(
            iterations: Self.soak ? 40 : 4, size: 6 * 1_048_576 + 999, uploadLimit: nil, tuning: tuning, readers: 64)
        #expect(result.mismatches.isEmpty, "\(result.mismatches.prefix(5)) of \(result.mismatches.count) in \(result.reads) reads (\(tuning))")
        #expect(result.reads > 0)
    }

    @Test("pieces read the instant they are reported are intact (throttled loopback)", arguments: Tuning.safe)
    func readAfterPieceFinishedThrottled(tuning: Tuning) async throws {
        let result = try await Self.hammer(
            iterations: Self.soak ? 12 : 1, size: 3 * 1_048_576 + 333, uploadLimit: 3_000_000, tuning: tuning, readers: 32)
        #expect(result.mismatches.isEmpty, "\(result.mismatches.prefix(5)) of \(result.mismatches.count) in \(result.reads) reads (\(tuning))")
        #expect(result.reads > 0)
    }
}

extension DataIntegrityStressTests {
    /// Documents the root cause: with libtorrent's default parallel disk pool, reading a piece the moment
    /// it is reported can return zeros. Opt in with `MARQUEE_STRESS_UNSAFE=1`; it only reports the
    /// mismatches it finds, so it is not part of any normal run.
    @Test("parallel disk pool shows the bug", .enabled(if: ProcessInfo.processInfo.environment["MARQUEE_STRESS_UNSAFE"] == "1"))
    func parallelDiskReproducesBug() async throws {
        let result = try await Self.hammer(iterations: 20, size: 6 * 1_048_576 + 999, uploadLimit: nil, tuning: .parallelDisk, readers: 64)
        print("[stress-unsafe] \(result.mismatches.count) mismatches in \(result.reads) reads: \(result.mismatches.prefix(3))")
    }
}

/// Deterministic generator so a failing iteration can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
