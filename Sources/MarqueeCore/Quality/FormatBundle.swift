import Foundation

/// Importable/exportable bundle of custom formats and the profiles that score them, in the spirit of
/// community "TRaSH-style" guides but with this app's own schema:
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "name": "Example bundle",
///   "formats": [
///     { "name": "DV + HDR10", "specifications": [
///         { "name": "Dolby Vision", "type": "hdr", "value": "dolbyVision" },
///         { "name": "HDR10 fallback", "type": "hdr", "value": "hdr10", "required": true } ] } ],
///   "profiles": [
///     { "name": "UHD", "allowed": ["webDL2160p", "bluray2160p", "remux2160p"], "cutoff": "bluray2160p",
///       "upgradeAllowed": true, "minFormatScore": 0, "upgradeUntilFormatScore": 300,
///       "minFormatScoreIncrement": 1, "sizePreference": "larger",
///       "formatScores": { "DV + HDR10": 150 } } ]
/// }
/// ```
///
/// - `formats[].specifications[].type` is a ``SpecificationType`` raw value; `value` is a regex for
///   `releaseTitle`/`releaseGroup` and a name otherwise; `negate`/`required` default to false; `size`
///   uses `min`/`max` in GiB.
/// - `profiles[].allowed` lists ``QualityTier`` raw values; the standard group ordering is applied.
/// - `profiles[].formatScores` is keyed by format **name**; ids are generated on import, so bundles
///   never collide with existing formats.
public struct FormatBundle: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public struct Profile: Sendable, Hashable, Codable {
        public var name: String
        public var allowed: [QualityTier]
        public var cutoff: QualityTier?
        public var upgradeAllowed: Bool
        public var minFormatScore: Int
        public var upgradeUntilFormatScore: Int
        public var minFormatScoreIncrement: Int
        public var sizePreference: SizePreference
        public var formatScores: [String: Int]

        public init(
            name: String, allowed: [QualityTier], cutoff: QualityTier? = nil, upgradeAllowed: Bool = true,
            minFormatScore: Int = 0, upgradeUntilFormatScore: Int = 0, minFormatScoreIncrement: Int = 1,
            sizePreference: SizePreference = .nearPreferred, formatScores: [String: Int] = [:]
        ) {
            self.name = name
            self.allowed = allowed
            self.cutoff = cutoff
            self.upgradeAllowed = upgradeAllowed
            self.minFormatScore = minFormatScore
            self.upgradeUntilFormatScore = upgradeUntilFormatScore
            self.minFormatScoreIncrement = minFormatScoreIncrement
            self.sizePreference = sizePreference
            self.formatScores = formatScores
        }

        private enum CodingKeys: String, CodingKey {
            case name, allowed, cutoff, upgradeAllowed, minFormatScore, upgradeUntilFormatScore
            case minFormatScoreIncrement, sizePreference, formatScores
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try c.decode(String.self, forKey: .name),
                allowed: try c.decodeIfPresent([QualityTier].self, forKey: .allowed) ?? [],
                cutoff: try c.decodeIfPresent(QualityTier.self, forKey: .cutoff),
                upgradeAllowed: try c.decodeIfPresent(Bool.self, forKey: .upgradeAllowed) ?? true,
                minFormatScore: try c.decodeIfPresent(Int.self, forKey: .minFormatScore) ?? 0,
                upgradeUntilFormatScore: try c.decodeIfPresent(Int.self, forKey: .upgradeUntilFormatScore) ?? 0,
                minFormatScoreIncrement: try c.decodeIfPresent(Int.self, forKey: .minFormatScoreIncrement) ?? 1,
                sizePreference: try c.decodeIfPresent(SizePreference.self, forKey: .sizePreference) ?? .nearPreferred,
                formatScores: try c.decodeIfPresent([String: Int].self, forKey: .formatScores) ?? [:])
        }
    }

    public var schemaVersion: Int
    public var name: String
    public var formats: [CustomFormatConfig]
    public var profiles: [Profile]

    public init(name: String, formats: [CustomFormatConfig], profiles: [Profile], schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.formats = formats
        self.profiles = profiles
    }

    public struct Imported: Sendable {
        public var formats: [CustomFormatConfig]
        public var profiles: [QualityProfileConfig]
        /// Non-fatal problems: scores for unknown formats, formats with unmatchable specifications.
        public var warnings: [String]
    }

    public static func decode(_ data: Data) throws -> FormatBundle {
        try JSONDecoder().decode(FormatBundle.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Turns the bundle into app models with fresh ids.
    public func materialize() -> Imported {
        var warnings: [String] = []
        let formats = formats.map { CustomFormatConfig(id: UUID(), name: $0.name, specifications: $0.specifications) }
        for format in formats {
            if format.specifications.isEmpty { warnings.append("Format \"\(format.name)\" has no specifications and never matches") }
            warnings += format.validationIssues.map { "\(format.name): \($0)" }
        }
        let idByName = Dictionary(formats.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let profiles = profiles.map { p -> QualityProfileConfig in
            var scores: [String: Int] = [:]
            for (formatName, score) in p.formatScores {
                if let id = idByName[formatName] { scores[id.uuidString] = score }
                else { warnings.append("Profile \"\(p.name)\" scores unknown format \"\(formatName)\"") }
            }
            return QualityProfileConfig(
                name: p.name, groups: QualityProfileConfig.standardGroups(allowing: Set(p.allowed)),
                upgradeAllowed: p.upgradeAllowed, cutoff: p.cutoff, minFormatScore: p.minFormatScore,
                upgradeUntilFormatScore: p.upgradeUntilFormatScore,
                minFormatScoreIncrement: p.minFormatScoreIncrement, formatScores: scores,
                sizePreference: p.sizePreference)
        }
        return Imported(formats: formats, profiles: profiles, warnings: warnings)
    }

    /// Builds a bundle from app models; scores are re-keyed by format name.
    public static func export(name: String, formats: [CustomFormatConfig], profiles: [QualityProfileConfig]) -> FormatBundle {
        let nameByID = Dictionary(formats.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { first, _ in first })
        let exported = profiles.map { p in
            Profile(
                name: p.name, allowed: p.groups.filter(\.allowed).flatMap(\.tiers), cutoff: p.cutoff,
                upgradeAllowed: p.upgradeAllowed, minFormatScore: p.minFormatScore,
                upgradeUntilFormatScore: p.upgradeUntilFormatScore, minFormatScoreIncrement: p.minFormatScoreIncrement,
                sizePreference: p.sizePreference,
                formatScores: Dictionary(p.formatScores.compactMap { key, value in nameByID[key].map { ($0, value) } },
                                         uniquingKeysWith: { first, _ in first }))
        }
        return FormatBundle(name: name, formats: formats, profiles: exported)
    }
}
