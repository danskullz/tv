import Foundation
import Testing
@testable import MarqueeCore

private struct Scenario: Decodable, Sendable {
    struct Wanted: Decodable {
        var type: String
        var title: String
        var aliases: [String]?
        var year: Int?
        var season: Int?
        var episodes: [Int]?
        var absolute: [Int]?
        var runtime: Double?
        var seasonEpisodeCount: Int?
        var episodeCount: Int?
    }
    struct Current: Decodable { var tier: QualityTier; var score: Int }
    struct Release: Decodable {
        var title: String
        var seeders: Int
        var sizeGB: Double
        var ageHours: Double
        var indexer: String?
        var guid: String?
        var hash: String?
    }

    var name: String
    var now: String
    var profile: String
    var wanted: Wanted
    var current: Current?
    var minimumSeeders: Int?
    var freeSpaceGB: Double?
    var blocklistHashes: [String]?
    var indexerPriorities: [String: Int]?
    var expectTop: String?
    var expectTopIndexer: String?
    var expectOrder: [String]?
    var expectAccepted: [String]?
    var expectRejections: [String: [String]]?
    var releases: [Release]

    var wantedItem: WantedItem {
        switch wanted.type {
        case "movie":
            return .movie(wanted.title, year: wanted.year, runtimeMinutes: wanted.runtime, aliases: wanted.aliases ?? [])
        case "season":
            return .season(wanted.title, season: wanted.season ?? 1, episodeCount: wanted.episodeCount,
                           runtimeMinutes: wanted.runtime, aliases: wanted.aliases ?? [])
        default:
            return .episode(wanted.title, season: wanted.season, episodes: wanted.episodes ?? [], absolute: wanted.absolute ?? [],
                            runtimeMinutes: wanted.runtime, seasonEpisodeCount: wanted.seasonEpisodeCount,
                            aliases: wanted.aliases ?? [])
        }
    }

    var qualityProfileValue: QualityProfileConfig {
        QualityProfileConfig.presets.first { $0.name.lowercased() == profile }!
    }

    func run() -> [ReleaseDecision] {
        let now = ISO8601DateFormatter().date(from: self.now)!
        var blocklist = ReleaseBlocklist()
        for hash in blocklistHashes ?? [] { blocklist.add(infoHash: hash, title: nil, reason: "failed earlier") }
        let context = DecisionContext(
            wanted: wantedItem, profile: qualityProfileValue, formats: BuiltInFormats.all,
            current: current.map { CurrentFile(tier: $0.tier, formatScore: $0.score) }, blocklist: blocklist,
            minimumSeeders: minimumSeeders ?? 1, freeSpaceBytes: freeSpaceGB.map { Int64($0 * 1_073_741_824) },
            now: now, indexerPriorities: Dictionary(uniqueKeysWithValues: (indexerPriorities ?? [:]).map { (qualityIndexerID($0.key), $0.value) }))
        let candidates = releases.map {
            qualityMakeCandidate(
                $0.title, seeders: $0.seeders, sizeGB: $0.sizeGB, ageHours: $0.ageHours, indexer: $0.indexer ?? "A",
                guid: $0.guid, hash: $0.hash, now: now)
        }
        return ReleaseDecisionEngine.decide(candidates, in: context)
    }
}

private let scenarioFiles = [
    "movie-4k-and-1080p", "tv-episode-with-pack", "anime", "upgrade", "all-rejected", "tv-season",
]

private func loadScenario(_ name: String) throws -> Scenario {
    try JSONDecoder().decode(Scenario.self, from: qualityFixtureData("\(name).json"))
}

@Suite struct QualityScenarioTests {
    @Test func fixtureCorpusHasAtLeastSixtyReleases() throws {
        let total = try scenarioFiles.reduce(0) { $0 + (try loadScenario($1)).releases.count }
        #expect(total >= 60)
    }

    @Test(arguments: scenarioFiles)
    func scenarioMatchesExpectations(_ file: String) throws {
        let scenario = try loadScenario(file)
        let decisions = scenario.run()
        #expect(decisions.count == scenario.releases.count)

        let accepted = decisions.accepted
        if let top = scenario.expectTop {
            #expect(accepted.first?.candidate.release.title == top, "\(scenario.name): top pick")
            if let indexer = scenario.expectTopIndexer {
                #expect(accepted.first?.candidate.release.indexerName == indexer)
            }
        } else {
            #expect(accepted.isEmpty, "\(scenario.name): nothing should be accepted, got \(accepted.map(\.candidate.release.title))")
        }

        if let order = scenario.expectOrder {
            let actual = accepted.prefix(order.count).map(\.candidate.release.title)
            #expect(actual == order, "\(scenario.name): order")
        }
        for title in scenario.expectAccepted ?? [] {
            let decision = decisions.first { $0.candidate.release.title == title }
            #expect(decision?.isAccepted == true, "\(title) should be accepted, got \(decision?.rejections.map(\.code) ?? [])")
        }
        for (title, codes) in scenario.expectRejections ?? [:] {
            guard let decision = decisions.first(where: { $0.candidate.release.title == title }) else {
                Issue.record("missing release \(title)")
                continue
            }
            #expect(Set(decision.rejections.map(\.code)) == Set(codes), "\(title): got \(decision.rejections.map(\.code))")
        }
        // Accepted decisions always precede rejected ones and carry consecutive ranks.
        #expect(decisions.prefix(accepted.count).allSatisfy { $0.isAccepted })
        #expect(accepted.map(\.rank) == (1...max(accepted.count, 1)).prefix(accepted.count).map { Optional($0) })
    }

    @Test func rejectionsHaveHumanReadableMessages() throws {
        for file in scenarioFiles {
            for decision in try loadScenario(file).run() where !decision.isAccepted {
                let text = decision.explanation.text
                #expect(text.hasPrefix("Rejected: "))
                #expect(!text.contains("Optional("))
            }
        }
    }
}
