import Foundation
import Testing
@testable import MarqueeCore

@Suite struct DelayProfileTests {
    private let profile = qualityProfile(allowing: [.webDL720p, .webDL1080p, .bluray1080p], cutoff: .bluray1080p)
    private var web1080Group: Int { profile.groupIndex(of: .webDL1080p)! }
    private var bluray1080Group: Int { profile.groupIndex(of: .bluray1080p)! }

    @Test func holdsReleasesUntilTheDelayElapses() {
        let delay = DelayProfileConfig(delayMinutes: 120, bypassIfHighestQuality: false)
        let published = qualityNow.addingTimeInterval(-30 * 60)
        let verdict = delay.evaluate(tierGroupIndex: web1080Group, formatScore: 0, in: profile, publishDate: published, now: qualityNow)
        #expect(verdict == .wait(until: published.addingTimeInterval(120 * 60)))
    }

    @Test func proceedsOnceTheInjectedClockPassesTheDelay() {
        let delay = DelayProfileConfig(delayMinutes: 120, bypassIfHighestQuality: false)
        let published = qualityNow.addingTimeInterval(-30 * 60)
        let later = qualityNow.addingTimeInterval(90 * 60)
        let atBoundary = delay.evaluate(tierGroupIndex: web1080Group, formatScore: 0, in: profile, publishDate: published, now: later)
        #expect(atBoundary == .proceed(reason: "waited 120 min"))
        let before = delay.evaluate(tierGroupIndex: web1080Group, formatScore: 0, in: profile, publishDate: published, now: later - 1)
        #expect(before.isWaiting)
    }

    @Test func bypassesForTheHighestQualityGroup() {
        let delay = DelayProfileConfig(delayMinutes: 120, bypassIfHighestQuality: true)
        let fresh = qualityNow.addingTimeInterval(-60)
        let top = delay.evaluate(tierGroupIndex: bluray1080Group, formatScore: 0, in: profile, publishDate: fresh, now: qualityNow)
        #expect(top == .proceed(reason: "highest quality in your profile"))
        #expect(delay.evaluate(tierGroupIndex: web1080Group, formatScore: 0, in: profile, publishDate: fresh, now: qualityNow).isWaiting)
    }

    @Test func bypassesForHighScores() {
        let delay = DelayProfileConfig(delayMinutes: 120, bypassIfHighestQuality: false, bypassIfScoreAtLeast: 100)
        let fresh = qualityNow.addingTimeInterval(-60)
        #expect(!delay.evaluate(tierGroupIndex: web1080Group, formatScore: 100, in: profile, publishDate: fresh, now: qualityNow).isWaiting)
        #expect(delay.evaluate(tierGroupIndex: web1080Group, formatScore: 99, in: profile, publishDate: fresh, now: qualityNow).isWaiting)
    }

    @Test func zeroDelayAndUnknownDatesNeverWait() {
        let none = DelayProfileConfig(delayMinutes: 0)
        #expect(!none.evaluate(tierGroupIndex: 0, formatScore: 0, in: profile, publishDate: qualityNow, now: qualityNow).isWaiting)
        let delay = DelayProfileConfig(delayMinutes: 60, bypassIfHighestQuality: false)
        #expect(!delay.evaluate(tierGroupIndex: 0, formatScore: 0, in: profile, publishDate: nil, now: qualityNow).isWaiting)
    }

