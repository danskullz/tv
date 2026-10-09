import Foundation

/// Why a candidate release was not accepted. Typed so the UI can filter and explain; `message` is the
/// plain-language form shown in the interactive search table.
public enum Rejection: Sendable, Hashable, Codable {
    case wrongTitle(found: String, expected: String)
    case wrongYear(found: Int, expected: Int)
    case wrongEpisode(expected: String, found: String)
    /// A pack was returned but the search policy only wants single episodes.
    case packNotWanted
    case sample
    case extraContent
    case noDownloadLink
    case qualityNotAllowed(QualityTier)
    case upgradesDisabled(current: QualityTier)
    /// The existing file already meets the profile's cutoff (quality, and score where relevant).
    case cutoffMet(current: QualityTier, currentScore: Int)
    case notAnUpgrade(current: QualityTier, candidate: QualityTier)
    case upgradeScoreTooSmall(currentScore: Int, candidateScore: Int, requiredIncrease: Int)
    /// Quality is below the cutoff, but the file already reached the profile's "upgrade until" score.
    case upgradeScoreReached(currentScore: Int, target: Int)
    case sizeTooSmall(mbPerMinute: Double, minimum: Double)
    case sizeTooLarge(mbPerMinute: Double, maximum: Double)
    case tooFewSeeders(found: Int, required: Int)
    case blocklisted(reason: String)
    case formatScoreBelowMinimum(score: Int, minimum: Int)
    case notEnoughFreeSpace(required: Int64, available: Int64)
    case delayed(until: Date)

    /// Stable machine-readable name of the case (used by fixtures and analytics-free logs).
    public var code: String {
        switch self {
        case .wrongTitle: "wrongTitle"
        case .wrongYear: "wrongYear"
        case .wrongEpisode: "wrongEpisode"
        case .packNotWanted: "packNotWanted"
        case .sample: "sample"
        case .extraContent: "extraContent"
        case .noDownloadLink: "noDownloadLink"
        case .qualityNotAllowed: "qualityNotAllowed"
        case .upgradesDisabled: "upgradesDisabled"
        case .cutoffMet: "cutoffMet"
        case .notAnUpgrade: "notAnUpgrade"
        case .upgradeScoreTooSmall: "upgradeScoreTooSmall"
        case .upgradeScoreReached: "upgradeScoreReached"
        case .sizeTooSmall: "sizeTooSmall"
        case .sizeTooLarge: "sizeTooLarge"
        case .tooFewSeeders: "tooFewSeeders"
        case .blocklisted: "blocklisted"
        case .formatScoreBelowMinimum: "formatScoreBelowMinimum"
        case .notEnoughFreeSpace: "notEnoughFreeSpace"
        case .delayed: "delayed"
        }
    }

    /// True when the release may become acceptable later without anything about the release changing
    /// (swarm recovers, space is freed, delay elapses).
    public var isTemporary: Bool {
        switch self {
        case .tooFewSeeders, .notEnoughFreeSpace, .delayed: true
        default: false
        }
    }

