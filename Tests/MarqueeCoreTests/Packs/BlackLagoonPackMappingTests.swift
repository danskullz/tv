import Foundation
import Testing

@testable import MarqueeCore

/// The real Black Lagoon situation, run through the mapper.
///
/// The library flattens every season into season 1 (and the OVAs into season 0), so an episode's
/// library ref has nothing to do with the season folder the file sits in. A pack is only usable if
/// the episode the user pressed resolves to the right file, so this walks the whole episode list
/// rather than the one episode that happened to be pressed.
@Suite("Black Lagoon pack mapping", .serialized)
struct BlackLagoonPackMappingTests {
    // MARK: Ground truth

    private static let packRoot = "[Anime Time] Black Lagoon (Complete Series) (Season 01+02+03+OST) [BD] [Dual Audio] [1080p][HEVC 10bit x265][AAC][Eng Sub]"

    /// The 29 episode files, by folder, exactly as the pack ships them.
    private static let episodeFiles: [(folder: String, number: Int, name: String)] = [
        ("Season 1", 1, "The Black Lagoon"),
        ("Season 1", 2, "Mangrove Heaven"),
        ("Season 1", 3, "Ring-Ding Ship Chase"),
        ("Season 1", 4, "Die Ruckkehr Des Adlers"),
        ("Season 1", 5, "Eagle Hunting And Hunting Eagles"),
        ("Season 1", 6, "Moonlit Hunting Grounds"),
        ("Season 1", 7, "Calm Down Two Men"),
        ("Season 1", 8, "Rasta Blasta"),
        ("Season 1", 9, "Maid To Kill"),
        ("Season 1", 10, "The Unstoppable Chambermaid"),
        ("Season 1", 11, "Lockn Load Revolution"),
        ("Season 1", 12, "Guerrillas In The Jungle"),
        ("Season 2 The Second Barrage", 13, "The Vampire Twins Comen"),
        ("Season 2 The Second Barrage", 14, "Bloodsport Fairytale"),
        ("Season 2 The Second Barrage", 15, "Swan Song At Dawn"),
        ("Season 2 The Second Barrage", 16, "Greenback Jane"),
        ("Season 2 The Second Barrage", 17, "The Roanapur Freakshow Circus"),
        ("Season 2 The Second Barrage", 18, "Mr Bennys Good Fortune"),
        ("Season 2 The Second Barrage", 19, "Fujiyama Gangsta Paradise"),
        ("Season 2 The Second Barrage", 20, "The Succession"),
        ("Season 2 The Second Barrage", 21, "Two Fathers Little Soldier Girls"),
        ("Season 2 The Second Barrage", 22, "The Dark Tower"),
        ("Season 2 The Second Barrage", 23, "Snow Whites Payback"),
        ("Season 2 The Second Barrage", 24, "The Gunslingers"),
        ("Season 3 Roberta's Blood Trail", 25, "Collateral Massacre"),
        ("Season 3 Roberta's Blood Trail", 26, "An Office Man's Tactics"),
        ("Season 3 Roberta's Blood Trail", 27, "Angels In The Crosshairs"),
        ("Season 3 Roberta's Blood Trail", 28, "Oversaturation Kill Box"),
        ("Season 3 Roberta's Blood Trail", 29, "Codename Paradise Status MIA"),
    ]

    /// The seven OVAs the library lists that this pack does not ship. Correct behaviour is to
    /// report them as gaps, not to borrow another episode's file for them.
    private static let ovaTitles = [
        "High School Life", "The Magical Girl", "The Melancholy of Balalaika", "Boys and Girls",
        "Summer Evening Spooky Story Contest", "Viva! Youth!", "Go For It! Manzai Grand Prix!",
        "Collateral Massacre", "An Office Man's Tactics", "Angels in the Crosshairs",
        "Oversaturation Kill Box", "Codename Paradise, Status MIA",
    ]
    private static let ovaMissingCount = 7  // the first seven above

