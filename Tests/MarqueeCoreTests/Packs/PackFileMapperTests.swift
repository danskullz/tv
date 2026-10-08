import Foundation
import Testing
@testable import MarqueeCore

private let mb: Int64 = 1 << 20

private func ctx(seasons: [Int: Int], title: String = "Show Name", unaired: Set<EpisodeRef> = []) -> PackSeriesContext {
    var eps: [PackEpisode] = []
    for s in seasons.keys.sorted() {
        for e in 1...seasons[s]! {
            let r = EpisodeRef(season: s, episode: e)
            eps.append(PackEpisode(ref: r, isAired: !unaired.contains(r)))
        }
    }
    return PackSeriesContext(title: title, episodes: eps, targetSeasons: Set(seasons.keys))
}

private func layout(_ entries: [(String, Int64)]) -> [PackFile] { PackFile.layout(entries.map { ($0.0, $0.1) }) }

private func ref(_ s: String) -> EpisodeRef { EpisodeRef(s)! }

@Suite("PackFileMapper")
struct PackFileMapperTests {
    @Test func episodeRefRoundTrip() {
        #expect(EpisodeRef("S01E02") == EpisodeRef(season: 1, episode: 2))
        #expect(EpisodeRef("s10e105")?.description == "S10E105")
        #expect(EpisodeRef("nonsense") == nil)
        #expect(EpisodeRef(season: 0, episode: 3) < EpisodeRef(season: 1, episode: 1))
    }

    @Test func emptyInputs() {
        let r = PackFileMapper.map(files: [], series: ctx(seasons: [1: 3]))
        #expect(r.assignments.isEmpty)
        #expect(r.gaps.count == 3 && r.needsFallback, "nothing in the pack: every wanted episode is a gap")
        let loose = PackFileMapper.map(
            files: layout([("Show.Name.S01E01.mkv", 500 * mb), ("Show.Name.S01E02.mkv", 500 * mb)]),
            series: PackSeriesContext(title: "Show Name"))
        #expect(loose.assignments.map(\.episodes) == [[ref("S01E01")], [ref("S01E02")]])
        #expect(loose.gaps.isEmpty, "no episode list means no gap detection")
    }

    @Test func correctionsAlwaysWin() {
        let files = layout([
            ("Show.Name.S01.720p/Show.Name.S01E01.720p.mkv", 900 * mb),
            ("Show.Name.S01.720p/Show.Name.S01E02.720p.mkv", 900 * mb),
            ("Show.Name.S01.720p/Weird Name.mkv", 400 * mb),
            ("Show.Name.S01.720p/Show.Name.S01E03.720p.mkv", 900 * mb),
        ])
        // The user says the odd file is episode 3 (even though a bigger, better file also claims it)
        // and that file 1 is not an episode at all.
        let r = PackFileMapper.map(
            files: files, series: ctx(seasons: [1: 3]), corrections: [2: [ref("S01E03")], 1: []])
        let odd = r.assignments[2]
        #expect(odd.userCorrected && odd.confidence == 1 && odd.isPreferred)
        #expect(odd.episodes == [ref("S01E03")] && odd.role == .episode)
        #expect(!r.assignments[3].isPreferred, "the automatic claimant loses to the correction")
        #expect(r.assignments[1].role == .extra && r.assignments[1].userCorrected)
        #expect(r.gaps == [ref("S01E02")])
        #expect(r.conflicts.contains { $0.episode == ref("S01E03") && $0.winner == 2 && $0.losers == [3] })
    }

    @Test func correctionOnArchiveVolumeAppliesToWholeSet() {
        let files = layout([
            ("pack/abc.rar", 15 * mb), ("pack/abc.r00", 15 * mb), ("pack/abc.r01", 15 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 3]), corrections: [1: [ref("S01E02")]])
        #expect(r.assignments.allSatisfy { $0.episodes == [ref("S01E02")] && $0.userCorrected })
        #expect(r.archiveSets.first?.episodes == [ref("S01E02")])
        #expect(!r.hasOpaqueArchives)
    }

    @Test func duplicatesPreferQualityAndReportConflicts() {
        let files = layout([
            ("a/Show.Name.S01E01.720p.HDTV.x264-GRP.mkv", 800 * mb),
            ("b/Show.Name.S01E01.1080p.WEB-DL.x264-GRP.mkv", 1500 * mb),
            ("c/Show.Name.S01E01.1080p.BluRay.x264-GRP.mkv", 1400 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 1]))
        #expect(r.assignments.map(\.isPreferred) == [false, false, true], "BluRay 1080p beats WEB-DL 1080p and 720p")
        #expect(r.conflicts.count == 1)
        #expect(r.conflicts[0].winner == 2 && r.conflicts[0].losers == [0, 1])
        #expect(r.gaps.isEmpty)
        #expect(r.files(for: ref("S01E01")).map(\.fileIndex) == [2])
    }

    @Test func multiEpisodeFileRescuesPartiallyCoveredEpisodes() {
        let files = layout([
            ("Show.Name.S01E01.1080p.mkv", 1000 * mb),
            ("Show.Name.S01E01E02.1080p.mkv", 2000 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 2]))
        // The double episode is better (larger) and covers both; the single is redundant.
        #expect(r.assignments[1].isPreferred && r.assignments[1].role == .multiEpisode)
        #expect(!r.assignments[0].isPreferred)
        #expect(r.gaps.isEmpty)
    }