    @Test func engineReportsDelayedReleasesAndHonoursIgnoreDelay() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let fresh = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6, ageHours: 0.5)
        var context = DecisionContext(
            wanted: wanted, profile: profile, delayProfile: DelayProfileConfig(delayMinutes: 120, bypassIfHighestQuality: false),
            now: qualityNow)
        let delayed = ReleaseDecisionEngine.decide([fresh], in: context)[0]
        #expect(delayed.rejections == [.delayed(until: qualityNow.addingTimeInterval(90 * 60))])
        #expect(delayed.rejections.allSatisfy { $0.isTemporary })

        context.ignoreDelay = true
        #expect(ReleaseDecisionEngine.decide([fresh], in: context)[0].isAccepted)

        context.ignoreDelay = false
        context.now = qualityNow.addingTimeInterval(2 * 3600)
        #expect(ReleaseDecisionEngine.decide([fresh], in: context)[0].isAccepted)
    }

    @Test func delayIsOnlyReportedForOtherwiseAcceptableReleases() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let dead = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", seeders: 0, sizeGB: 6, ageHours: 0.5)
        let context = DecisionContext(
            wanted: wanted, profile: profile, delayProfile: DelayProfileConfig(delayMinutes: 120, bypassIfHighestQuality: false),
            now: qualityNow)
        #expect(ReleaseDecisionEngine.decide([dead], in: context)[0].rejections.map(\.code) == ["tooFewSeeders"])
    }
}

@Suite struct RankComparatorTests {
    private func key(
        quality: Int = 5, score: Int = 0, priority: Int = 25, seeders: Int = 100, size: Double = 0, age: Int = 24, id: String = "a"
    ) -> RankKey {
        RankKey(
            qualityGroup: quality, formatScore: score, indexerPriority: priority, seederBucket: RankKey.seederBucket(for: seeders),
            sizeDistance: size, ageHours: age, tiebreak: id)
    }

    @Test func qualityOutranksEverything() {
        let better = key(quality: 6, score: -500, priority: 50, seeders: 1, size: 99, age: 9999)
        let worse = key(quality: 5, score: 500, priority: 1, seeders: 5000, size: 0, age: 1)
        let verdict = RankKey.compare(better, worse)
        #expect(verdict.lhsWins == true && verdict.criterion == .quality)
    }

    @Test func formatScoreComesSecond() {
        let verdict = RankKey.compare(key(score: 50, priority: 50, seeders: 1), key(score: 40, priority: 1, seeders: 5000))
        #expect(verdict.lhsWins == true && verdict.criterion == .formatScore)
    }

    @Test func lowerIndexerPriorityNumberWins() {
        let verdict = RankKey.compare(key(priority: 10, seeders: 1), key(priority: 25, seeders: 5000))
        #expect(verdict.lhsWins == true && verdict.criterion == .indexerPriority)
    }

    @Test func seedersAreCompared_inLogBuckets() {
        #expect(RankKey.compare(key(seeders: 1000), key(seeders: 40)).criterion == .seeders)
        #expect(RankKey.compare(key(seeders: 1000), key(seeders: 40)).lhsWins == true)
        // 312 and 290 seeders fall in the same bucket, so the next criterion decides.
        let close = RankKey.compare(key(seeders: 312, size: 5), key(seeders: 290, size: 1))
        #expect(close.criterion == .sizePreference && close.lhsWins == false)
        #expect(RankKey.seederBucket(for: nil) == 0 && RankKey.seederBucket(for: 0) == 0)
        #expect(RankKey.seederBucket(for: 1) == 1 && RankKey.seederBucket(for: 3) == 2 && RankKey.seederBucket(for: 312) == 8)
    }

    @Test func sizePreferenceThenAgeThenStableTiebreak() {
        #expect(RankKey.compare(key(size: 1), key(size: 2)).lhsWins == true)
        let age = RankKey.compare(key(age: 5), key(age: 50))
        #expect(age.criterion == .age && age.lhsWins == true)
        let tie = RankKey.compare(key(id: "a"), key(id: "b"))
        #expect(tie.criterion == .tiebreak && tie.lhsWins == true)
        #expect(RankKey.compare(key(), key()).lhsWins == nil)
    }

