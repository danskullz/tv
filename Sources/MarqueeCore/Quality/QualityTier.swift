import Foundation

/// A concrete quality level a release can have, ordered from worst to best.
///
/// Tiers are derived from a ``ParsedRelease`` (source + resolution) by ``QualityTier/derive(from:)``.
/// Profiles order and group tiers; two tiers in the same ``QualityGroup`` count as equal quality.
public enum QualityTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case unknown
    /// Cam, telesync, telecine, screener, workprint: never wanted by default.
    case preRelease
    case sdtv, dvd
    case webRip480p, webDL480p
    case hdtv720p, webRip720p, webDL720p, bluray720p
    case hdtv1080p, webRip1080p, webDL1080p, bluray1080p, remux1080p
    case hdtv2160p, webRip2160p, webDL2160p, bluray2160p, remux2160p

    /// Position in the global worst-to-best order (higher is better).
    public var rank: Int { Self.order[self] ?? 0 }
    private static let order: [QualityTier: Int] = Dictionary(
        uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })

    public static func < (lhs: QualityTier, rhs: QualityTier) -> Bool { lhs.rank < rhs.rank }

    /// Human-readable label, e.g. "1080p WEB-DL".
    public var displayName: String {
        switch self {
        case .unknown: "Unknown quality"
        case .preRelease: "Pre-release (CAM/TS)"
        case .sdtv: "SDTV"
        case .dvd: "DVD"
        case .webRip480p: "480p WEBRip"
        case .webDL480p: "480p WEB-DL"
        case .hdtv720p: "720p HDTV"
        case .webRip720p: "720p WEBRip"
        case .webDL720p: "720p WEB-DL"
        case .bluray720p: "720p Bluray"
        case .hdtv1080p: "1080p HDTV"
        case .webRip1080p: "1080p WEBRip"
        case .webDL1080p: "1080p WEB-DL"
        case .bluray1080p: "1080p Bluray"
        case .remux1080p: "1080p Remux"
        case .hdtv2160p: "2160p HDTV"
        case .webRip2160p: "2160p WEBRip"
        case .webDL2160p: "2160p WEB-DL"
        case .bluray2160p: "2160p Bluray"
        case .remux2160p: "2160p Remux"
        }
    }

    /// Vertical resolution implied by the tier (480 for SD tiers, 0 when unknown).
    public var resolution: Int {
        switch self {
        case .unknown, .preRelease: 0
        case .sdtv, .dvd, .webRip480p, .webDL480p: 480
        case .hdtv720p, .webRip720p, .webDL720p, .bluray720p: 720
        case .hdtv1080p, .webRip1080p, .webDL1080p, .bluray1080p, .remux1080p: 1080
        case .hdtv2160p, .webRip2160p, .webDL2160p, .bluray2160p, .remux2160p: 2160
        }
    }

    /// Derives the tier from a parsed release.
    ///
    /// Missing information is inferred conservatively: a release with a resolution but no source is
    /// treated as WEB-DL; Bluray/Remux without a resolution is assumed 1080p; sub-720p Bluray rips
    /// count as DVD; VHS counts as SDTV; legacy codecs (XviD/DivX/MPEG-2) without a resolution count as DVD.
    public static func derive(from parsed: ParsedRelease) -> QualityTier {
        let res = parsed.resolution?.rawValue
        func pick(_ r2160: QualityTier, _ r1080: QualityTier, _ r720: QualityTier, _ sd: QualityTier) -> QualityTier {
            guard let res else { return sd }
            return res >= 2160 ? r2160 : res >= 1080 ? r1080 : res >= 720 ? r720 : sd
        }
        guard let source = parsed.source else {
            guard let res else { return legacyCodec(parsed) ? .dvd : .unknown }
            return pick(.webDL2160p, .webDL1080p, .webDL720p, res >= 720 ? .webDL720p : .webDL480p)
        }
        switch source {
        case .cam, .telesync, .telecine, .screener, .workprint: return .preRelease
        case .vhs, .sdtv: return .sdtv
        case .dvd: return .dvd
        case .hdtv:
            if res == nil { return legacyCodec(parsed) ? .sdtv : .hdtv720p }
            return pick(.hdtv2160p, .hdtv1080p, .hdtv720p, .sdtv)
        case .webRip: return pick(.webRip2160p, .webRip1080p, .webRip720p, .webRip480p)
        case .webDL: return pick(.webDL2160p, .webDL1080p, .webDL720p, .webDL480p)
        case .bluRay:
            if let res, res < 720 { return .dvd }
            if res == nil { return .bluray1080p }
            return pick(.bluray2160p, .bluray1080p, .bluray720p, .dvd)
        case .remux:
            return (res ?? 1080) >= 2160 ? .remux2160p : .remux1080p
        }
    }

    private static func legacyCodec(_ parsed: ParsedRelease) -> Bool {
        switch parsed.videoCodec {
        case .xvid?, .divx?, .mpeg2?: true
        default: false
        }
    }
}

/// Size limits for a tier in megabytes per minute of runtime. `nil` max means unlimited.
public struct QualityDefinition: Sendable, Hashable, Codable {
    public var tier: QualityTier
    public var minMBPerMinute: Double
    /// Target the "closest to preferred" size preference aims for.
    public var preferredMBPerMinute: Double
    public var maxMBPerMinute: Double?

    public init(tier: QualityTier, min: Double, preferred: Double, max: Double?) {
        self.tier = tier
        self.minMBPerMinute = min
        self.preferredMBPerMinute = preferred
        self.maxMBPerMinute = max
    }

    /// Default limits for every tier, tuned for typical release sizes (45 min episodes, 2 h films).
    public static let defaults: [QualityDefinition] = [
        .init(tier: .unknown, min: 0, preferred: 50, max: nil),
        .init(tier: .preRelease, min: 0, preferred: 20, max: 200),
        .init(tier: .sdtv, min: 2, preferred: 15, max: 60),
        .init(tier: .dvd, min: 3, preferred: 25, max: 100),
        .init(tier: .webRip480p, min: 3, preferred: 15, max: 100),
        .init(tier: .webDL480p, min: 3, preferred: 15, max: 100),
        .init(tier: .hdtv720p, min: 4, preferred: 35, max: 150),
        .init(tier: .webRip720p, min: 4, preferred: 35, max: 150),
        .init(tier: .webDL720p, min: 4, preferred: 35, max: 150),
        .init(tier: .bluray720p, min: 8, preferred: 50, max: 250),
        .init(tier: .hdtv1080p, min: 8, preferred: 60, max: 250),
        .init(tier: .webRip1080p, min: 8, preferred: 60, max: 350),
        .init(tier: .webDL1080p, min: 8, preferred: 60, max: 350),
        .init(tier: .bluray1080p, min: 15, preferred: 100, max: 450),
        .init(tier: .remux1080p, min: 60, preferred: 250, max: nil),
        .init(tier: .hdtv2160p, min: 30, preferred: 150, max: 700),
        .init(tier: .webRip2160p, min: 30, preferred: 200, max: 800),
        .init(tier: .webDL2160p, min: 30, preferred: 200, max: 800),
        .init(tier: .bluray2160p, min: 60, preferred: 300, max: 1200),
        .init(tier: .remux2160p, min: 120, preferred: 500, max: nil),
    ]

    public static func defaultDefinition(for tier: QualityTier) -> QualityDefinition {
        defaults.first { $0.tier == tier } ?? defaults[0]
    }
}
