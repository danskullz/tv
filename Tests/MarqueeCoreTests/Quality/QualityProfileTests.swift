import Foundation
import Testing
@testable import MarqueeCore

@Suite struct QualityTierTests {
    @Test(arguments: [
        ("Movie.2021.2160p.UHD.BluRay.REMUX.HEVC-GRP", QualityTier.remux2160p),
        ("Movie.2021.1080p.BluRay.REMUX.AVC-GRP", .remux1080p),
        ("Movie.2021.2160p.BluRay.x265-GRP", .bluray2160p),
        ("Movie.2021.1080p.BluRay.x264-GRP", .bluray1080p),
        ("Movie.2021.720p.BluRay.x264-GRP", .bluray720p),
        ("Movie.2021.480p.BluRay.x264-GRP", .dvd),
        ("Movie.2021.BluRay.x264-GRP", .bluray1080p),
        ("Movie.2021.2160p.WEB-DL.H.265-GRP", .webDL2160p),
        ("Movie.2021.1080p.WEBRip.x264-GRP", .webRip1080p),
        ("Movie.2021.720p.WEB-DL.x264-GRP", .webDL720p),
        ("Movie.2021.480p.WEB-DL.x264-GRP", .webDL480p),
        ("Movie.2021.1080p.x264-GRP", .webDL1080p),
        ("Show.S01E01.720p.HDTV.x264-GRP", .hdtv720p),
        ("Show.S01E01.1080p.HDTV.x264-GRP", .hdtv1080p),
        ("Show.S01E01.HDTV.x264-GRP", .hdtv720p),
        ("Show.S01E01.SDTV.XviD-GRP", .sdtv),
        ("Movie.2005.DVDRip.XviD-GRP", .dvd),
        ("Movie.2021.1080p.CAM.x264-GRP", .preRelease),
        ("Movie.2021.TS.x264-GRP", .preRelease),
    ])
    func derivesTier(_ name: String, _ expected: QualityTier) {
        #expect(QualityTier.derive(from: ReleaseParser.parse(name)) == expected, "\(name)")
    }

    @Test func tiersAreOrderedWorstToBest() {
        #expect(QualityTier.sdtv < .dvd)
        #expect(QualityTier.webDL1080p < .bluray1080p)
        #expect(QualityTier.bluray1080p < .remux1080p)
        #expect(QualityTier.remux1080p < .hdtv2160p)
        #expect(QualityTier.allCases.map(\.rank) == Array(0..<QualityTier.allCases.count))
    }

    @Test func everyTierHasADefinitionWithSaneLimits() {
        for tier in QualityTier.allCases {
            let d = QualityDefinition.defaultDefinition(for: tier)
            #expect(d.tier == tier)
            #expect(d.minMBPerMinute <= d.preferredMBPerMinute)
            if let max = d.maxMBPerMinute { #expect(d.preferredMBPerMinute <= max) }
        }
    }
}

@Suite struct QualityProfileTests {
    private func profile(
        cutoff: QualityTier = .bluray1080p, upgradeUntil: Int = 50, increment: Int = 10, upgrades: Bool = true
    ) -> QualityProfileConfig {
        qualityProfile(
            allowing: [.webDL720p, .webDL1080p, .bluray1080p, .bluray2160p], cutoff: cutoff, upgradeAllowed: upgrades,
            upgradeUntil: upgradeUntil, increment: increment)
    }

    // MARK: Groups

    @Test func webDLAndWebRipShareAGroup() {
        let p = profile()
        #expect(p.groupIndex(of: .webDL1080p) == p.groupIndex(of: .webRip1080p))
        #expect(p.groupIndex(of: .webDL1080p)! < p.groupIndex(of: .bluray1080p)!)
        #expect(p.isAllowed(.webRip1080p))
        #expect(!p.isAllowed(.hdtv1080p))
        #expect(!p.isAllowed(.remux2160p))
    }

    @Test func missingCutoffMeansHighestAllowedGroup() {
        let p = qualityProfile(allowing: [.webDL1080p, .bluray2160p])
        #expect(p.cutoffGroupIndex == p.groupIndex(of: .bluray2160p))
    }

    // MARK: Upgrade rules

    @Test func belowCutoffHigherQualityIsAlwaysAnUpgrade() {
        let r = profile().upgradeRejection(current: .init(tier: .webDL720p), candidateTier: .webDL1080p, candidateScore: -20)
        #expect(r == nil)
    }

