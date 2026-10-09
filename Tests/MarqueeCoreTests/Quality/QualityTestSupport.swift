import Foundation
@testable import MarqueeCore

/// Fixed "current time" for quality tests: 2026-10-09T12:00:00Z.
let qualityNow = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!

/// Stable id for a named test indexer ("A", "B", ...).
func qualityIndexerID(_ name: String) -> UUID {
    let hex = name.utf8.map { String(format: "%02x", $0) }.joined().prefix(12)
    let padded = String(repeating: "0", count: 12 - hex.count) + hex
    return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
}

func qualityMakeCandidate(
    _ title: String, seeders: Int? = 100, sizeGB: Double? = nil, ageHours: Double? = 24, indexer: String = "A",
    guid: String? = nil, hash: String? = nil, downloadVolumeFactor: Double? = nil, leechers: Int? = nil,
    now: Date = qualityNow
) -> ReleaseCandidate {
    let release = IndexerRelease(
        indexerID: qualityIndexerID(indexer), indexerName: indexer, title: title, guid: guid ?? title,
        downloadURL: URL(string: "https://indexer.invalid/dl/\(abs(title.hashValue))"), infoHash: hash,
        size: sizeGB.map { Int64($0 * 1_073_741_824) }, seeders: seeders, leechers: leechers,
        publishDate: ageHours.map { now.addingTimeInterval(-$0 * 3600) },
        downloadVolumeFactor: downloadVolumeFactor)
    return ReleaseCandidate(release: release)
}

/// Shorthand for a parsed-only candidate with explicit fields.
func qualityParsed(_ title: String) -> ParsedRelease { ReleaseParser.parse(title) }

func qualityFormat(_ name: String, _ specs: FormatSpecification...) -> CustomFormatConfig {
    CustomFormatConfig(name: name, specifications: specs)
}

func qualityProfile(
    allowing allowed: Set<QualityTier>, cutoff: QualityTier? = nil, upgradeAllowed: Bool = true,
    upgradeUntil: Int = 0, minScore: Int = 0, increment: Int = 1, scores: [(CustomFormatConfig, Int)] = [],
    sizePreference: SizePreference = .nearPreferred
) -> QualityProfileConfig {
    QualityProfileConfig(
        name: "Test", groups: QualityProfileConfig.standardGroups(allowing: allowed), upgradeAllowed: upgradeAllowed,
        cutoff: cutoff, minFormatScore: minScore, upgradeUntilFormatScore: upgradeUntil,
        minFormatScoreIncrement: increment,
        formatScores: Dictionary(uniqueKeysWithValues: scores.map { ($0.0.id.uuidString, $0.1) }),
        sizePreference: sizePreference)
}

func qualityFixtureData(_ name: String) -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Quality/\(name)")
    return try! Data(contentsOf: url)
}