    @Test func sortingFollowsTheFullCriterionChain() {
        var keys = [
            key(quality: 5, score: 10, id: "e"), key(quality: 6, id: "a"), key(quality: 5, score: 10, priority: 5, id: "d"),
            key(quality: 5, score: 20, id: "c"), key(quality: 5, score: 10, seeders: 5000, id: "f"),
        ]
        keys.sort(by: RankKey.ranksBefore)
        #expect(keys.map(\.tiebreak) == ["a", "c", "d", "f", "e"])
    }

    @Test func engineUsesSizePreferenceFromTheProfile() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let small = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-AAA", seeders: 100, sizeGB: 4)
        let large = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", seeders: 100, sizeGB: 12)
        func winner(_ preference: SizePreference) -> String? {
            let profile = qualityProfile(allowing: [.webDL1080p], sizePreference: preference)
            return ReleaseDecisionEngine.decide([large, small], in: DecisionContext(wanted: wanted, profile: profile, now: qualityNow)).best?.candidate.release.title
        }
        #expect(winner(.smaller) == small.release.title)
        #expect(winner(.larger) == large.release.title)
        // Preferred for 1080p WEB-DL is 60 MB/min = ~5.9 GiB for 100 minutes: 4 GiB is closer than 12 GiB.
        #expect(winner(.nearPreferred) == small.release.title)
    }

    @Test func engineBreaksTiesByAgeNewestFirst() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let older = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-AAA", sizeGB: 6, ageHours: 500)
        let newer = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BBB", sizeGB: 6, ageHours: 20)
        let profile = qualityProfile(allowing: [.webDL1080p])
        let result = ReleaseDecisionEngine.decide([older, newer], in: DecisionContext(wanted: wanted, profile: profile, now: qualityNow))
        #expect(result.first?.candidate.release.title == newer.release.title)
    }
}

