import Foundation

/// Custom formats shipped with the app and referenced by the preset profiles. Ids are fixed so presets
/// and stored profiles keep pointing at the same format across launches.
public enum BuiltInFormats {
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "6D617271-0000-4000-8000-%012d", n))!
    }

    public static let dolbyVision = CustomFormatConfig(
        id: id(1), name: "Dolby Vision", specifications: [.init(type: .hdr, value: "dolbyVision")])
    public static let hdr10Plus = CustomFormatConfig(
        id: id(2), name: "HDR10+", specifications: [.init(type: .hdr, value: "hdr10+")])
    public static let hdr10 = CustomFormatConfig(
        id: id(3), name: "HDR10",
        specifications: [.init(type: .hdr, value: "hdr10"), .init(type: .hdr, value: "hdr")])
    public static let atmos = CustomFormatConfig(
        id: id(4), name: "Atmos", specifications: [.init(type: .audioCodec, value: "atmos")])
    public static let losslessAudio = CustomFormatConfig(
        id: id(5), name: "Lossless audio",
        specifications: ["trueHD", "dtsHDMA", "dtsX", "flac", "pcm"].map { .init(type: .audioCodec, value: $0) })
    public static let hevc = CustomFormatConfig(
        id: id(6), name: "x265 (HEVC)", specifications: [.init(type: .videoCodec, value: "h265")])
    public static let properRepack = CustomFormatConfig(
        id: id(7), name: "Proper/Repack",
        specifications: [.init(type: .releaseFlag, value: "proper"), .init(type: .releaseFlag, value: "repack")])
    public static let freeleech = CustomFormatConfig(
        id: id(8), name: "Freeleech", specifications: [.init(type: .indexerFlag, value: "freeleech")])
    public static let hardcodedSubs = CustomFormatConfig(
        id: id(9), name: "Hardcoded subs", specifications: [.init(type: .releaseFlag, value: "hardcodedSubs")])
    public static let threeD = CustomFormatConfig(
        id: id(10), name: "3D", specifications: [.init(type: .releaseFlag, value: "threeD")])
    public static let lowQualityGroups = CustomFormatConfig(
        id: id(11), name: "Low-quality groups",
        specifications: [.init(type: .releaseGroup, value: "YIFY|YTS|aXXo|FGT|nSD|ION10|TeKno|KORSUB")])
    public static let dualAudio = CustomFormatConfig(
        id: id(12), name: "Dual audio",
        specifications: [
            .init(type: .releaseTitle, value: "\\bdual[ ._-]?audio\\b"), .init(type: .language, value: "multi"),
        ])
    public static let animeWebGroups = CustomFormatConfig(
        id: id(13), name: "Anime web groups",
        specifications: [.init(type: .releaseGroup, value: "SubsPlease|Erai-raws|ASW|Judas|EMBER|Tsundere-Raws")])
    public static let animeBDGroups = CustomFormatConfig(
        id: id(14), name: "Anime BD groups",
        specifications: [.init(type: .releaseGroup, value: "Beatrice-Raws|sam|Kametsu|Vodes|JySzE|CtrlHD")])

    public static let all: [CustomFormatConfig] = [
        dolbyVision, hdr10Plus, hdr10, atmos, losslessAudio, hevc, properRepack, freeleech, hardcodedSubs, threeD,
        lowQualityGroups, dualAudio, animeWebGroups, animeBDGroups,
    ]
}