    /// The soundtrack, opening and cover files a real torrent carries alongside the episodes.
    private static let noise: [String] = [
        "NCOP and NCED/[Anime Time] Black Lagoon OP 01 - Red Fraction.mkv",
        "NCOP and NCED/[Anime Time] Black Lagoon ED 01  - Don't Look Behind.mkv",
        "NCOP and NCED/cover.jpg",
        "OST/BLACK LAGOON ORIGINAL SOUNDTRACK/[Anime Time] Black Lagoon - 001 - Red Fraction [TV Size].mp3",
        "OST/BLACK LAGOON ORIGINAL SOUNDTRACK/[Anime Time] Black Lagoon - 013 - Tadpole Dance.mp3",
        "OST/Black Lagoon Roberta's Blood Trail OP Album - MIRAGE/[Anime Time] Black Lagoon - 003 - Princess bloom.mp3",
        "OST/BLACK LAGOON Roberta's Blood Trail Original Sound Track/[Anime Time] Black Lagoon - 007 - Roberta's Last Moment.mp3",
        "README.txt",
    ]

    private static func files(seasons: [String]? = nil) -> [PackFile] {
        var entries: [(path: String, size: Int64)] = episodeFiles
            .filter { seasons == nil || seasons!.contains($0.folder) }
            .map { e in
                let number = String(format: "%03d", e.number)
                // The real pack has a double space where the release tag is short.
                let prefix = e.number == 11 ? "[Anime Time] Black Lagoon  -" : "[Anime Time] Black Lagoon -"
                return (
                    "\(packRoot)/\(e.folder)/\(prefix) \(number) - \(e.name).mkv",
                    Int64(700_000_000) + Int64(e.number) * 1_000
                )
            }
        entries += noise.map { (path: "\(packRoot)/\($0)", size: Int64(4_000_000)) }
        return PackFile.layout(entries)
    }

    /// What the library actually holds: season 1's twelve episodes, then season 2's twelve folded
    /// in as S01E13-E24, then the twelve OVAs as specials.
    private static func libraryEpisodes() -> [PackEpisode] {
        let season1 = episodeFiles.filter { $0.folder == "Season 1" }
        let season2 = episodeFiles.filter { $0.folder == "Season 2 The Second Barrage" }
        var episodes: [PackEpisode] = []
        for i in 1...season1.count {
            episodes.append(PackEpisode(
                ref: EpisodeRef(season: 1, episode: i),
                airDate: AirDate(year: 2006, month: 4, day: 9 + (i - 1) * 7),
                title: season1[i - 1].name))
        }
        for i in 1...season2.count {
            episodes.append(PackEpisode(
                ref: EpisodeRef(season: 1, episode: season1.count + i),
                airDate: AirDate(year: 2006, month: 10, day: 4 + (i - 1) * 7),
                title: season2[i - 1].name))
        }
        for (i, title) in ovaTitles.enumerated() {
            episodes.append(PackEpisode(ref: EpisodeRef(season: 0, episode: i + 1), title: title))
        }
        return episodes
    }

    private static func context(_ episodes: [PackEpisode], targetSeasons: Set<Int>) -> PackSeriesContext {
        PackSeriesContext(
            title: "Black Lagoon", aliases: ["Black Lagoon", "Kuroi Hon"], episodes: episodes,
            targetSeasons: targetSeasons)
    }

    private static func completeMapping() -> (PackMappingResult, [PackEpisode]) {
        let episodes = libraryEpisodes()
        return (
            PackFileMapper.map(files: files(), series: context(episodes, targetSeasons: [0, 1])), episodes
        )
    }

    /// Loose enough to survive the punctuation and case a release group adds to a title
    /// ("Angels In The Crosshairs" vs "Angels in the Crosshairs").
    private static func titleMatches(_ path: String, _ title: String) -> Bool {
        func normalise(_ s: String) -> String {
            let folded = s.lowercased().filter { $0.isLetter || $0.isNumber }
            return folded.replacingOccurrences(of: " ", with: "")
        }
        return normalise(path).contains(normalise(title))
    }

    // MARK: Tests

    @Test("all 24 flattened season-1 episodes resolve to their own file")
    func everySeasonOneEpisodeMaps() {
        let (mapping, episodes) = Self.completeMapping()
        let mapped = Set(mapping.assignments.flatMap(\.episodes))
        let season1 = episodes.filter { $0.ref.season == 1 }.map(\.ref)
        let missing = season1.filter { !mapped.contains($0) }

        #expect(missing.isEmpty, "these episodes have no file: \(missing.map(\.description))")
    }

