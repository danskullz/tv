import Foundation
import Testing
@testable import MarqueeCore

@Suite struct StreamingFileByteSourceTests {
    @Test func readsRanges() async throws {
        let dir = TempDir()
        let url = dir.makePatternFile(size: 3_000_000)
        let src = try FileByteSource(url: url)
        #expect(src.length == 3_000_000)
        #expect(src.contentType == "video/x-matroska")
        #expect(try await src.read(offset: 0, length: 10) == patternBytes(offset: 0, count: 10))
        #expect(try await src.read(offset: 1_048_570, length: 20) == patternBytes(offset: 1_048_570, count: 20))
        // clamps at EOF, empty beyond it
        #expect(try await src.read(offset: 2_999_990, length: 100) == patternBytes(offset: 2_999_990, count: 10))
        #expect(try await src.read(offset: 3_000_000, length: 10).isEmpty)
        #expect(try await src.read(offset: 5, length: 0).isEmpty)
    }

    @Test func rejectsBadArgumentsAndMissingFile() async throws {
        let dir = TempDir()
        let url = dir.makePatternFile(size: 100)
        let src = try FileByteSource(url: url)
        await #expect(throws: StreamSourceError.invalidRange) { try await src.read(offset: -1, length: 1) }
        #expect(throws: StreamSourceError.self) { try FileByteSource(url: dir.url.appendingPathComponent("nope.mkv")) }
    }

    @Test func zeroLengthFile() async throws {
        let dir = TempDir()
        let url = dir.makePatternFile(name: "empty.mp4", size: 0)
        let src = try FileByteSource(url: url)
        #expect(src.length == 0)
        #expect(try await src.read(offset: 0, length: 10).isEmpty)
    }
}

@Suite struct StreamingGrowingFileByteSourceTests {
    // 10 pieces x 100 KiB; the "file" is the whole torrent.
    static let pieceLength: Int64 = 100 * 1024
    static let size: Int64 = 10 * 100 * 1024

    func makeSource(dir: TempDir, completed: [Int]) -> (GrowingFileByteSource, ManualAvailability) {
        let url = dir.makePatternFile(name: "grow.mp4", size: Self.size)
        let map = PieceMap(pieceLength: Self.pieceLength, torrentSize: Self.size, fileOffset: 0, fileLength: Self.size)!
        let avail = ManualAvailability(pieceCount: 10, completed: completed)
        return (GrowingFileByteSource(url: url, pieceMap: map, availability: avail), avail)
    }

    @Test func readsAvailableDataImmediately() async throws {
        let dir = TempDir()
        let (src, _) = makeSource(dir: dir, completed: [0, 1])
        let data = try await src.read(offset: 50_000, length: 100_000)  // spans pieces 0 and 1
        #expect(data == patternBytes(offset: 50_000, count: 100_000))
    }

    @Test func blocksUntilPieceArrives() async throws {
        let dir = TempDir()
        let (src, avail) = makeSource(dir: dir, completed: [0])
        let start = ContinuousClock.now
        let reader = Task { try await src.read(offset: Self.pieceLength * 3, length: 1000) }
        try await Task.sleep(for: .milliseconds(150))
        avail.complete([5])  // unrelated piece
        try await Task.sleep(for: .milliseconds(100))
        avail.complete([3])
        let data = try await reader.value
        #expect(ContinuousClock.now - start >= .milliseconds(240))
        #expect(data == patternBytes(offset: Self.pieceLength * 3, count: 1000))
    }

    @Test func readSpanningTwoPiecesNeedsBoth() async throws {
        let dir = TempDir()
        let (src, avail) = makeSource(dir: dir, completed: [])
        let reader = Task { try await src.read(offset: Self.pieceLength - 10, length: 20) }
        try await Task.sleep(for: .milliseconds(50))
        avail.complete([0])
        try await Task.sleep(for: .milliseconds(100))
        avail.complete([1])
        #expect(try await reader.value == patternBytes(offset: Self.pieceLength - 10, count: 20))
    }

    @Test func piecesCompletedBetweenSubscribeAndSnapshotAreNotLost() async throws {
        let dir = TempDir()
        let (src, avail) = makeSource(dir: dir, completed: [])
        avail.complete([2])  // before first use of the source
        #expect(try await src.read(offset: Self.pieceLength * 2, length: 10).count == 10)
    }

    @Test func manyConcurrentWaiters() async throws {
        let dir = TempDir()
        let (src, avail) = makeSource(dir: dir, completed: [])
        let readers = (0..<10).map { p in
            Task { try await src.read(offset: Int64(p) * Self.pieceLength, length: 64) }
        }
        try await Task.sleep(for: .milliseconds(50))
        avail.complete((0..<10).reversed())
        for (p, r) in readers.enumerated() {
            #expect(try await r.value == patternBytes(offset: Int64(p) * Self.pieceLength, count: 64))
        }
    }

    @Test func cancellationWakesWaitingRead() async throws {
        let dir = TempDir()
        let (src, _) = makeSource(dir: dir, completed: [])
        let reader = Task { try await src.read(offset: 0, length: 10) }
        try await Task.sleep(for: .milliseconds(100))
        let t0 = ContinuousClock.now
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
        #expect(ContinuousClock.now - t0 < .seconds(1))
    }

    @Test func providerFinishingFailsWaiters() async throws {
        let dir = TempDir()
        let (src, avail) = makeSource(dir: dir, completed: [0])
        let reader = Task { try await src.read(offset: Self.pieceLength * 4, length: 10) }
        try await Task.sleep(for: .milliseconds(50))
        avail.finish()
        await #expect(throws: StreamSourceError.unavailable) { try await reader.value }
        // Subsequent reads of missing data fail fast; available data still works.
        await #expect(throws: StreamSourceError.unavailable) { try await src.read(offset: Self.pieceLength * 4, length: 10) }
        #expect(try await src.read(offset: 0, length: 10).count == 10)
    }

    @Test func prioritizeForwardsPieceRange() async throws {
        let dir = TempDir()
        let (src, avail) = makeSource(dir: dir, completed: [])
        await src.prioritize(offset: Self.pieceLength * 2 + 5, length: Int(Self.pieceLength))  // straddles 2 and 3
        await src.prioritize(offset: 0, length: 0)
        #expect(avail.prioritized == [2..<4])
    }

    @Test func clampsAtEndAndRejectsNegative() async throws {
        let dir = TempDir()
        let (src, _) = makeSource(dir: dir, completed: Array(0..<10))
        #expect(try await src.read(offset: Self.size - 5, length: 100) == patternBytes(offset: Self.size - 5, count: 5))
        #expect(try await src.read(offset: Self.size, length: 100).isEmpty)
        await #expect(throws: StreamSourceError.invalidRange) { try await src.read(offset: -5, length: 1) }
    }
}
