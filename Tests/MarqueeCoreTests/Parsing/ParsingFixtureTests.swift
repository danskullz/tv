import Foundation
import Testing
@testable import MarqueeCore

/// One fixture row: an input (`name` or `path`) plus the subset of fields that must match.
struct ParsingFixtureCase: Decodable, Sendable {
    var name: String?
    var path: String?
    var title: String?
    var year: Int?
    var kind: String?
    var seasons: [Int]?
    var episodes: [Int]?
    var absolute: [Int]?
    var airDate: String?
    var special: Bool?
    var resolution: Int?
    var source: String?
    var videoCodec: String?
    var hdr: [String]?
    var bitDepth: Int?
    var audio: [String]?
    var channels: String?
    var languages: [String]?
    var group: String?
    var crc32: String?
    var version: Int?
    var editions: [String]?
    var service: String?
    var container: String?
    var flags: [String]?
    var episodeTitle: String?

    var input: String { path ?? name ?? "" }
}

enum ParsingFixtures {
    static let files = ["movies", "tv-episodes", "packs", "anime", "daily", "foreign", "files"]

    static func load(_ file: String) throws -> [ParsingFixtureCase] {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures/Parsing"))
        return try JSONDecoder().decode([ParsingFixtureCase].self, from: Data(contentsOf: url))
    }

    /// Human-readable list of fields where `r` disagrees with the fixture; empty means a full match.
    static func mismatches(_ c: ParsingFixtureCase, _ r: ParsedRelease) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ label: String, _ expected: T?, _ actual: T?) {
            if let e = expected, e != actual { out.append("\(label): expected \(e), got \(actual.map { "\($0)" } ?? "nil")") }
        }
        if let t = c.title, ReleaseParser.normalizeTitle(t) != r.normalizedTitle {
            out.append("title: expected \(t), got \(r.title)")
        }
        check("year", c.year, r.year)
        check("kind", c.kind, r.kind.rawValue)
        check("seasons", c.seasons, r.seasons)
        check("episodes", c.episodes, r.episodes)
        check("absolute", c.absolute, r.absoluteEpisodes)
        check("airDate", c.airDate, r.airDate?.description)
        check("special", c.special, r.isSpecial)
        check("resolution", c.resolution, r.resolution?.rawValue)
        check("source", c.source, r.source?.rawValue)
        check("videoCodec", c.videoCodec, r.videoCodec?.rawValue)
        check("hdr", c.hdr, r.hdr.map(\.rawValue))
        check("bitDepth", c.bitDepth, r.bitDepth)
        check("audio", c.audio, r.audioCodecs.map(\.rawValue))
        check("channels", c.channels, r.audioChannels)
        check("languages", c.languages, r.languages.map(\.rawValue))
        check("group", c.group, r.releaseGroup)
        check("crc32", c.crc32, r.crc32)
        check("version", c.version, r.version)
        check("editions", c.editions, r.editions.map(\.rawValue))
        check("service", c.service, r.streamingService)
        check("container", c.container, r.container)
        if let f = c.flags, Set(f) != Set(r.flags.map(\.rawValue)) {
            out.append("flags: expected \(f.sorted()), got \(r.flags.map(\.rawValue).sorted())")
        }
        if let e = c.episodeTitle, ReleaseParser.normalizeTitle(e) != ReleaseParser.normalizeTitle(r.episodeTitle ?? "") {
            out.append("episodeTitle: expected \(e), got \(r.episodeTitle ?? "nil")")
        }
        return out
    }
}

@Suite("Release parser fixture corpus")
struct ParsingFixtureCorpusTests {
    @Test func corpusAccuracyMeetsReleaseGate() throws {
        var total = 0
        var correct = 0
        var failures: [String] = []
        var fieldChecks = 0
        var fieldMisses = 0
        for file in ParsingFixtures.files {
            let cases = try ParsingFixtures.load(file)
            var fileCorrect = 0
            for c in cases {
                let r = c.path != nil ? ReleaseParser.parseFileName(c.input) : ReleaseParser.parse(c.input)
                let m = ParsingFixtures.mismatches(c, r)
                total += 1
                if m.isEmpty {
                    correct += 1
                    fileCorrect += 1
                } else {
                    failures.append("[\(file)] \(c.input)\n      " + m.joined(separator: "\n      "))
                }
                fieldMisses += m.count
                fieldChecks += Mirror(reflecting: c).children.filter { child in
                    if child.label == "name" || child.label == "path" { return false }
                    if case Optional<Any>.none = child.value { return false }
                    return true
                }.count
            }
            print("parser fixtures \(file): \(fileCorrect)/\(cases.count)")
        }
        let accuracy = Double(correct) / Double(total)
        print("parser fixtures overall: \(correct)/\(total) = \(String(format: "%.2f", accuracy * 100))% fully correct; field accuracy \(String(format: "%.2f", 100 * (1 - Double(fieldMisses) / Double(max(fieldChecks, 1)))))%")
        for f in failures { print("MISMATCH " + f) }
        #expect(total >= 400, "fixture corpus must contain at least 400 names (has \(total))")
        let report = "accuracy \(accuracy) below 0.98; failures:\n" + failures.joined(separator: "\n")
        #expect(accuracy >= 0.98, Comment(rawValue: report))
    }

    @Test func parsedReleaseRoundTripsThroughCodable() throws {
        let r = ReleaseParser.parse("Show.Name.S01E05.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ParsedRelease.self, from: data)
        #expect(back == r)
    }
}