@Suite struct RejectionTests {
    private let profile = qualityProfile(allowing: [.webDL1080p, .bluray1080p], cutoff: .bluray1080p)
    private let movie = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)

    private func decide(_ candidate: ReleaseCandidate, _ configure: (inout DecisionContext) -> Void = { _ in }) -> ReleaseDecision {
        var context = DecisionContext(wanted: movie, profile: profile, now: qualityNow)
        configure(&context)
        return ReleaseDecisionEngine.decide([candidate], in: context)[0]
    }

    @Test func sampleAndExtraFlagsReject() {
        var parsed = ReleaseParser.parse("Movie.2021.1080p.WEB-DL.H.264-GRP")
        parsed.flags.insert(.sample)
        let sample = ReleaseCandidate(release: qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6).release, parsed: parsed)
        #expect(decide(sample).rejections == [.sample])
        parsed.flags = [.extra]
        let extra = ReleaseCandidate(release: sample.release, parsed: parsed)
        #expect(decide(extra).rejections == [.extraContent])
    }

    @Test func missingLinkRejects() {
        var release = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6).release
        release.downloadURL = nil
        #expect(decide(ReleaseCandidate(release: release)).rejections == [.noDownloadLink])
        release.magnetURL = URL(string: "magnet:?xt=urn:btih:abc")
        #expect(decide(ReleaseCandidate(release: release)).isAccepted)
    }

    @Test func sizeLimitsUseRuntime() {
        // 100 minutes: 1080p WEB-DL allows 8...350 MB/min = 0.78...34 GiB.
        #expect(decide(qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 0.3)).rejections.map(\.code) == ["sizeTooSmall"])
        #expect(decide(qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 40)).rejections.map(\.code) == ["sizeTooLarge"])
        #expect(decide(qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6)).isAccepted)
        // Unknown size or runtime skips the check.
        #expect(decide(qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: nil)).isAccepted)
    }

    @Test func profileCanOverrideSizeDefinitions() {
        var custom = profile
        custom.definitionOverrides = [QualityDefinition(tier: .webDL1080p, min: 1, preferred: 30, max: 40)]
        let c = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6)  // 61 MB/min
        var context = DecisionContext(wanted: movie, profile: custom, now: qualityNow)
        #expect(ReleaseDecisionEngine.decide([c], in: context)[0].rejections.map(\.code) == ["sizeTooLarge"])
        context.profile = profile
        #expect(ReleaseDecisionEngine.decide([c], in: context)[0].isAccepted)
    }

    @Test func seasonPackSizeUsesEpisodeCount() {
        let wanted = WantedItem.season("Show", season: 1, episodeCount: 10, runtimeMinutes: 45)
        let pack = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-GRP", sizeGB: 30)  // 68 MB/min
        let tiny = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-TINY", sizeGB: 1)
        let results = ReleaseDecisionEngine.decide([pack, tiny], in: DecisionContext(wanted: wanted, profile: profile, now: qualityNow))
        #expect(results[0].candidate.release.title == pack.release.title && results[0].isAccepted)
        #expect(results[1].rejections.map(\.code) == ["sizeTooSmall"])
    }

    @Test func packPolicyForSingleEpisodes() {
        let wanted = WantedItem.episode("Show", season: 1, episodes: [3], runtimeMinutes: 45, seasonEpisodeCount: 10)
        let pack = qualityMakeCandidate("Show.S01.1080p.WEB-DL.H.264-GRP", sizeGB: 30)
        var context = DecisionContext(wanted: wanted, profile: profile, now: qualityNow)
        #expect(ReleaseDecisionEngine.decide([pack], in: context)[0].isAccepted)
        #expect(ReleaseDecisionEngine.decide([pack], in: context)[0].isPack)
        context.allowPacksForEpisodes = false
        #expect(ReleaseDecisionEngine.decide([pack], in: context)[0].rejections == [.packNotWanted])
    }

    @Test func multiEpisodeReleaseCoversWantedEpisode() {
        let wanted = WantedItem.episode("Show", season: 1, episodes: [3], runtimeMinutes: 45)
        let multi = qualityMakeCandidate("Show.S01E02E03.1080p.WEB-DL.H.264-GRP", sizeGB: 5)
        let other = qualityMakeCandidate("Show.S01E04E05.1080p.WEB-DL.H.264-GRP", sizeGB: 5)
        let results = ReleaseDecisionEngine.decide([multi, other], in: DecisionContext(wanted: wanted, profile: profile, now: qualityNow))
        #expect(results[0].candidate.release.title == multi.release.title && results[0].isAccepted)
        #expect(results[1].rejections.map(\.code) == ["wrongEpisode"])
    }

    @Test func dailyShowsMatchByAirDate() {
        let wanted = WantedItem.episode("The Daily Show", season: nil, episodes: [], airDate: AirDate(year: 2024, month: 5, day: 14), runtimeMinutes: 30)
        let match = qualityMakeCandidate("The.Daily.Show.2024.05.14.1080p.WEB-DL.H.264-GRP", sizeGB: 2)
        let other = qualityMakeCandidate("The.Daily.Show.2024.05.15.1080p.WEB-DL.H.264-GRP", sizeGB: 2)
        let results = ReleaseDecisionEngine.decide([other, match], in: DecisionContext(wanted: wanted, profile: profile, now: qualityNow))
        #expect(results[0].candidate.release.title == match.release.title && results[0].isAccepted)
        #expect(results[1].rejections.map(\.code) == ["wrongEpisode"])
    }

    @Test func movieYearToleranceIsOne() {
        #expect(decide(qualityMakeCandidate("Movie.2022.1080p.WEB-DL.H.264-GRP", sizeGB: 6)).isAccepted)
        #expect(decide(qualityMakeCandidate("Movie.2024.1080p.WEB-DL.H.264-GRP", sizeGB: 6)).rejections.map(\.code) == ["wrongYear"])
    }

    @Test func titleAliasesAndYearSuffixMatch() {
        let wanted = WantedItem.movie("Spirited Away", year: 2001, runtimeMinutes: 125, aliases: ["Sen to Chihiro no Kamikakushi"])
        let alias = qualityMakeCandidate("Sen.to.Chihiro.no.Kamikakushi.2001.1080p.BluRay.x264-GRP", sizeGB: 10)
        let context = DecisionContext(wanted: wanted, profile: profile, now: qualityNow)
        #expect(ReleaseDecisionEngine.decide([alias], in: context)[0].isAccepted)
    }

    @Test func blocklistMatchesByHashAndTitle() {
        var blocklist = ReleaseBlocklist()
        blocklist.add(infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01", title: nil, reason: "hash failed")
        blocklist.add(infoHash: nil, title: "Movie.2021.1080p.WEB-DL.H.264-BAD", reason: "wrong content")
        let byHash = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6, hash: "abcdef0123456789abcdef0123456789abcdef01")
        let byTitle = qualityMakeCandidate("movie.2021.1080p.web-dl.h.264-bad", sizeGB: 6)
        let clean = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-OK", sizeGB: 6)
        var context = DecisionContext(wanted: movie, profile: profile, now: qualityNow)
        context.blocklist = blocklist
        let results = ReleaseDecisionEngine.decide([byHash, byTitle, clean], in: context)
        #expect(results.best?.candidate.release.title == clean.release.title)
        let reasons = results.rejected.flatMap(\.rejections)
        #expect(reasons.contains(.blocklisted(reason: "hash failed")) && reasons.contains(.blocklisted(reason: "wrong content")))
        #expect(!blocklist.isEmpty && ReleaseBlocklist().isEmpty)
    }

    @Test func blocklistBuildsFromPersistedEntries() {
        let entry = BlocklistEntry(titleId: UUID(), releaseTitle: "Some.Title", infoHash: "aa", reason: "stalled")
        let list = ReleaseBlocklist(entries: [entry])
        #expect(list.reason(for: qualityMakeCandidate("some.title").release) == "stalled")
    }

    @Test func freeSpaceAccountsForReserve() {
        let c = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6)
        #expect(decide(c) { $0.freeSpaceBytes = 7 * 1_073_741_824 }.isAccepted)
        let tight = decide(c) { $0.freeSpaceBytes = 7 * 1_073_741_824; $0.reservedFreeSpaceBytes = 2 * 1_073_741_824 }
        #expect(tight.rejections.map(\.code) == ["notEnoughFreeSpace"])
        #expect(tight.rejections[0].isTemporary)
    }

    @Test func minimumSeedersAppliesAndUnknownSeedersPass() {
        let few = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", seeders: 2, sizeGB: 6)
        #expect(decide(few) { $0.minimumSeeders = 3 }.rejections == [.tooFewSeeders(found: 2, required: 3)])
        let unknown = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", seeders: nil, sizeGB: 6)
        #expect(decide(unknown) { $0.minimumSeeders = 3 }.isAccepted)
    }

    @Test func formatScoreMinimumRejects() {
        let bad = qualityFormat("Bad group", FormatSpecification(type: .releaseGroup, value: "BADGRP"))
        let p = qualityProfile(allowing: [.webDL1080p], minScore: -5, scores: [(bad, -100)])
        var context = DecisionContext(wanted: movie, profile: p, formats: [bad], now: qualityNow)
        let c = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-BADGRP", sizeGB: 6)
        let d = ReleaseDecisionEngine.decide([c], in: context)[0]
        #expect(d.rejections == [.formatScoreBelowMinimum(score: -100, minimum: -5)])
        context.formats = []  // not evaluated -> no score
        #expect(ReleaseDecisionEngine.decide([c], in: context)[0].isAccepted)
    }

    @Test func rejectedDecisionsOrderTemporaryBeforePermanent() {
        let ok = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-OK", sizeGB: 6)
        let thin = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-THIN", seeders: 0, sizeGB: 6)
        let wrong = qualityMakeCandidate("Other.2021.1080p.WEB-DL.H.264-X", sizeGB: 6)
        let results = ReleaseDecisionEngine.decide([wrong, thin, ok], in: DecisionContext(wanted: movie, profile: profile, now: qualityNow))
        #expect(results.map(\.candidate.release.title) == [ok, thin, wrong].map(\.release.title))
    }

    @Test func rejectionMessagesAreReadable() {
        #expect(Rejection.tooFewSeeders(found: 1, required: 5).message == "Only 1 seeder (minimum 5)")
        #expect(Rejection.qualityNotAllowed(.webDL2160p).message == "2160p WEB-DL is not allowed in your quality profile")
        #expect(Rejection.notEnoughFreeSpace(required: 6 * 1_073_741_824, available: 2 * 1_073_741_824).message == "Needs 6.0 GB but only 2.0 GB is free")
        #expect(Rejection.formatScoreBelowMinimum(score: -100, minimum: 0).message == "Custom format score -100 is below your minimum of 0")
        #expect(Rejection.cutoffMet(current: .bluray1080p, currentScore: 60).message.contains("meets your cutoff"))
    }
}

