import Foundation
import GRDB
import Testing

@testable import MarqueeCore

@Suite struct PersistenceSearchTests {
    #if DEBUG
    static let budgetMs = 250.0  // debug builds are far slower than release; the gate is release
    #else
    static let budgetMs = 50.0
    #endif

    @Test func searchOver10kTitlesIsFast() async throws {
        let database = try AppDatabase.inMemory()
        let library = GRDBLibraryRepository(database)

        let words = [
            "dark", "city", "night", "river", "silent", "storm", "golden", "lost", "empire", "ghost",
            "winter", "iron", "crown", "shadow", "last", "road", "blue", "falcon", "garden", "echo",
            "paper", "glass", "wild", "island", "signal", "harbor", "ember", "valley", "orbit", "mirror",
        ]
        try await database.writer.write { db in
            for i in 0..<10_000 {
                let name = (0..<3).map { _ in words.randomElement()! }.joined(separator: " ")
                let overview = (0..<30).map { _ in words.randomElement()! }.joined(separator: " ")
                try Title(kind: i % 3 == 0 ? .movie : .series, tmdbId: i, title: name.capitalized, overview: overview).insert(db)
            }
        }
        #expect(try await database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM titleSearch") } == 10_000)

        // Warm up, then take the worst of several runs for each typical keystroke prefix.
        _ = try await library.searchLibrary(query: "dar", limit: 50)
        var worst = 0.0
        for query in ["d", "da", "dar", "dark ci", "silent sto", "gold emp", "zzz"] {
            for _ in 0..<5 {
                let start = ContinuousClock.now
                let results = try await library.searchLibrary(query: query, limit: 50)
                let ms = start.duration(to: .now).milliseconds
                worst = max(worst, ms)
                #expect(results.count <= 50)
            }
        }
        print("searchLibrary worst latency over 10k titles: \(String(format: "%.1f", worst)) ms (budget \(Self.budgetMs) ms)")
        #expect(worst < Self.budgetMs)
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