    @Test("S01E16 — the episode that failed — lands on 'Greenback Jane', in the season 2 folder")
    func theReportedEpisodeMapsToItsOwnFile() throws {
        let (mapping, _) = Self.completeMapping()
        let files = mapping.files(for: EpisodeRef(season: 1, episode: 16))
        let file = try #require(files.first, "S01E16 did not resolve to any file")

        #expect(file.path.contains("Greenback Jane"))
        #expect(file.path.contains("Season 2 The Second Barrage"))
        #expect(file.isPreferred)
    }

    @Test("every episode lands on the file that actually has its title")
    func titlesLandOnTheirOwnFile() {
        let (mapping, episodes) = Self.completeMapping()
        for assignment in mapping.assignments where assignment.carriesEpisodes {
            for ref in assignment.episodes {
                let expected = episodes.first { $0.ref == ref }?.title ?? ""
                #expect(
                    Self.titleMatches(assignment.path, expected),
                    "\(ref) landed on \(assignment.path) but is called \"\(expected)\""
                )
            }
        }
    }

    @Test("no file is claimed by two different episodes")
    func noFileIsShared() throws {
        let (mapping, _) = Self.completeMapping()
        var seen = Set<Int>()
        for assignment in mapping.assignments where assignment.carriesEpisodes {
            #expect(seen.insert(assignment.fileIndex).inserted, "\(assignment.path) was claimed twice")
        }
    }

    @Test("the seven OVAs the pack does not ship are never faked onto another episode's file")
    func missingOvasAreNotFaked() {
        let (mapping, episodes) = Self.completeMapping()
        let mapped = Set(mapping.assignments.flatMap(\.episodes))
        let specials = episodes.filter { $0.ref.season == 0 }.map(\.ref)
        let missing = specials.filter { !mapped.contains($0) }

        #expect(missing.count == Self.ovaMissingCount, "got \(missing.map(\.description))")
        // The five OVAs the pack does ship must be found, by title, not borrowed by position.
        for i in (Self.ovaMissingCount + 1)...specials.count {
            #expect(mapped.contains(specials[i - 1]), "\(specials[i - 1]) should map")
        }
        for assignment in mapping.assignments where assignment.carriesEpisodes {
            #expect(
                !missing.contains { assignment.episodes.contains($0) },
                "a missing OVA was handed a file: \(assignment.path)"
            )
        }
    }

    @Test("a season-1-only pack covers exactly its twelve episodes and nothing else")
    func seasonOnePackCoversItsOwnEpisodes() throws {
        let episodes = Self.libraryEpisodes().filter { $0.ref.season == 1 && $0.ref.episode <= 12 }
        let mapping = PackFileMapper.map(
            files: Self.files(seasons: ["Season 1"]), series: Self.context(episodes, targetSeasons: [1]))
        let mapped = Set(mapping.assignments.flatMap(\.episodes))

        #expect(mapped == Set(episodes.map(\.ref)))
        #expect(mapping.gaps.isEmpty, "a complete season 1 pack leaves no gaps")

        // The episode the user pressed is genuinely not in this pack. Because the library folded
        // season 2 into season 1, the mapper reports every one of those twelve as a gap, which is
        // what should send the pipeline looking for a pack that does have them.
        let allEpisodes = Self.libraryEpisodes().filter { $0.ref.season == 1 }
        let seasonOneOnly = PackFileMapper.map(
            files: Self.files(seasons: ["Season 1"]), series: Self.context(allEpisodes, targetSeasons: [1]))
        let covered = Set(seasonOneOnly.assignments.flatMap(\.episodes))
        #expect(!covered.contains(EpisodeRef(season: 1, episode: 16)))
        #expect(
            Set(seasonOneOnly.gaps) == Set((13...24).map { EpisodeRef(season: 1, episode: $0) }),
            "got \(seasonOneOnly.gaps.map(\.description))"
        )
        #expect(seasonOneOnly.needsFallback, "a pack that is missing half the season must ask for a fallback")
    }

    @Test("soundtracks, openings and covers never count as episodes")
    func extrasAreNotEpisodes() {
        let (mapping, _) = Self.completeMapping()
        for assignment in mapping.assignments where assignment.carriesEpisodes {
            #expect(!assignment.path.hasSuffix(".mp3"), "claimed an OST track: \(assignment.path)")
            #expect(!assignment.path.contains("NCOP"), "claimed an opening: \(assignment.path)")
            #expect(!assignment.path.hasSuffix(".txt"), "claimed the readme: \(assignment.path)")
        }
        #expect(mapping.files(for: EpisodeRef(season: 0, episode: 1)).isEmpty)
    }
}