extension QualityProfileConfig {
    private static func presetID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "6D617271-0001-4000-8000-%012d", n))!
    }

    private static func scores(_ pairs: [(CustomFormatConfig, Int)]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id.uuidString, $0.1) })
    }

    private static let unwanted: [(CustomFormatConfig, Int)] = [
        (BuiltInFormats.threeD, -10000), (BuiltInFormats.lowQualityGroups, -10000),
    ]

    /// 720p/1080p, HEVC and small sizes.
    public static let efficient = QualityProfileConfig(
        id: presetID(1), name: "Efficient",
        groups: standardGroups(allowing: [.hdtv720p, .webRip720p, .webDL720p, .hdtv1080p, .webRip1080p, .webDL1080p, .bluray1080p]),
        cutoff: .webDL1080p, upgradeUntilFormatScore: 60,
        formatScores: scores(unwanted + [
            (BuiltInFormats.hardcodedSubs, -10000), (BuiltInFormats.hevc, 60), (BuiltInFormats.properRepack, 5),
            (BuiltInFormats.freeleech, 5),
        ]),
        sizePreference: .smaller)

    /// 720p-1080p from web and disc sources; HDR and Atmos are nice to have.
    public static let balanced = QualityProfileConfig(
        id: presetID(2), name: "Balanced",
        groups: standardGroups(allowing: [
            .hdtv720p, .webRip720p, .webDL720p, .bluray720p, .hdtv1080p, .webRip1080p, .webDL1080p, .bluray1080p,
        ]),
        cutoff: .bluray1080p, upgradeUntilFormatScore: 50,
        formatScores: scores(unwanted + [
            (BuiltInFormats.hardcodedSubs, -10000), (BuiltInFormats.hdr10, 20), (BuiltInFormats.atmos, 20),
            (BuiltInFormats.losslessAudio, 10), (BuiltInFormats.properRepack, 5), (BuiltInFormats.freeleech, 5),
        ]),
        sizePreference: .nearPreferred)

    /// 2160p HDR with lossless audio; 1080p Bluray/WEB when no 4K exists.
    public static let best = QualityProfileConfig(
        id: presetID(3), name: "Best",
        groups: standardGroups(allowing: [
            .webDL1080p, .webRip1080p, .bluray1080p, .remux1080p, .webRip2160p, .webDL2160p, .bluray2160p, .remux2160p,
        ]),
        cutoff: .bluray2160p, upgradeUntilFormatScore: 300,
        formatScores: scores(unwanted + [
            (BuiltInFormats.hardcodedSubs, -10000), (BuiltInFormats.dolbyVision, 150), (BuiltInFormats.hdr10Plus, 120),
            (BuiltInFormats.hdr10, 100), (BuiltInFormats.atmos, 100), (BuiltInFormats.losslessAudio, 75),
            (BuiltInFormats.properRepack, 10), (BuiltInFormats.freeleech, 5),
        ]),
        sizePreference: .larger)

    /// Fansub and BD releases at 720p/1080p; dual audio and trusted groups preferred.
    public static let anime = QualityProfileConfig(
        id: presetID(4), name: "Anime",
        groups: standardGroups(allowing: [
            .hdtv720p, .webRip720p, .webDL720p, .bluray720p, .webRip1080p, .webDL1080p, .bluray1080p,
        ]),
        cutoff: .bluray1080p, upgradeUntilFormatScore: 150,
        formatScores: scores(unwanted + [
            (BuiltInFormats.animeBDGroups, 100), (BuiltInFormats.animeWebGroups, 75), (BuiltInFormats.dualAudio, 30),
            (BuiltInFormats.hevc, 15), (BuiltInFormats.hardcodedSubs, -50), (BuiltInFormats.properRepack, 10),
        ]),
        sizePreference: .nearPreferred)

    /// Untouched disc remuxes only.
    public static let remux = QualityProfileConfig(
        id: presetID(5), name: "Remux",
        groups: standardGroups(allowing: [.remux1080p, .remux2160p]),
        cutoff: .remux2160p, upgradeUntilFormatScore: 300,
        formatScores: scores(unwanted + [
            (BuiltInFormats.hardcodedSubs, -10000), (BuiltInFormats.dolbyVision, 150), (BuiltInFormats.hdr10Plus, 120),
            (BuiltInFormats.hdr10, 100), (BuiltInFormats.atmos, 100), (BuiltInFormats.losslessAudio, 75),
            (BuiltInFormats.properRepack, 10),
        ]),
        sizePreference: .larger)

    public static let presets: [QualityProfileConfig] = [.efficient, .balanced, .best, .anime, .remux]
}