@Suite struct ExplanationTests {
    @Test func pickedExplanationNamesQualityScoreAndSeeders() {
        let hdr = qualityFormat("HDR10", FormatSpecification(type: .hdr, value: "hdr10"))
        let atmos = qualityFormat("Atmos", FormatSpecification(type: .audioCodec, value: "atmos"))
        let profile = qualityProfile(allowing: [.webDL1080p], scores: [(hdr, 100), (atmos, 50)])
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let great = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.DDP5.1.Atmos.HDR10.H.265-GRP", seeders: 312, sizeGB: 8)
        let plain = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.DDP5.1.H.264-GRP", seeders: 500, sizeGB: 8)
        let context = DecisionContext(wanted: wanted, profile: profile, formats: [hdr, atmos], now: qualityNow)
        let results = ReleaseDecisionEngine.decide([plain, great], in: context)
        let explanation = results[0].explanation
        #expect(explanation.headline == "Picked because")
        #expect(explanation.reasons[0] == "1080p WEB-DL is in your Test profile")
        #expect(explanation.reasons.contains("custom format score +150 (HDR10, Atmos)"))
        #expect(explanation.reasons.contains("312 seeders"))
        #expect(explanation.reasons.contains { $0.hasPrefix("8.0 GB (") && $0.hasSuffix("MB/min)") })
        #expect(explanation.reasons.last == "ranked above \"\(plain.release.title)\" on custom format score")
        #expect(explanation.text.hasPrefix("Picked because: 1080p WEB-DL is in your Test profile; "))

        let second = results[1].explanation
        #expect(second.headline == "Acceptable")
        #expect(second.reasons.contains("custom format score +0") == false)
        #expect(second.reasons.contains("500 seeders"))
    }

    @Test func upgradeAndRejectionExplanations() {
        let profile = qualityProfile(allowing: [.webDL720p, .bluray1080p], cutoff: .bluray1080p)
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 100)
        let context = DecisionContext(wanted: wanted, profile: profile, current: CurrentFile(tier: .webDL720p, formatScore: 0), now: qualityNow)
        let up = qualityMakeCandidate("Movie.2021.1080p.BluRay.x264-GRP", seeders: 1, sizeGB: 10)
        let nope = qualityMakeCandidate("Movie.2021.480p.DVDRip.x264-GRP", seeders: 9, sizeGB: 1)
        let results = ReleaseDecisionEngine.decide([nope, up], in: context)
        #expect(results[0].explanation.text.contains("upgrade from 720p WEB-DL (score 0)"))
        #expect(results[0].explanation.text.contains("1 seeder;") || results[0].explanation.text.contains("1 seeder"))
        #expect(results[1].explanation.text == "Rejected: DVD is not allowed in your quality profile")
    }
}