    @Test func belowCutoffLowerOrEqualQualityWithoutScoreGainIsRejected() {
        let p = profile()
        let current = CurrentFile(tier: .webDL1080p, formatScore: 0)
        #expect(p.upgradeRejection(current: current, candidateTier: .webDL720p, candidateScore: 100)
            == .notAnUpgrade(current: .webDL1080p, candidate: .webDL720p))
        #expect(p.upgradeRejection(current: current, candidateTier: .webRip1080p, candidateScore: 0)
            == .notAnUpgrade(current: .webDL1080p, candidate: .webRip1080p))
    }

    @Test func sameQualityNeedsTheMinimumScoreIncrement() {
        let p = profile(increment: 10)
        let current = CurrentFile(tier: .webDL1080p, formatScore: 5)
        #expect(p.upgradeRejection(current: current, candidateTier: .webDL1080p, candidateScore: 14)
            == .upgradeScoreTooSmall(currentScore: 5, candidateScore: 14, requiredIncrease: 10))
        #expect(p.upgradeRejection(current: current, candidateTier: .webDL1080p, candidateScore: 15) == nil)
    }

    @Test func atCutoffOnlyScoreGainsCountUntilTheUpgradeUntilScore() {
        let p = profile(upgradeUntil: 50, increment: 10)
        let atCutoff = CurrentFile(tier: .bluray1080p, formatScore: 20)
        // Better tier but no score gain: not an upgrade once the cutoff is met.
        #expect(p.upgradeRejection(current: atCutoff, candidateTier: .bluray2160p, candidateScore: 20)
            == .notAnUpgrade(current: .bluray1080p, candidate: .bluray2160p))
        // Score gain from the same tier is.
        #expect(p.upgradeRejection(current: atCutoff, candidateTier: .bluray1080p, candidateScore: 40) == nil)
        // Never downgrade the tier for score.
        #expect(p.upgradeRejection(current: atCutoff, candidateTier: .webDL1080p, candidateScore: 200)
            == .notAnUpgrade(current: .bluray1080p, candidate: .webDL1080p))
        // Reached the upgrade-until score: stop.
        let done = CurrentFile(tier: .bluray1080p, formatScore: 50)
        #expect(p.upgradeRejection(current: done, candidateTier: .bluray1080p, candidateScore: 500)
            == .cutoffMet(current: .bluray1080p, currentScore: 50))
    }

    @Test func belowCutoffStopsScoreUpgradesAtTheUpgradeUntilScore() {
        let p = profile(upgradeUntil: 50)
        let r = p.upgradeRejection(current: .init(tier: .webDL1080p, formatScore: 60), candidateTier: .webDL1080p, candidateScore: 200)
        #expect(r == .upgradeScoreReached(currentScore: 60, target: 50))
    }

    @Test func upgradesCanBeDisabled() {
        let r = profile(upgrades: false).upgradeRejection(current: .init(tier: .webDL720p), candidateTier: .bluray1080p, candidateScore: 99)
        #expect(r == .upgradesDisabled(current: .webDL720p))
    }

    @Test func engineAppliesUpgradeRulesToCandidates() {
        let p = profile()
        let context = DecisionContext(
            wanted: .movie("Movie", year: 2021, runtimeMinutes: 120), profile: p, current: CurrentFile(tier: .webDL1080p),
            now: qualityNow)
        let better = qualityMakeCandidate("Movie.2021.1080p.BluRay.x264-GRP", sizeGB: 12)
        let same = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-GRP", sizeGB: 6)
        let results = ReleaseDecisionEngine.decide([same, better], in: context)
        #expect(results.best?.candidate.release.title == better.release.title)
        #expect(results.last?.rejections.map(\.code) == ["notAnUpgrade"])
    }

    // MARK: Presets & persistence bridge

    @Test func presetsAreCompleteAndSelfConsistent() {
        #expect(QualityProfileConfig.presets.map(\.name) == ["Efficient", "Balanced", "Best", "Anime", "Remux"])
        let knownFormats = Set(BuiltInFormats.all.map(\.id.uuidString))
        for p in QualityProfileConfig.presets {
            let tiers = p.groups.flatMap(\.tiers)
            #expect(Set(tiers) == Set(QualityTier.allCases), "\(p.name) covers every tier once")
            #expect(tiers.count == QualityTier.allCases.count)
            #expect(p.groups.contains { $0.allowed })
            #expect(p.isAllowed(p.cutoff!), "\(p.name) cutoff is allowed")
            #expect(Set(p.formatScores.keys).isSubset(of: knownFormats))
            #expect(!p.isAllowed(.preRelease) && !p.isAllowed(.unknown))
        }
        #expect(QualityProfileConfig.efficient.sizePreference == .smaller)
        #expect(QualityProfileConfig.best.isAllowed(.remux2160p) && !QualityProfileConfig.balanced.isAllowed(.webDL2160p))
        #expect(QualityProfileConfig.remux.isAllowed(.remux1080p) && !QualityProfileConfig.remux.isAllowed(.bluray1080p))
    }

    @Test func builtInFormatIDsAreUniqueAndStable() {
        #expect(Set(BuiltInFormats.all.map(\.id)).count == BuiltInFormats.all.count)
        #expect(BuiltInFormats.dolbyVision.id.uuidString == "6D617271-0000-4000-8000-000000000001")
    }

    @Test func profileRoundTripsThroughJSON() throws {
        for p in QualityProfileConfig.presets {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(QualityProfileConfig.self, from: data) == p)
        }
    }

    @Test func profileMapsToPersistenceRecordAndBack() {
        let p = QualityProfileConfig.balanced
        let record = p.record()
        #expect(record.cutoff == "bluray1080p")
        #expect(record.items.count == QualityTier.allCases.count)
        let back = QualityProfileConfig(record: record)
        #expect(back.id == p.id && back.formatScores == p.formatScores)
        #expect(back.isAllowed(.bluray1080p) && !back.isAllowed(.webDL2160p))
        // The persistence bridge keeps equal-tier groups intact.
        #expect(back.groupIndex(of: .webDL1080p)! < back.groupIndex(of: .bluray1080p)!)
        #expect(back.groups == p.groups)
    }

    @Test func presetBehaviourOnRealisticReleases() {
        let wanted = WantedItem.movie("Movie", year: 2021, runtimeMinutes: 120)
        let hdr = qualityMakeCandidate("Movie.2021.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10Plus.H.265-FLUX", sizeGB: 22)
        let plain = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.DDP5.1.H.264-GRP", sizeGB: 6)
        func best(_ profile: QualityProfileConfig) -> String? {
            let context = DecisionContext(wanted: wanted, profile: profile, formats: BuiltInFormats.all, now: qualityNow)
            return ReleaseDecisionEngine.decide([plain, hdr], in: context).best?.candidate.release.title
        }
        #expect(best(.best) == hdr.release.title)
        #expect(best(.balanced) == plain.release.title)
        #expect(best(.efficient) == plain.release.title)
    }
}
