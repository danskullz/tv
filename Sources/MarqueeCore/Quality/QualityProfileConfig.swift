import Foundation

/// Tiers the profile treats as equal quality (e.g. WEB-DL and WEBRip of the same resolution).
public struct QualityGroup: Sendable, Hashable, Codable {
    public var name: String
    public var tiers: [QualityTier]
    public var allowed: Bool

    public init(name: String? = nil, tiers: [QualityTier], allowed: Bool = true) {
        self.name = name ?? tiers.map(\.displayName).joined(separator: " / ")
        self.tiers = tiers
        self.allowed = allowed
    }
}

/// Which end of the size range wins when everything else ties.
public enum SizePreference: String, Sendable, Hashable, Codable, CaseIterable {
    case smaller
    /// Closest to the tier's preferred MB/min (see ``QualityDefinition``).
    case nearPreferred
    case larger
}

/// A quality profile: which tiers are wanted, in what order, when to stop upgrading and how
/// custom-format scores count. Persistence stores the full group layout alongside legacy flat tiers.
public struct QualityProfileConfig: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Lowest to highest preference. Every tier should appear in exactly one group; disallowed groups
    /// stay listed so the ordering is complete.
    public var groups: [QualityGroup]
    public var upgradeAllowed: Bool
    /// Quality at which upgrading by quality stops. `nil` means the highest allowed group.
    public var cutoff: QualityTier?
    /// Releases scoring below this are rejected.
    public var minFormatScore: Int
    /// Once quality meets the cutoff, keep upgrading by score until the file reaches this score.
    public var upgradeUntilFormatScore: Int
    /// A score-driven upgrade must improve the score by at least this much.
    public var minFormatScoreIncrement: Int
    /// Custom format id (UUID string) -> score.
    public var formatScores: [String: Int]
    public var sizePreference: SizePreference
    /// Replaces the default size limits for specific tiers.
    public var definitionOverrides: [QualityDefinition]

    public init(
        id: UUID = UUID(), name: String, groups: [QualityGroup], upgradeAllowed: Bool = true,
        cutoff: QualityTier? = nil, minFormatScore: Int = 0, upgradeUntilFormatScore: Int = 0,
        minFormatScoreIncrement: Int = 1, formatScores: [String: Int] = [:],
        sizePreference: SizePreference = .nearPreferred, definitionOverrides: [QualityDefinition] = []
    ) {
        self.id = id
        self.name = name
        self.groups = groups
        self.upgradeAllowed = upgradeAllowed
        self.cutoff = cutoff
        self.minFormatScore = minFormatScore
        self.upgradeUntilFormatScore = upgradeUntilFormatScore
        self.minFormatScoreIncrement = minFormatScoreIncrement
        self.formatScores = formatScores
        self.sizePreference = sizePreference
        self.definitionOverrides = definitionOverrides
    }

    // MARK: Queries

    /// Index of the group containing `tier` (higher is better), or nil if the profile does not list it.
    public func groupIndex(of tier: QualityTier) -> Int? {
        groups.firstIndex { $0.tiers.contains(tier) }
    }

    public func isAllowed(_ tier: QualityTier) -> Bool {
        groupIndex(of: tier).map { groups[$0].allowed } ?? false
    }

    public var highestAllowedGroupIndex: Int? { groups.lastIndex { $0.allowed } }

    /// Group index of the cutoff (the highest allowed group when no cutoff is set).
    public var cutoffGroupIndex: Int {
        if let cutoff, let idx = groupIndex(of: cutoff) { return idx }
        return highestAllowedGroupIndex ?? 0
    }

    public func score(forFormat id: UUID) -> Int { formatScores[id.uuidString] ?? 0 }

    public func definition(for tier: QualityTier) -> QualityDefinition {
        definitionOverrides.first { $0.tier == tier } ?? QualityDefinition.defaultDefinition(for: tier)
    }

    // MARK: Persistence bridge

    public init(record: QualityProfile) {
        let groups = record.groups ?? record.items.compactMap { item -> QualityGroup? in
            QualityTier(rawValue: item.quality).map { QualityGroup(tiers: [$0], allowed: item.allowed) }
        }
        self.init(
            id: record.id, name: record.name, groups: groups, upgradeAllowed: record.upgradeAllowed,
            cutoff: record.cutoff.flatMap(QualityTier.init(rawValue:)), minFormatScore: record.minFormatScore,
            upgradeUntilFormatScore: record.cutoffFormatScore, formatScores: record.formatScores)
    }

    /// Persists the group layout and a flat compatibility representation.
    public func record(createdAt: Date = Date(), updatedAt: Date = Date()) -> QualityProfile {
        QualityProfile(
            id: id, name: name,
            items: groups.flatMap { g in g.tiers.map { QualityItem(quality: $0.rawValue, allowed: g.allowed) } },
            groups: groups,
            cutoff: cutoff?.rawValue, upgradeAllowed: upgradeAllowed, minFormatScore: minFormatScore,
            cutoffFormatScore: upgradeUntilFormatScore, formatScores: formatScores, createdAt: createdAt,
            updatedAt: updatedAt)
    }

    // MARK: Group layout helper

    /// The standard ordering of all tiers into equal-quality groups, with `allowed` tiers enabled.
    public static func standardGroups(allowing allowed: Set<QualityTier>) -> [QualityGroup] {
        let layout: [[QualityTier]] = [
            [.unknown], [.preRelease], [.sdtv], [.dvd], [.webRip480p, .webDL480p],
            [.hdtv720p], [.webRip720p, .webDL720p], [.bluray720p],
            [.hdtv1080p], [.webRip1080p, .webDL1080p], [.bluray1080p], [.remux1080p],
            [.hdtv2160p], [.webRip2160p, .webDL2160p], [.bluray2160p], [.remux2160p],
        ]
        return layout.map { tiers in
            QualityGroup(tiers: tiers, allowed: tiers.contains { allowed.contains($0) })
        }
    }
}