    public var message: String {
        switch self {
        case .wrongTitle(let found, let expected): "Title \"\(found)\" does not match \"\(expected)\""
        case .wrongYear(let found, let expected): "Year \(found) does not match \(expected)"
        case .wrongEpisode(let expected, let found): "Wanted \(expected) but this is \(found)"
        case .packNotWanted: "Season packs are not wanted for a single episode"
        case .sample: "Sample file, not the full release"
        case .extraContent: "Extras or bonus content, not the main video"
        case .noDownloadLink: "No download link or magnet from the indexer"
        case .qualityNotAllowed(let tier): "\(tier.displayName) is not allowed in your quality profile"
        case .upgradesDisabled(let current): "You already have \(current.displayName) and upgrades are turned off"
        case .cutoffMet(let current, let score):
            "You already have \(current.displayName) (score \(Self.signed(score))), which meets your cutoff"
        case .notAnUpgrade(let current, let candidate):
            "\(candidate.displayName) is not an upgrade over your \(current.displayName)"
        case .upgradeScoreTooSmall(let currentScore, let candidateScore, let required):
            "Score \(Self.signed(candidateScore)) improves on \(Self.signed(currentScore)) by less than the required \(required)"
        case .upgradeScoreReached(let currentScore, let target):
            "Your file's score \(Self.signed(currentScore)) already reaches the upgrade-until score \(target)"
        case .sizeTooSmall(let value, let minimum):
            "Only \(Self.mb(value)) MB/min; \(Self.mb(minimum)) MB/min is the minimum for this quality"
        case .sizeTooLarge(let value, let maximum):
            "\(Self.mb(value)) MB/min is above the \(Self.mb(maximum)) MB/min maximum for this quality"
        case .tooFewSeeders(let found, let required):
            "Only \(found) seeder\(found == 1 ? "" : "s") (minimum \(required))"
        case .blocklisted(let reason): "Blocklisted: \(reason)"
        case .formatScoreBelowMinimum(let score, let minimum):
            "Custom format score \(Self.signed(score)) is below your minimum of \(Self.signed(minimum))"
        case .notEnoughFreeSpace(let required, let available):
            "Needs \(Self.bytes(required)) but only \(Self.bytes(available)) is free"
        case .delayed(let until):
            "Held back by your delay profile until \(until.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    static func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }
    static func mb(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
    static func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}

/// The criterion that separated two releases in the ranking.
public enum RankCriterion: String, Sendable, Hashable, Codable {
    case quality, formatScore, indexerPriority, seeders, sizePreference, age, tiebreak

    public var label: String {
        switch self {
        case .quality: "quality tier"
        case .formatScore: "custom format score"
        case .indexerPriority: "indexer priority"
        case .seeders: "seeders"
        case .sizePreference: "size preference"
        case .age: "age"
        case .tiebreak: "a stable tiebreak"
        }
    }
}

/// Everything the ranking compares, precomputed per release.
///
/// Order of significance (each criterion only matters when all earlier ones tie):
/// 1. quality group index in the profile (higher wins; tiers in one group are equal)
/// 2. custom-format score (higher wins)
/// 3. indexer priority (lower number wins, Prowlarr convention)
/// 4. seeder bucket, `floor(log2(seeders + 1))` (higher wins; 312 vs 290 seeders tie, 40 vs 300 do not)
/// 5. size preference: distance to the preferred size (1 % buckets; lower wins)
/// 6. age in whole hours (newer wins)
/// 7. release guid, then input order, so ordering is deterministic
public struct RankKey: Sendable, Hashable {
    public var qualityGroup: Int
    public var formatScore: Int
    public var indexerPriority: Int
    public var seederBucket: Int
    public var sizeDistance: Double
    public var ageHours: Int
    /// Release guid; makes ordering deterministic when everything else ties.
    public var tiebreak: String
    /// Position in the input list; the last resort so equal guids from different indexers still order stably.
    public var sequence: Int

    public init(
        qualityGroup: Int, formatScore: Int, indexerPriority: Int = 25, seederBucket: Int = 0,
        sizeDistance: Double = 0, ageHours: Int = Int.max, tiebreak: String = "", sequence: Int = 0
    ) {
        self.sequence = sequence
        self.qualityGroup = qualityGroup
        self.formatScore = formatScore
        self.indexerPriority = indexerPriority
        self.seederBucket = seederBucket
        self.sizeDistance = sizeDistance
        self.ageHours = ageHours
        self.tiebreak = tiebreak
    }

    public static func seederBucket(for seeders: Int?) -> Int {
        let s = max(0, seeders ?? 0)
        return Int(Double(s + 1).log2Floor)
    }

    /// The criterion at which `lhs` and `rhs` first differ, and which one wins there.
    /// `lhsWins == nil` only when the keys are identical.
    public static func compare(_ lhs: RankKey, _ rhs: RankKey) -> (lhsWins: Bool?, criterion: RankCriterion?) {
        if lhs.qualityGroup != rhs.qualityGroup { return (lhs.qualityGroup > rhs.qualityGroup, .quality) }
        if lhs.formatScore != rhs.formatScore { return (lhs.formatScore > rhs.formatScore, .formatScore) }
        if lhs.indexerPriority != rhs.indexerPriority { return (lhs.indexerPriority < rhs.indexerPriority, .indexerPriority) }
        if lhs.seederBucket != rhs.seederBucket { return (lhs.seederBucket > rhs.seederBucket, .seeders) }
        if lhs.sizeDistance != rhs.sizeDistance { return (lhs.sizeDistance < rhs.sizeDistance, .sizePreference) }
        if lhs.ageHours != rhs.ageHours { return (lhs.ageHours < rhs.ageHours, .age) }
        if lhs.tiebreak != rhs.tiebreak { return (lhs.tiebreak < rhs.tiebreak, .tiebreak) }
        if lhs.sequence != rhs.sequence { return (lhs.sequence < rhs.sequence, .tiebreak) }
        return (nil, nil)
    }

    /// Strict "ranks before" ordering for sorting best-first.
    public static func ranksBefore(_ lhs: RankKey, _ rhs: RankKey) -> Bool {
        compare(lhs, rhs).lhsWins ?? false
    }
}

private extension Double {
    var log2Floor: Double { Foundation.log2(self).rounded(.down) }
}

/// A human-readable account of a decision.
public struct DecisionExplanation: Sendable, Hashable {
    /// "Picked because", "Acceptable" or "Rejected".
    public var headline: String
    public var reasons: [String]

    /// One line, e.g. "Picked because: 1080p WEB-DL is in your profile; custom format score +150 (HDR10, Atmos); 312 seeders".
    public var text: String { reasons.isEmpty ? headline : "\(headline): \(reasons.joined(separator: "; "))" }
}

/// Facts kept on a decision so its explanation can be produced lazily.
struct ExplanationFacts: Sendable, Hashable {
    var profileName: String
    var current: CurrentFile?
    var delayNote: String?
    var beatTitle: String?
    var beatCriterion: RankCriterion?
    var sizeMBPerMinute: Double?
}

/// The engine's verdict on one candidate.
public struct ReleaseDecision: Sendable, Hashable, Identifiable {
    public var candidate: ReleaseCandidate
    public var tier: QualityTier
    public var formatScore: Int
    public var matchedFormats: [FormatMatch]
    public var rejections: [Rejection]
    public var rankKey: RankKey
    /// 1-based position among accepted decisions; nil for rejected ones.
    public var rank: Int?
    /// Whether the release is a pack relative to what was wanted.
    public var isPack: Bool
    var facts: ExplanationFacts

    public var id: String { candidate.id }
    public var isAccepted: Bool { rejections.isEmpty }

    init(
        candidate: ReleaseCandidate, tier: QualityTier, formatScore: Int, matchedFormats: [FormatMatch],
        rejections: [Rejection], rankKey: RankKey, rank: Int? = nil, isPack: Bool, facts: ExplanationFacts
    ) {
        self.candidate = candidate
        self.tier = tier
        self.formatScore = formatScore
        self.matchedFormats = matchedFormats
        self.rejections = rejections
        self.rankKey = rankKey
        self.rank = rank
        self.isPack = isPack
        self.facts = facts
    }

    public var explanation: DecisionExplanation {
        if !isAccepted {
            return DecisionExplanation(headline: "Rejected", reasons: rejections.map(\.message))
        }
        var reasons = ["\(tier.displayName) is in your \(facts.profileName) profile"]
        if let current = facts.current {
            reasons.append("upgrade from \(current.tier.displayName) (score \(Rejection.signed(current.formatScore)))")
        }
        if !matchedFormats.isEmpty || formatScore != 0 {
            let names = matchedFormats.sorted { abs($0.score) > abs($1.score) }.map(\.name).joined(separator: ", ")
            reasons.append("custom format score \(Rejection.signed(formatScore))" + (names.isEmpty ? "" : " (\(names))"))
        }
        if let seeders = candidate.release.seeders {
            reasons.append("\(seeders) seeder\(seeders == 1 ? "" : "s")")
        }
        if let size = candidate.release.size {
            var text = Rejection.bytes(size)
            if let mbpm = facts.sizeMBPerMinute { text += " (\(Rejection.mb(mbpm)) MB/min)" }
            reasons.append(text)
        }
        if let note = facts.delayNote { reasons.append(note) }
        if let beat = facts.beatTitle, let criterion = facts.beatCriterion {
            reasons.append("ranked above \"\(beat)\" on \(criterion.label)")
        }
        return DecisionExplanation(headline: rank == 1 ? "Picked because" : "Acceptable", reasons: reasons)
    }
}

extension Array where Element == ReleaseDecision {
    public var accepted: [ReleaseDecision] { filter(\.isAccepted) }
    public var rejected: [ReleaseDecision] { filter { !$0.isAccepted } }
    /// The top-ranked accepted decision.
    public var best: ReleaseDecision? { first { $0.isAccepted } }
}
