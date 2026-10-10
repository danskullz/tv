import Foundation
import Testing

@testable import MarqueeCore

/// Stress harness for ``PackFileMapper``. Test-only: nothing in Sources is touched.
///
/// What is probed is *soundness*, not completeness: a heuristic mapper will legitimately fail to
/// resolve an awkward file, but it must never resolve one episode to another episode's file. Every
/// case is a shape real scene releases ship — absolute-numbered complete packs, an OVA interleaved
/// mid-season, multi-episode range files, split ("v2") episodes, Omake specials with no season
/// number, Western SxxExx naming — plus the usual pile of soundtrack and cover files. The episode
/// lists are representative of those shapes, not transcripts of any one series.
@Suite("Pack mapping stress", .serialized)
struct PackMappingStressTests {
    // MARK: Name understanding (the harness's own, deliberately independent of the mapper)

    /// Every episode number the file name bears, in whichever scheme it writes them.
    private static func numbers(in name: String) -> Set<Int> {
        var out = Set<Int>()
        let patterns = [
            #"(?i)(?:^|[^a-z0-9])s\d{1,2}e(\d{1,3})"#,          // S01E02
            #"(?i)(?:^|[^a-z0-9])(\d{1,3})v\d"#                // 01v2 — the version, not episode 2
            ,
            #"(?i)(?:omake|ova|special|sp)[\s._-]*(\d{1,3})"#,  // Omake 01
            #"(?:^|[^a-z0-9])(\d{1,3})(?![0-9vx])"#,            // a standalone 001
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = name as NSString
            for match in re.matches(in: name, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range(at: 1), in: name),
                    let value = Int(name[range]), value > 0, value < 1000
                else { continue }
                out.insert(value)
            }
        }
        return out
    }

    /// Loose text comparison: a release group may change case, drop punctuation or possessive 's.
    private static func fuzzy(_ a: String, _ b: String) -> Bool {
        func normalise(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "’", with: "")
                .filter { $0.isLetter || $0.isNumber }
        }
        let x = normalise(a), y = normalise(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }

    private static func isVideo(_ path: String) -> Bool {
        let ext = ((path as NSString).pathExtension).lowercased()
        return ["mkv", "mp4", "m4v", "avi", "wmv", "ts", "m2ts"].contains(ext)
    }

    private static func looksLikeExtra(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/ost/") || lower.contains("soundtrack") || lower.contains("ncop")
            || lower.contains("cover") || lower.contains("sample") || lower.contains("extras/")
    }

    private struct Failure { var caseLabel: String; var detail: String }

    /// The properties that must hold no matter how awkward the pack is.
    private static func audit(
        _ mapping: PackMappingResult, _ episodes: [PackEpisode], files: [PackFile], label: String
    ) -> [Failure] {
        var problems: [Failure] = []
        let byIndex = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.offset, $0.element) })
        // Only preferred files are ever played, so only they are held to the soundness rule. A file
        // the mapper considered and then rejected ("not used: another file already covers…") is
        // working as designed, not a wrong episode.
        let playable = mapping.assignments.filter { $0.isPreferred && $0.carriesEpisodes }

        // A file may cover several episodes, but only consecutive ones — a range file.
        var claimants: [Int: [EpisodeRef]] = [:]
        for a in playable {
            for ref in a.episodes { claimants[a.fileIndex, default: []].append(ref) }
        }
        for (fileIndex, refs) in claimants where refs.count > 1 {
            let sorted = refs.sorted()
            let consecutive = zip(sorted, sorted.dropFirst()).allSatisfy { $0.episode + 1 == $1.episode && $0.season == $1.season }
            if !consecutive {
                problems.append(
                    Failure(caseLabel: label, detail: "one file for non-adjacent episodes \(sorted): \(byIndex[fileIndex]?.path ?? "?")"))
            }
        }

        for a in playable {
            let path = byIndex[a.fileIndex]?.path ?? ""
            if !isVideo(path) {
                problems.append(Failure(caseLabel: label, detail: "non-video claimed as an episode: \(path)"))
            }
            if looksLikeExtra(path) {
                problems.append(Failure(caseLabel: label, detail: "extra claimed as an episode: \(path)"))
            }
        }

        // The soundness rule: a playable file must bear that episode's number or its title.
        for a in playable {
            let path = byIndex[a.fileIndex]?.path ?? ""
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let inName = numbers(in: base)
            for ref in a.episodes {
                let episode = episodes.first { $0.ref == ref }
                // If the library records an absolute number, that is the only number the file may
                // carry — accepting the episode number as well would hide exactly the confusion
                // this harness exists to catch.
                let expected: Int? = episode?.absolute ?? ref.episode
                let byNumber = expected.map { inName.contains($0) } ?? false
                let byTitle = episode?.title.map { fuzzy(path, $0) } ?? false
                if !byNumber && !byTitle {
                    problems.append(
                        Failure(caseLabel: label, detail: "\(ref) (absolute \(episode?.absolute.map(String.init) ?? "-")) mapped to \(path), which bears neither its number nor its title"))
                }
            }
        }
        return problems
    }

    private static func files(_ entries: [String]) -> [PackFile] {
        PackFile.layout(entries.enumerated().map { ($0.element, 700_000_000 + Int64($0.offset) * 1_000) })
    }

    // MARK: Cases

    private struct Case {
        var label: String
        var files: [PackFile]
        var episodes: [PackEpisode]
        /// Episodes that a correct mapper must resolve; anything else in `episodes` has no file.
        var mustResolve: [EpisodeRef]
    }

    private static func cases() -> [Case] {
        var cases: [Case] = []

        // Absolute-numbered complete pack with an OVA interleaved mid-season: the library's
        // episode number and the file's absolute number stop agreeing after episode 9.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            var absolute = 1
            for e in 1...24 {
                if e == 10 {
                    entries.append("Series/Series - \(pad(absolute)) - OVA Ten.mkv")
                    episodes.append(PackEpisode(ref: EpisodeRef(season: 0, episode: 1), absolute: absolute, title: "OVA Ten"))
                    absolute += 1
                }
                entries.append("Series/Series - \(pad(absolute)) - Episode \(e).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: e), absolute: absolute, title: "Episode \(e)"))
                absolute += 1
            }
            cases.append(Case(label: "absolute-with-interleaved-ova", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Absolute numbering with a hole: the pack genuinely does not ship episode 9.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for e in 1...12 where e != 9 {
                entries.append("Show/Show - \(pad(e)) - Chapter \(e).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: e), absolute: e, title: "Chapter \(e)"))
            }
            let missing = PackEpisode(ref: EpisodeRef(season: 1, episode: 9), absolute: 9, title: "Chapter 9")
            cases.append(Case(label: "absolute-with-hole", files: files(entries), episodes: episodes + [missing], mustResolve: episodes.map(\.ref)))
        }

        // Season folders for three seasons, specials in their own folder, plus extras.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for (si, folder) in ["Season 1", "Season 2", "Season 3 OVA"].enumerated() {
                for e in 1...8 {
                    entries.append("Pack/\(folder)/Pack - \(pad2(e)) - S0\(si + 1)E\(e).mkv")
                    episodes.append(PackEpisode(ref: EpisodeRef(season: si + 1, episode: e), title: "S0\(si + 1)E\(e)"))
                }
            }
            for e in 1...3 {
                entries.append("Pack/Specials/Pack - Omake \(pad2(e)).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 0, episode: e), title: "Omake \(e)"))
            }
            entries += ["Pack/Extras/OP.mkv", "Pack/Extras/ED.mkv", "Pack/OST/track 01.mp3", "Pack/cover.jpg", "Pack/readme.txt"]
            cases.append(Case(label: "season-folders", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Western TV: the season and episode are in the file name and the titles are absent.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for e in 1...10 {
                entries.append("Show.S01E\(pad2(e)).1080p.WEB-DL.mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: e)))
            }
            cases.append(Case(label: "western-s01enaming", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Multi-episode range files: one file genuinely covers two adjacent episodes.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for e in stride(from: 1, through: 11, by: 2) {
                entries.append("Range/Show - \(pad2(e))-\(e + 1).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: e)))
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: e + 1)))
            }
            cases.append(Case(label: "range-files", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Split episodes: "- 01v2" is episode 1, not episode 12 or 2.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for e in 1...6 {
                entries.append("Split/Show - \(pad2(e))v2.mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: e)))
            }
            cases.append(Case(label: "split-episodes", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Second season numbered from one again, in its own folder.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for e in 1...5 {
                entries.append("Show/Season 2/Show - \(pad2(e)).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 2, episode: e)))
            }
            cases.append(Case(label: "second-season-renumbered", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Omake specials with no season marker anywhere.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            for e in 1...5 {
                entries.append("Some.Show.Omake \(pad2(e)).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 0, episode: e)))
            }
            cases.append(Case(label: "omake-no-season", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Titles that are not "Episode N": matching has to fall back on the number.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            let names = ["Opening", "The Long Walk", "Reunion", "Fallout", "Epilogue"]
            for (i, name) in names.enumerated() {
                entries.append("Mixed/[Group] Mixed Show - \(pad(i + 1)) - \(name).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: i + 1), title: name))
            }
            cases.append(Case(label: "mixed-padding-titles", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // Punctuation and possessives the comparison has to survive.
        do {
            var entries: [String] = []
            var episodes: [PackEpisode] = []
            let names = ["Angel's Wings", "Bloodsport: Fairytale", "Mr. Bennys Fortune", "Two Fathers"]
            for (i, name) in names.enumerated() {
                entries.append("Punct/Show - \(pad2(i + 1)) - \(name).mkv")
                episodes.append(PackEpisode(ref: EpisodeRef(season: 1, episode: i + 1), title: name))
            }
            cases.append(Case(label: "punctuation-and-apostrophes", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        // The library knows three episodes; the pack ships six and has no titles for them.
        do {
            let entries = (1...6).map { "Unknown/Show - \(pad2($0)).mkv" }
            let episodes = (1...3).map { PackEpisode(ref: EpisodeRef(season: 1, episode: $0)) }
            cases.append(Case(label: "pack-larger-than-library", files: files(entries), episodes: episodes, mustResolve: episodes.map(\.ref)))
        }

        return cases
    }

    private static func pad(_ n: Int) -> String { String(format: "%03d", n) }
    private static func pad2(_ n: Int) -> String { String(format: "%02d", n) }

    private static func map(_ c: Case) -> (PackMappingResult, PackSeriesContext) {
        let series = PackSeriesContext(title: "Show", episodes: c.episodes, targetSeasons: [0, 1, 2, 3])
        return (PackFileMapper.map(files: c.files, series: series), series)
    }

    // MARK: Tests

    @Test("no case ever resolves an episode to the wrong file")
    func neverResolvesToTheWrongFile() {
        var problems: [Failure] = []
        for c in Self.cases() {
            problems += Self.audit(Self.map(c).0, c.episodes, files: c.files, label: c.label)
        }
        #expect(problems.isEmpty, Comment(rawValue: "\n" + problems.map { "  [\($0.caseLabel)] \($0.detail)" }.joined(separator: "\n")))
    }

    @Test("every case resolves the episodes it must, one at a time")
    func resolvesIndividualEpisodes() {
        var failures: [String] = []
        for c in Self.cases() {
            let mapping = Self.map(c).0
            for ref in c.mustResolve {
                let found = mapping.files(for: ref)
                if found.isEmpty { failures.append("[\(c.label)] \(ref) resolved to nothing") }
                if found.count > 1 { failures.append("[\(c.label)] \(ref) resolved to \(found.count) files") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\n" + failures.joined(separator: "\n")))
    }

    @Test("episodes the pack does not ship are never given a file")
    func missingEpisodesAreNotFaked() {
        var failures: [String] = []
        for c in Self.cases() {
            let mapped = Set(Self.map(c).0.assignments.flatMap(\.episodes))
            for episode in c.episodes where !c.mustResolve.contains(episode.ref) {
                if mapped.contains(episode.ref) {
                    failures.append("[\(c.label)] \(episode.ref) has no file but was given one")
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\n" + failures.joined(separator: "\n")))
    }

    @Test("random single episodes land on a file that bears their number or title")
    func randomEpisodesLandCorrectly() {
        var failures: [String] = []
        var generator = SystemRandomNumberGenerator()
        for c in Self.cases() where !c.mustResolve.isEmpty {
            let mapping = Self.map(c).0
            let byIndex = Dictionary(uniqueKeysWithValues: c.files.enumerated().map { ($0.offset, $0.element) })
            for ref in c.mustResolve.shuffled(using: &generator).prefix(4) {
                guard let file = mapping.files(for: ref).first else {
                    failures.append("[\(c.label)] \(ref) resolved to nothing")
                    continue
                }
                let path = byIndex[file.fileIndex]?.path ?? "?"
                let episode = c.episodes.first { $0.ref == ref }
                let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let inName = Self.numbers(in: base)
                let expected = episode?.absolute ?? ref.episode
                let ok = inName.contains(expected)
                    || (episode?.title.map { Self.fuzzy(path, $0) } ?? false)
                if !ok { failures.append("[\(c.label)] \(ref) landed on \(path)") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\n" + failures.joined(separator: "\n")))
    }

    @Test("the mapper is deterministic")
    func mappingIsDeterministic() {
        for c in Self.cases() {
            let first = Self.map(c).0
            let second = Self.map(c).0
            #expect(first.assignments.map(\.fileIndex) == second.assignments.map(\.fileIndex), Comment(rawValue: c.label))
            #expect(first.assignments.flatMap(\.episodes) == second.assignments.flatMap(\.episodes), Comment(rawValue: c.label))
        }
    }

    @Test("a library with no titles at all still maps by number")
    func untitledLibraryStillMaps() {
        var failures: [String] = []
        for c in Self.cases() {
            let anonymous = c.episodes.map { PackEpisode(ref: $0.ref, absolute: $0.absolute) }
            let series = PackSeriesContext(title: "Show", episodes: anonymous, targetSeasons: [0, 1, 2, 3])
            let mapping = PackFileMapper.map(files: c.files, series: series)
            for problem in Self.audit(mapping, anonymous, files: c.files, label: "\(c.label)/untitled") {
                failures.append("  \(problem.detail)")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\n" + failures.joined(separator: "\n")))
    }
}