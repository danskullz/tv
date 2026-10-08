import Foundation
import Testing
@testable import MarqueeCore

// MARK: - Fixture model

struct PacksLayout: Decodable, Sendable {
    struct Daily: Decodable, Sendable { var date: String; var season: Int; var episode: Int }
    struct Series: Decodable, Sendable {
        var title: String
        var seasons: [String: Int]
        var specials: Int
        var absolute: Bool
        var daily: [Daily]
        var titles: [String: String]
        var unaired: [String]
        var targetSeasons: [Int]
        var aliases: [String]
    }
    struct FileEntry: Decodable, Sendable { var path: String; var size: Int64 }
    struct Expect: Decodable, Sendable {
        var files: [String: String]
        var gaps: [String]
        var conflicts: [String]
        var warnings: [String]
        var archiveSets: Int?
    }
    var name: String
    var series: Series
    var files: [FileEntry]
    var expect: Expect
}

func packsLoadLayouts(_ group: String) throws -> [PacksLayout] {
    let url = try #require(Bundle.module.url(forResource: group, withExtension: "json", subdirectory: "Fixtures/Packs"))
    return try JSONDecoder().decode([PacksLayout].self, from: Data(contentsOf: url))
}

let packsGroups = ["standard", "extras", "complete", "anime", "daily", "multi", "subs", "archives", "gaps", "odd", "hard"]

func packsContext(_ s: PacksLayout.Series) -> PackSeriesContext {
    var eps: [PackEpisode] = []
    var absolute = 0
    for season in s.seasons.keys.compactMap(Int.init).sorted() {
        for e in 1...(s.seasons[String(season)] ?? 0) {
            absolute += 1
            let ref = EpisodeRef(season: season, episode: e)
            eps.append(PackEpisode(
                ref: ref, absolute: s.absolute ? absolute : nil, title: s.titles[ref.description],
                isAired: !s.unaired.contains(ref.description)))
        }
    }
    if s.specials > 0 {
        for e in 1...s.specials { eps.append(PackEpisode(ref: EpisodeRef(season: 0, episode: e))) }
    }
    for d in s.daily {
        let p = d.date.split(separator: "-").compactMap { Int($0) }
        eps.append(PackEpisode(
            ref: EpisodeRef(season: d.season, episode: d.episode), airDate: AirDate(year: p[0], month: p[1], day: p[2])))
    }
    return PackSeriesContext(title: s.title, aliases: s.aliases, episodes: eps, targetSeasons: Set(s.targetSeasons))
}

func packsFiles(_ l: PacksLayout) -> [PackFile] {
    PackFile.layout(l.files.map { ($0.path, $0.size) })
}

/// Compact description of an assignment, in the grammar the fixtures use.
func packsDescribe(_ a: PackFileAssignment) -> String {
    let eps = a.episodes.map(\.description).joined(separator: "+")
    var s: String
    switch a.role {
    case .episode: s = "episode \(eps)"
    case .multiEpisode: s = "multi \(eps)"
    case .special: s = "special \(eps)"
    case .extra: s = "extra"
    case .sample: s = "sample"
    case .subtitle: s = eps.isEmpty ? "subtitle" : "subtitle \(eps)"
    case .archiveVolume: s = "archive \(eps)"
    case .nonMedia: s = a.isSuspicious ? "nonMedia!" : "nonMedia"
    }
    return (a.isPreferred ? "" : "dup ") + s.trimmingCharacters(in: .whitespaces)
}

struct PacksOutcome {
    var fileTotal = 0
    var fileMatches = 0
    var mismatches: [String] = []
}

func packsEvaluate(_ l: PacksLayout, corrections: [Int: [EpisodeRef]] = [:]) -> PacksOutcome {
    let files = packsFiles(l)
    let result = PackFileMapper.map(files: files, series: packsContext(l.series), corrections: corrections)
    var out = PacksOutcome()
    for a in result.assignments {
        out.fileTotal += 1
        let expected = l.expect.files[a.path]
        let actual = packsDescribe(a)
        if expected == actual {
            out.fileMatches += 1
        } else {
            out.mismatches.append("[\(l.name)] \(a.path)\n      expected: \(expected ?? "<none>")\n      actual:   \(actual)   (\(a.reason), conf \(String(format: "%.2f", a.confidence)))")
        }
    }
    func layoutCheck(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        out.fileTotal += 1
        if ok { out.fileMatches += 1 } else { out.mismatches.append("[\(l.name)] \(label): \(detail())") }
    }
    let gaps = result.gaps.map(\.description)
    layoutCheck("gaps", gaps == l.expect.gaps, "expected \(l.expect.gaps) got \(gaps)")
    let conflicts = Set(result.conflicts.map(\.episode.description))
    layoutCheck("conflicts", conflicts == Set(l.expect.conflicts), "expected \(l.expect.conflicts.sorted()) got \(conflicts.sorted())")
    if let n = l.expect.archiveSets {
        layoutCheck("archiveSets", result.archiveSets.count == n, "expected \(n) got \(result.archiveSets.count)")
    }
    for w in l.expect.warnings {
        let ok: Bool
        if w.hasPrefix("suspicious:") {
            let path = String(w.dropFirst("suspicious:".count))
            ok = result.warnings.contains { if case .suspiciousExecutable(let i) = $0 { return files[i].path == path } else { return false } }
        } else if w == "titleMismatch" {
            ok = result.warnings.contains { if case .titleMismatch = $0 { return true } else { return false } }
        } else {
            ok = result.warnings.contains { if case .incompleteArchive = $0 { return true } else { return false } }
        }
        layoutCheck("warning \(w)", ok, "missing; got \(result.warnings)")
    }
    return out
}
