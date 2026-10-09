import Foundation

/// Everything the engine needs besides the candidates.
public struct DecisionContext: Sendable {
    public var wanted: WantedItem
    public var profile: QualityProfileConfig
    /// All known custom formats; only those the profile scores are evaluated.
    public var formats: [CustomFormatConfig]
    public var current: CurrentFile?
    public var blocklist: ReleaseBlocklist
    public var minimumSeeders: Int
    public var freeSpaceBytes: Int64?
    /// Free space that must remain after the download.
    public var reservedFreeSpaceBytes: Int64
    public var delayProfile: DelayProfileConfig?
    /// Injected clock for delay and age calculations.
    public var now: Date
    /// Interactive search and Play skip the delay profile.
    public var ignoreDelay: Bool
    /// Indexer id -> priority (1 best ... 50 worst); missing means 25.
    public var indexerPriorities: [UUID: Int]
    /// When false, season packs are rejected while a single episode is wanted.
    public var allowPacksForEpisodes: Bool

    public init(
        wanted: WantedItem, profile: QualityProfileConfig, formats: [CustomFormatConfig] = [],
        current: CurrentFile? = nil, blocklist: ReleaseBlocklist = ReleaseBlocklist(), minimumSeeders: Int = 1,
        freeSpaceBytes: Int64? = nil, reservedFreeSpaceBytes: Int64 = 0, delayProfile: DelayProfileConfig? = nil,
        now: Date = Date(), ignoreDelay: Bool = false, indexerPriorities: [UUID: Int] = [:],
        allowPacksForEpisodes: Bool = true
    ) {
        self.wanted = wanted
        self.profile = profile
        self.formats = formats
        self.current = current
        self.blocklist = blocklist
        self.minimumSeeders = minimumSeeders
        self.freeSpaceBytes = freeSpaceBytes
        self.reservedFreeSpaceBytes = reservedFreeSpaceBytes
        self.delayProfile = delayProfile
        self.now = now
        self.ignoreDelay = ignoreDelay
        self.indexerPriorities = indexerPriorities
        self.allowPacksForEpisodes = allowPacksForEpisodes
    }
}

extension QualityProfileConfig {
    /// Why a release of `candidateTier` / `candidateScore` is not an upgrade over `current`, or nil when it is.
    ///
    /// - Quality below the cutoff: a better group is always an upgrade; the same group needs a score gain
    ///   (and the file must not already have reached the upgrade-until score).
    /// - Quality at/above the cutoff: only score gains count, until the file reaches the upgrade-until score;
    ///   never downgrade to a lower group.
    public func upgradeRejection(current: CurrentFile, candidateTier: QualityTier, candidateScore: Int) -> Rejection? {
        guard upgradeAllowed else { return .upgradesDisabled(current: current.tier) }
        let currentGroup = groupIndex(of: current.tier) ?? -1
        let candidateGroup = groupIndex(of: candidateTier) ?? -1
        let belowCutoff = currentGroup < cutoffGroupIndex
        if belowCutoff {
            if candidateGroup > currentGroup { return nil }
            if candidateGroup < currentGroup { return .notAnUpgrade(current: current.tier, candidate: candidateTier) }
            if current.formatScore >= upgradeUntilFormatScore {
                return .upgradeScoreReached(currentScore: current.formatScore, target: upgradeUntilFormatScore)
            }
        } else {
            if current.formatScore >= upgradeUntilFormatScore {
                return .cutoffMet(current: current.tier, currentScore: current.formatScore)
            }
            if candidateGroup < currentGroup { return .notAnUpgrade(current: current.tier, candidate: candidateTier) }
        }
        let required = max(1, minFormatScoreIncrement)
        let gain = candidateScore - current.formatScore
        if gain >= required { return nil }
        if gain <= 0 { return .notAnUpgrade(current: current.tier, candidate: candidateTier) }
        return .upgradeScoreTooSmall(currentScore: current.formatScore, candidateScore: candidateScore, requiredIncrease: required)
    }
}

/// Filters and ranks candidate releases against a wanted item, a quality profile and custom formats.
public struct ReleaseDecisionEngine: Sendable {
    public let context: DecisionContext
    private let scoredFormats: [(format: CompiledFormat, score: Int)]
    /// Per-tier lookups (indexed by `QualityTier.rank`) so evaluating a candidate does no searching.
    private let groupIndexByTier: [Int]
    private let allowedByTier: [Bool]
    private let definitionByTier: [QualityDefinition]

