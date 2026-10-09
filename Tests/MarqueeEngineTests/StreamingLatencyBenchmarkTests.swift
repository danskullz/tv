import Foundation
import MarqueeCore
import Testing
import TorrentEngine

@testable import MarqueeEngine

/// Time to first byte and seek latency against a throttled loopback seeder, for several controller
/// configurations. Opt in with `MARQUEE_BENCH=1`; it prints a table and asserts the targets for the
/// shipped defaults. `MARQUEE_BENCH_RUNS` sets the iteration count (default 5).
@Suite("Streaming latency benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MARQUEE_BENCH"] == "1"))
struct StreamingLatencyBenchmarkTests {
    struct Variant: CustomStringConvertible, Sendable {
        var name: String
        var tuning: StreamingTuning
        var budget: Int64?
        var seederTick: Int?
        var description: String { name }
    }

    static let variants: [Variant] = {
        var v: [Variant] = []
        for tick in [100, 500] {
            v.append(Variant(name: "legacy (no tuning, full window), seeder tick \(tick)", tuning: .disabled, budget: nil, seederTick: tick))
        }
        v.append(Variant(name: "defaults, seeder tick 500", tuning: StreamingTuning(), budget: 1 << 20, seederTick: nil))
        for tick in [20, 50, 100] {
            var t = StreamingTuning()
            t.activeTickInterval = tick
            v.append(Variant(name: "defaults with leecher tick \(tick), seeder tick 100", tuning: t, budget: 1 << 20, seederTick: 100))
        }
        return v
    }()

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    @Test("first byte and seek latency by configuration")
    func benchmark() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["MARQUEE_BENCH_RUNS"] ?? "") ?? 5
        let scratch = try EngineScratch()
        let seedDir = try scratch.directory("seed")
        let pack = try EnginePack.make(in: seedDir)
        var rows: [String] = []
        var defaultsFirst: [Double] = []
        var defaultsSeek: [Double] = []

        for variant in Self.variants {
            let seeder = try await engineMakeSeeder(torrent: pack.torrent, saveDirectory: seedDir, uploadLimit: 2_000_000)
            if let tick = variant.seederTick { try await seeder.session.setInt("tick_interval", tick) }
            var firsts: [Double] = []
            var seeks: [Double] = []
            for run in 0..<runs {
                let download = try scratch.directory("dl-\(variant.name.hashValue)-\(run)")
                let leecher = try await engineMakeLeecher()
                let server = StreamServer()
                var options = StreamPlanOptions()
                options.rolloverBytes = 2 << 20
                let controller = StreamSessionController(
                    session: leecher, server: server,
                    configuration: StreamControllerConfiguration(
                        savePath: download, planOptions: options, deadlineBudgetBytes: variant.budget,
                        tuning: variant.tuning, stallTimeout: .seconds(30)))
                let t0 = ContinuousClock.now
                let handle = try await controller.start(
                    source: .torrentFile(pack.torrent), content: .series(EnginePack.series()),
                    startEpisode: EpisodeRef(season: 1, episode: 1),
                    peers: [PeerEndpoint(host: "127.0.0.1", port: seeder.port)])
                let http = engineSession()
                let first = try await engineFetch(handle.url, range: 0..<(1 << 20), session: http)
                firsts.append((ContinuousClock.now - t0 - first.total + first.firstByte).engineMilliseconds)
                #expect(first.data == pack.episodes[0].prefix(1 << 20))
                let length = Int64(pack.episodes[0].count)
                for fraction in [6, 8] {  // two seeks, to fresh places
                    let offset = length * Int64(fraction) / 10 / 65_536 * 65_536 + 1000
                    let seek = try await engineFetch(handle.url, range: offset..<(offset + 262_144), session: http)
                    #expect(seek.data == pack.episodes[0].subdata(in: Int(offset)..<Int(offset) + 262_144))
                    seeks.append(seek.firstByte.engineMilliseconds)
                }
                await controller.stop()
                await server.stop()
                await leecher.shutdown()
            }
            await seeder.session.shutdown()
            let f = firsts.map { String(format: "%.0f", $0) }.joined(separator: " ")
            let s = seeks.map { String(format: "%.0f", $0) }.joined(separator: " ")
            rows.append("""
                [bench] \(variant.name)
                        first byte ms (median \(String(format: "%.0f", Self.median(firsts)))): \(f)
                        seek first byte ms (median \(String(format: "%.0f", Self.median(seeks)))): \(s)
                """)
            if variant.name == "defaults with leecher tick 100, seeder tick 100" {
                defaultsFirst = firsts
                defaultsSeek = seeks
            }
        }
        print(rows.joined(separator: "\n"))
        #expect(Self.median(defaultsFirst) < 1500, "first byte target < 1.5 s")
        #expect(Self.median(defaultsSeek) < 1000, "seek first byte target < 1 s")
    }
}
