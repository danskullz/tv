import Foundation
import Testing
@testable import MarqueeCore

@Suite(.serialized) struct StreamingThroughputTests {
    #if DEBUG
    static let thresholdMBps = 100.0     // unoptimised builds: only catch pathological regressions
    #else
    static let thresholdMBps = 200.0     // release gate from the task spec
    #endif

    @Test func loopbackThroughputFromTempFile() async throws {
        let dir = TempDir()
        let size: Int64 = 200 * 1024 * 1024
        let file = dir.makePatternFile(size: size)
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(try FileByteSource(url: file), filename: "big.mkv")

        // Warm-up (page cache, connection setup).
        _ = try await ByteCounter().run(url: ep.url)

        var best = 0.0
        for _ in 0..<3 {
            let (bytes, seconds) = try await ByteCounter().run(url: ep.url)
            #expect(bytes == size)
            best = max(best, Double(bytes) / 1_000_000 / seconds)
        }
        print("STREAM THROUGHPUT best of 3: \(Int(best)) MB/s (threshold \(Int(Self.thresholdMBps)) MB/s)")
        #expect(best > Self.thresholdMBps)
    }

    @Test func largeRangeBytesAreCorrect() async throws {
        // Integrity check across many chunks of a big range (not just a byte count).
        let dir = TempDir()
        let size: Int64 = 40 * 1024 * 1024
        let file = dir.makePatternFile(size: size)
        let server = StreamServer(chunkSize: 100_000)  // odd chunk size exercises boundary maths
        defer { Task { await server.stop() } }
        let ep = try await server.register(try FileByteSource(url: file), filename: "big.mkv")
        let (data, resp) = try await fetch(ep.url, headers: ["Range": "bytes=12345-\(size - 54321)"], session: makeSession())
        #expect(resp.statusCode == 206)
        let expectedCount = Int(size - 54321 - 12345 + 1)
        #expect(data.count == expectedCount)
        #expect(data == patternBytes(offset: 12345, count: expectedCount))
    }
}