    public init(_ context: DecisionContext) {
        self.context = context
        let profile = context.profile
        scoredFormats = context.formats.compactMap { format in
            let score = profile.score(forFormat: format.id)
            return score == 0 ? nil : (CompiledFormat(format), score)
        }
        groupIndexByTier = QualityTier.allCases.map { profile.groupIndex(of: $0) ?? -1 }
        allowedByTier = QualityTier.allCases.map { profile.isAllowed($0) }
        definitionByTier = QualityTier.allCases.map { profile.definition(for: $0) }
    }

    public static func decide(_ candidates: [ReleaseCandidate], in context: DecisionContext) -> [ReleaseDecision] {
        ReleaseDecisionEngine(context).decide(candidates)
    }

    /// Accepted decisions first (best to worst, with `rank` set), then rejected ones: temporary-only
    /// rejections before permanent ones, each group ordered by the same comparator.
    public func decide(_ candidates: [ReleaseCandidate]) -> [ReleaseDecision] {
        var evaluated = [ReleaseDecision]()
        evaluated.reserveCapacity(candidates.count)
        var accepted = [Bool](), temporaryOnly = [Bool]()
        accepted.reserveCapacity(candidates.count)
        temporaryOnly.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            let decision = evaluate(candidate, sequence: index)
            accepted.append(decision.rejections.isEmpty)
            temporaryOnly.append(decision.rejections.allSatisfy { $0.isTemporary })
            evaluated.append(decision)
        }

