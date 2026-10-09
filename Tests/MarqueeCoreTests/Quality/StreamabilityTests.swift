import Foundation
import Testing
@testable import MarqueeCore

@Suite struct StreamabilityTests {
    private let profile = qualityProfile(
        allowing: [.webDL720p, .webDL1080p, .bluray1080p, .webDL2160p], cutoff: .webDL2160p)

    private func decisions(_ candidates: [ReleaseCandidate], wanted: WantedItem, minimumSeeders: Int = 0) -> [ReleaseDecision] {
        ReleaseDecisionEngine.decide(
            candidates, in: DecisionContext(wanted: wanted, profile: profile, minimumSeeders: minimumSeeders, now: qualityNow, ignoreDelay: true))
    }

    private func titles(_ scores: [StreamabilityScore]) -> [String] { scores.map(\.decision.candidate.release.title) }

    // MARK: Health

    @Test func healthIsLogScaledAndDeadSwarmsSinkToTheBottom() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let healthy = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-AAA", seeders: 300, sizeGB: 6)
        let ok = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 30, sizeGB: 6)
        let thin = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-CCC", seeders: 3, sizeGB: 6)
        let dead = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-DDD", seeders: 0, sizeGB: 6)
        let ranked = StreamabilityScorer.rank(decisions([dead, thin, ok, healthy], wanted: wanted), input: StreamabilityInput(wanted: wanted))
        #expect(titles(ranked) == [healthy, ok, thin, dead].map(\.release.title))
        func health(_ i: Int) -> Double { ranked[i].components.first { $0.name == "health" }!.points }
        // Log scale: ten times the seeders is worth roughly the same step at every magnitude, and 300 vs 30 is
        // far from the 10x raw difference.
        #expect(health(0) - health(1) < 25)
        #expect(health(1) - health(2) > 15)
        #expect(health(3) == -100)
    }

    @Test func healthNeverOverridesAHugeQualityGapAlone() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let uhd = qualityMakeCandidate("Movie.2021.2160p.WEB-DL.H.265-AAA", seeders: 200, sizeGB: 20)
        let hd = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 300, sizeGB: 6)
        let ranked = StreamabilityScorer.rank(decisions([hd, uhd], wanted: wanted), input: StreamabilityInput(wanted: wanted))
        #expect(ranked.first?.decision.candidate.release.title == uhd.release.title)
    }

    // MARK: Bitrate

    @Test func bitrateFitDrivesTheChoiceWhenThroughputIsKnown() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let uhd = qualityMakeCandidate("Movie.2021.2160p.WEB-DL.H.265-AAA", seeders: 200, sizeGB: 30)  // ~4.5 MB/s
        let hd = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 200, sizeGB: 6)  // ~0.9 MB/s
        let all = decisions([uhd, hd], wanted: wanted)
        let fast = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 12_000_000)
        let slow = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 2_000_000)
        #expect(StreamabilityScorer.rank(all, input: fast).first?.decision.candidate.release.title == uhd.release.title)
        let slowRanked = StreamabilityScorer.rank(all, input: slow)
        #expect(slowRanked.first?.decision.candidate.release.title == hd.release.title)
        #expect(slowRanked.first?.fitsThroughput == true)
        #expect(slowRanked.last?.fitsThroughput == false)
        #expect(slowRanked.last?.explanation.reasons.contains { $0.contains("well above your") } == true)
    }

    @Test func bitrateIsSizeOverRuntime() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let c = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-AAA", seeders: 50, sizeGB: 6)
        let s = StreamabilityScorer.rank(decisions([c], wanted: wanted), input: StreamabilityInput(wanted: wanted))[0]
        let expected = Double(6 * 1_073_741_824) / (100 * 60)
        #expect(abs(s.bitrateBytesPerSecond! - expected) < 1)
        #expect(s.fitsThroughput == nil)
    }

    // MARK: Containers

    @Test func archivesArePenalizedStoredMildlyCompressedHeavily() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let mkv = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-AAA", seeders: 100, sizeGB: 6)
        let stored = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 100, sizeGB: 6)
        let packed = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-CCC", seeders: 100, sizeGB: 6)
        let input = StreamabilityInput(
            wanted: wanted, containerOverrides: [mkv.id: .mkv, stored.id: .storedArchive, packed.id: .compressedArchive])
        let ranked = StreamabilityScorer.rank(decisions([packed, stored, mkv], wanted: wanted), input: input)
        #expect(titles(ranked) == [mkv, stored, packed].map(\.release.title))
        func container(_ c: ReleaseCandidate) -> Double {
            ranked.first { $0.decision.candidate.release.title == c.release.title }!.components.first { $0.name == "container" }!.points
        }
        #expect(container(mkv) - container(stored) < 20)
        #expect(container(mkv) - container(packed) > 40)
        #expect(ranked.last?.explanation.text.contains("compressed archive") == true)
    }

    @Test func containerIsGuessedFromParsedNames() {
        #expect(ContainerKind.guess(from: ReleaseParser.parse("Movie.2021.1080p.WEB-DL.H.264-GRP.mkv")) == .mkv)
        #expect(ContainerKind.guess(from: ReleaseParser.parse("Movie.2021.1080p.WEB-DL.H.264-GRP.mp4")) == .mp4)
        var archive = ReleaseParser.parse("Movie.2021.1080p.WEB-DL.H.264-GRP")
        archive.flags.insert(.archive)
        #expect(ContainerKind.guess(from: archive) == .compressedArchive)
        #expect(ContainerKind.guess(from: ReleaseParser.parse("Movie.2021.1080p.WEB-DL.H.264-GRP")) == .unknown)
    }

    // MARK: Pack vs single

    @Test func singleEpisodePlayPrefersTheSingleUnlessThePackIsMuchHealthier() {
        let wanted = WantedItem.episode("Show", season: 1, episodes: [4], runtimeMinutes: 45, seasonEpisodeCount: 10)
        let single = qualityMakeCandidate("Show.S01E04.1080p.WEB-DL.H.264-GRP", seeders: 80, sizeGB: 3)
        let pack = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-GRP", seeders: 120, sizeGB: 30)
        let similar = StreamabilityScorer.rank(decisions([pack, single], wanted: wanted), input: StreamabilityInput(wanted: wanted))
        #expect(similar.first?.decision.candidate.release.title == single.release.title)

        let healthyPack = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-GRP", seeders: 900, sizeGB: 30)
        let weakSingle = qualityMakeCandidate("Show.S01E04.1080p.WEB-DL.H.264-GRP", seeders: 12, sizeGB: 3)
        let muchHealthier = StreamabilityScorer.rank(decisions([weakSingle, healthyPack], wanted: wanted), input: StreamabilityInput(wanted: wanted))
        #expect(muchHealthier.first?.decision.isPack == true)
        #expect(muchHealthier.first?.explanation.text.contains("much healthier") == true)
    }

    @Test func packIsUsedWhenNoSingleEpisodeExists() {
        let wanted = WantedItem.episode("Show", season: 1, episodes: [4], runtimeMinutes: 45, seasonEpisodeCount: 10)
        let pack = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-GRP", seeders: 200, sizeGB: 30)
        let ranked = StreamabilityScorer.rank(decisions([pack], wanted: wanted), input: StreamabilityInput(wanted: wanted))
        #expect(ranked.count == 1 && ranked[0].decision.isPack)
    }

    @Test func seasonPlayPrefersAHealthyCompletePack() {
        let wanted = WantedItem.season("Show", season: 2, episodeCount: 8, runtimeMinutes: 45)
        let pack = qualityMakeCandidate("Show.S02.1080p.WEB-DL.H.264-GRP", seeders: 150, sizeGB: 25)
        let thinPack = qualityMakeCandidate("Show.S02.1080p.WEB-DL.H.264-THIN", seeders: 1, sizeGB: 25)
        let multi = qualityMakeCandidate("Show.S01-S03.1080p.WEB-DL.H.264-MULTI", seeders: 150, sizeGB: 25)
        // Single episodes are rejected by the engine for a season request, so only packs are scored.
        let single = qualityMakeCandidate("Show.S02E01.1080p.WEB-DL.H.264-GRP", seeders: 2000, sizeGB: 3)
        let all = decisions([single, thinPack, multi, pack], wanted: wanted)
        let ranked = StreamabilityScorer.rank(all, input: StreamabilityInput(wanted: wanted))
        #expect(titles(ranked) == [pack, multi, thinPack].map(\.release.title))
        #expect(ranked.first?.explanation.text.contains("complete season pack with a healthy swarm") == true)
    }

    // MARK: Fallback

    @Test func smallerVersionPicksTheBestRankedReleaseThatFitsThroughput() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let uhd = qualityMakeCandidate("Movie.2021.2160p.WEB-DL.H.265-AAA", seeders: 200, sizeGB: 30)  // 36 Mbit/s
        let hd = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 200, sizeGB: 8)  // 9.5 Mbit/s
        let sd = qualityMakeCandidate("Movie.2021.720p.WEB-DL.H.264-CCC", seeders: 200, sizeGB: 3)  // 3.6 Mbit/s
        let dead = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-DEAD", seeders: 0, sizeGB: 5)
        let all = decisions([uhd, hd, sd, dead], wanted: wanted)
        let current = all.first { $0.candidate.release.title == uhd.release.title }!
        let input = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 2_000_000)  // 16 Mbit/s
        let pick = StreamabilityScorer.smallerVersion(than: current, among: all, input: input)
        #expect(pick?.decision.candidate.release.title == hd.release.title)
        #expect(pick?.explanation.headline == "Try a smaller version")
        #expect(pick?.explanation.text.contains("fits your measured") == true)

        // On a slower line the 1080p no longer fits (needs 1.2 MB/s with headroom), the 720p does.
        let slower = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 800_000)
        let slowPick = StreamabilityScorer.smallerVersion(than: current, among: all, input: slower)
        #expect(slowPick?.decision.candidate.release.title == sd.release.title)
    }

    @Test func smallerVersionOffersTheLightestWhenNothingFits() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let hd = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 200, sizeGB: 8)
        let sd = qualityMakeCandidate("Movie.2021.720p.WEB-DL.H.264-CCC", seeders: 200, sizeGB: 3)
        let all = decisions([hd, sd], wanted: wanted)
        let current = all.first { $0.candidate.release.title == hd.release.title }!
        let crawl = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 100_000)
        let pick = StreamabilityScorer.smallerVersion(than: current, among: all, input: crawl)
        #expect(pick?.decision.candidate.release.title == sd.release.title)
        #expect(pick?.explanation.text.contains("lightest available") == true)
    }

    @Test func smallerVersionIsNilWhenNothingSmallerExists() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let only = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 200, sizeGB: 8)
        let all = decisions([only], wanted: wanted)
        let input = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 100_000)
        #expect(StreamabilityScorer.smallerVersion(than: all[0], among: all, input: input) == nil)
    }

    @Test func smallerVersionOfASeasonPackStaysInPacks() {
        let wanted = WantedItem.season("Show", season: 1, episodeCount: 8, runtimeMinutes: 45)
        let big = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-AAA", seeders: 100, sizeGB: 40)
        let small = qualityMakeCandidate("Show.S01.720p.WEB-DL.H.264-BBB", seeders: 100, sizeGB: 12)
        let all = decisions([big, small], wanted: wanted)
        let current = all.first { $0.candidate.release.title == big.release.title }!
        let pick = StreamabilityScorer.smallerVersion(
            than: current, among: all, input: StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 300_000))
        #expect(pick?.decision.candidate.release.title == small.release.title)
    }

    // MARK: Explanation

    @Test func explanationReadsLikeADecisionExplanation() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let c = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-AAA", seeders: 312, sizeGB: 6)
        let input = StreamabilityInput(wanted: wanted, measuredThroughputBytesPerSecond: 5_000_000, containerOverrides: [c.id: .mkv])
        let ranked = StreamabilityScorer.rank(decisions([c], wanted: wanted), input: input)
        let text = ranked[0].explanation.text
        #expect(text.hasPrefix("Best to stream: 1080p WEB-DL; 312 seeders; bitrate "))
        #expect(text.contains("well within your 40.0 Mbit/s connection"))
        #expect(text.contains("MKV container"))
    }

    @Test func rejectedDecisionsAreNeverScored() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let bad = qualityMakeCandidate("Other.2021.1080p.WEB-DL.H.264-AAA", seeders: 999, sizeGB: 6)
        let ok = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 5, sizeGB: 6)
        let ranked = StreamabilityScorer.rank(decisions([bad, ok], wanted: wanted), input: StreamabilityInput(wanted: wanted))
        #expect(titles(ranked) == [ok.release.title])
    }
}