    @Test func gapsIgnoreUnairedAndUnrelatedSeasons() {
        let c = ctx(seasons: [1: 4, 2: 4], unaired: [ref("S01E04")])
        var c1 = c
        c1.targetSeasons = [1]
        let files = layout([("Show.Name.S01E01.mkv", 500 * mb), ("Show.Name.S01E03.mkv", 500 * mb)])
        let r = PackFileMapper.map(files: files, series: c1)
        #expect(r.gaps == [ref("S01E02")], "S01E04 is unaired; season 2 isn't in the pack")
        #expect(r.needsFallback)
    }

    @Test func incompleteArchivesCountAsGaps() {
        let files = layout([
            ("s/show.name.s01e01.rar", 15 * mb), ("s/show.name.s01e01.r00", 15 * mb), ("s/show.name.s01e01.r02", 15 * mb),
            ("s/show.name.s01e02.rar", 15 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 2]))
        #expect(r.gaps == [ref("S01E01")])
        #expect(r.warnings.contains { if case .incompleteArchive(_, let m) = $0 { return m == [2] } else { return false } })
    }

    @Test func opaqueArchiveSuppressesGapClaims() {
        let files = layout([("Show.Name.S01.complete.rar", 15 * mb), ("Show.Name.S01.complete.r00", 15 * mb)])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 5]))
        #expect(r.hasOpaqueArchives)
        #expect(r.gaps.isEmpty)
        #expect(r.assignments.allSatisfy { $0.role == .archiveVolume && $0.episodes.isEmpty })
    }

    @Test func executablesAreSuspiciousAndNeverEpisodes() {
        let files = layout([
            ("Show.Name.S01E01.mkv", 500 * mb), ("Show.Name.S01E01.mkv.exe", 2 * mb), ("setup.scr", 1 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 1]))
        #expect(r.suspiciousFiles == [1, 2])
        #expect(r.coveredEpisodes == [ref("S01E01")])
        #expect(r.assignments[1].role == .nonMedia && r.assignments[1].isSuspicious)
    }

    @Test func subtitlesAttachByNameAndByEpisode() {
        let files = layout([
            ("Show.Name.S01E01.1080p.mkv", 500 * mb),
            ("Show.Name.S01E01.1080p.en.forced.srt", 30_000),
            ("Subs/Show.Name.S01E02/3_English.srt", 30_000),
            ("Show.Name.S01E02.1080p.mkv", 500 * mb),
            ("Orphan Subtitle.srt", 30_000),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 2]))
        #expect(r.assignments[1].attachedTo == 0 && r.assignments[1].episodes == [ref("S01E01")])
        #expect(r.assignments[2].attachedTo == 3 && r.assignments[2].episodes == [ref("S01E02")])
        #expect(r.assignments[4].attachedTo == nil && r.assignments[4].episodes.isEmpty)
        #expect(r.assignments[4].confidence < 0.5)
    }

    @Test func reasonsAndConfidenceTellTheStory() {
        let files = layout([
            ("Show.Name.S01E01.mkv", 500 * mb),
            ("Show Name Season 1/03.mkv", 500 * mb),
            ("Show Name Season 1/Bonus Material.mkv", 80 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: ctx(seasons: [1: 3]))
        #expect(r.assignments[0].confidence > 0.95)
        #expect(r.assignments[1].confidence < r.assignments[0].confidence)
        #expect(r.assignments[1].reason.contains("folder"))
        #expect(r.assignments.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func persistedRecordConversion() {
        let id = UUID()
        let a = PackFileAssignment(
            fileIndex: 3, path: "x.mkv", size: 10, offset: 0, role: .episode, episodes: [ref("S01E01"), ref("S01E02")],
            confidence: 0.9, reason: "r", userCorrected: true)
        let rec = a.record(infoHash: "ABCDEF", episodeID: { $0 == ref("S01E01") ? id : nil })
        #expect(rec.infoHash == "abcdef" && rec.fileIndex == 3 && rec.episodeIds == [id])
        #expect(rec.role == .episode && rec.userCorrected)
        var loser = a
        loser.isPreferred = false
        #expect(loser.record(infoHash: "a", episodeID: { _ in nil }).role == .ignored)
    }

    @Test func absoluteNumbersFallBackWhenSeasonNumbersDontFit() {
        var eps: [PackEpisode] = []
        for a in 1...24 {
            let (s, e) = a <= 12 ? (1, a) : (2, a - 12)
            eps.append(PackEpisode(ref: EpisodeRef(season: s, episode: e), absolute: a))
        }
        let c = PackSeriesContext(title: "Show Title", episodes: eps, targetSeasons: [2])
        let files = layout([
            ("[G] Show Title S2/[G] Show Title - 13 [AAAAAAAA].mkv", 900 * mb),
            ("[G] Show Title S2/[G] Show Title - 24 [BBBBBBBB].mkv", 900 * mb),
        ])
        let r = PackFileMapper.map(files: files, series: c)
        #expect(r.assignments.map(\.episodes) == [[ref("S02E01")], [ref("S02E12")]])
    }
}