        // Sort indices rather than the (large) decision values.
        let order = evaluated.indices.sorted { a, b in
            if accepted[a] != accepted[b] { return accepted[a] }
            if !accepted[a], temporaryOnly[a] != temporaryOnly[b] { return temporaryOnly[a] }
            return RankKey.ranksBefore(evaluated[a].rankKey, evaluated[b].rankKey)
        }
        // Apply the permutation in place with swaps (moves, no copies of the large values).
        for i in evaluated.indices {
            var j = order[i]
            while j < i { j = order[j] }
            if j != i { evaluated.swapAt(i, j) }
        }
        let acceptedCount = accepted.reduce(0) { $0 + ($1 ? 1 : 0) }
        for i in 0..<acceptedCount {
            evaluated[i].rank = i + 1
            if i == 0, acceptedCount > 1 {
                let runnerUp = evaluated[1]
                let verdict = RankKey.compare(evaluated[0].rankKey, runnerUp.rankKey)
                evaluated[0].setBeat(title: runnerUp.candidate.release.title, criterion: verdict.criterion)
            }
        }
        return evaluated
    }

    // MARK: Evaluation

    func evaluate(_ candidate: ReleaseCandidate, sequence: Int = 0) -> ReleaseDecision {
        var rejections: [Rejection] = []

        // Content: is this the thing we want?
        if !context.wanted.matchesTitle(candidate.parsed) {
            rejections.append(.wrongTitle(found: candidate.parsed.title, expected: context.wanted.title))
        } else if case .movie(let year?) = context.wanted.scope, let found = candidate.parsed.year, abs(found - year) > 1 {
            rejections.append(.wrongYear(found: found, expected: year))
        }
        var isPack = false
        switch context.wanted.match(candidate.parsed) {
        case .exact: break
        case .pack:
            isPack = true
            if !context.wanted.isSeason, !context.allowPacksForEpisodes { rejections.append(.packNotWanted) }
        case .mismatch(let expected, let found):
            // Title mismatches already explain themselves; don't pile on for unrelated releases.
            if rejections.isEmpty { rejections.append(.wrongEpisode(expected: expected, found: found)) }
        }
        if candidate.parsed.flags.contains(.sample) { rejections.append(.sample) }
        if candidate.parsed.flags.contains(.extra) { rejections.append(.extraContent) }
        if candidate.release.downloadURL == nil && candidate.release.magnetURL == nil && candidate.release.infoHash == nil {
            rejections.append(.noDownloadLink)
        }

        let contentOK = rejections.isEmpty

        /// A single special: sized against the series' regular episode runtime, which is often wrong.
        let isSpecialEpisode: Bool = {
            if case .episodes(let season?, _, _, _) = context.wanted.scope { return season == 0 }
            return false
        }()

        // Quality.
        let tier = QualityTier.derive(from: candidate.parsed)
        let tierRank = tier.rank
        let tierGroup: Int? = groupIndexByTier[tierRank] >= 0 ? groupIndexByTier[tierRank] : nil
        let tierAllowed = allowedByTier[tierRank]
        if !tierAllowed { rejections.append(.qualityNotAllowed(tier)) }

        // Custom formats.
        var matched: [FormatMatch] = []
        var score = 0
        if !scoredFormats.isEmpty {
            let facts = CandidateFacts(candidate)
            for (format, formatScore) in scoredFormats where format.matches(facts) {
                matched.append(FormatMatch(formatID: format.id, name: format.name, score: formatScore))
                score += formatScore
            }
        }
        if score < context.profile.minFormatScore {
            rejections.append(.formatScoreBelowMinimum(score: score, minimum: context.profile.minFormatScore))
        }

        // Size per runtime. Specials (season 0) vary wildly in length and are sized against the
        // series' regular episode runtime, so the maximum is waived for them; the minimum still
        // catches samples and junk.
        var mbPerMinute: Double?
        if let size = candidate.release.size, size > 0, let minutes = context.wanted.coveredRuntimeMinutes(for: candidate.parsed) {
            let value = Double(size) / 1_048_576 / minutes
            mbPerMinute = value
            if tierAllowed {
                let definition = definitionByTier[tierRank]
                if value < definition.minMBPerMinute {
                    rejections.append(.sizeTooSmall(mbPerMinute: value, minimum: definition.minMBPerMinute))
                } else if !isSpecialEpisode, let maximum = definition.maxMBPerMinute, value > maximum {
                    rejections.append(.sizeTooLarge(mbPerMinute: value, maximum: maximum))
                }
            }
        }

        // Swarm, blocklist, disk.
        if let seeders = candidate.release.seeders, seeders < context.minimumSeeders {
            rejections.append(.tooFewSeeders(found: seeders, required: context.minimumSeeders))
        }
        if let reason = context.blocklist.reason(for: candidate.release) { rejections.append(.blocklisted(reason: reason)) }
        if let free = context.freeSpaceBytes, let size = candidate.release.size, size + context.reservedFreeSpaceBytes > free {
            rejections.append(.notEnoughFreeSpace(required: size + context.reservedFreeSpaceBytes, available: free))
        }

        // Upgrade rules.
        if let current = context.current, tierAllowed, contentOK,
            let rejection = context.profile.upgradeRejection(current: current, candidateTier: tier, candidateScore: score)
        {
            rejections.append(rejection)
        }

        // Delay: only worth reporting for releases that would otherwise be grabbed.
        var delayNote: String?
        if rejections.isEmpty, !context.ignoreDelay, let delay = context.delayProfile {
            switch delay.evaluate(
                tierGroupIndex: tierGroup, formatScore: score, in: context.profile, publishDate: candidate.release.publishDate, now: context.now)
            {
            case .wait(let until): rejections.append(.delayed(until: until))
            case .proceed(let reason): if delay.delayMinutes > 0 { delayNote = "no delay: \(reason)" }
            }
        }

        let key = RankKey(
            qualityGroup: tierGroup ?? -1, formatScore: score,
            indexerPriority: context.indexerPriorities[candidate.release.indexerID] ?? 25,
            seederBucket: RankKey.seederBucket(for: candidate.release.seeders),
            sizeDistance: sizeDistance(size: candidate.release.size, mbPerMinute: mbPerMinute, rank: tierRank),
            ageHours: candidate.release.publishDate.map { Int(max(0, context.now.timeIntervalSince($0)) / 3600) } ?? Int.max,
            tiebreak: candidate.release.guid, sequence: sequence)

        return ReleaseDecision(
            candidate: candidate, tier: tier, formatScore: score, matchedFormats: matched, rejections: rejections,
            rankKey: key, isPack: isPack,
            facts: ExplanationFacts(
                profileName: context.profile.name, current: context.current, delayNote: delayNote, sizeMBPerMinute: mbPerMinute))
    }

    /// Lower is better.
    private func sizeDistance(size: Int64?, mbPerMinute: Double?, rank: Int) -> Double {
        func bucket(_ v: Double) -> Double { (log(max(v, 1)) / log(1.01)).rounded() }
        switch context.profile.sizePreference {
        case .smaller:
            guard let size else { return .infinity }
            return bucket(Double(size))
        case .larger:
            guard let size else { return .infinity }
            return -bucket(Double(size))
        case .nearPreferred:
            guard let mbPerMinute else { return 0 }
            let preferred = definitionByTier[rank].preferredMBPerMinute
            guard preferred > 0 else { return 0 }
            return (abs(mbPerMinute - preferred) / preferred * 100).rounded()
        }
    }
}

extension ReleaseDecision {
    mutating func setBeat(title: String, criterion: RankCriterion?) {
        facts.setBeat(title: title, criterion: criterion)
    }
}

extension ExplanationFacts {
    mutating func setBeat(title: String, criterion: RankCriterion?) {
        beatTitle = title
        beatCriterion = criterion
    }
}
