/// What a release name (or a file inside a torrent) appears to be.
public enum MediaKind: String, Sendable, Hashable, Codable, CaseIterable {
    case movie
    case episode          // one or more episodes of one season (S01E01, S01E01E02, 1x01...)
    case seasonPack       // one season, no episode (S01, Season 1)
    case multiSeason      // several seasons (S01-S03)
    case completeSeries   // "Complete Series" with no season information
    case daily            // date-based episode (2019-05-12)
    case animeAbsolute    // absolute episode numbering ("Title - 1071", batches "01-12")
    case unknown          // nothing identifying beyond a title
}

public enum Resolution: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case p480 = 480
    case p576 = 576
    case p720 = 720
    case p1080 = 1080
    case p2160 = 2160

    public static func < (lhs: Resolution, rhs: Resolution) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Source: String, Sendable, Hashable, Codable, CaseIterable {
    case webDL, webRip, bluRay, remux, hdtv, sdtv, dvd
    case cam, telesync, telecine, screener, workprint, vhs
}

public enum VideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264, h265, av1, vp9, xvid, divx, mpeg2, vc1
}

public enum HDRFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case hdr          // unspecified "HDR"
    case hdr10, hdr10Plus, dolbyVision, hlg, sdr
}

public enum AudioCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case aac, ac3, eac3, dts, dtsHD, dtsHDMA, dtsX, trueHD, atmos, flac, opus, mp3, pcm
}

public enum Language: String, Sendable, Hashable, Codable, CaseIterable {
    case multi
    case english, french, german, spanish, italian, portuguese, russian, japanese, korean
    case chinese, dutch, swedish, danish, norwegian, finnish, polish, czech, hungarian
    case turkish, arabic, hindi, thai, greek, hebrew, ukrainian, vietnamese
}

public enum Edition: String, Sendable, Hashable, Codable, CaseIterable {
    case extended, directorsCut, theatrical, unrated, uncut, imax, remastered, restored
    case specialEdition, ultimateEdition, finalCut, collectorsEdition, anniversaryEdition
    case criterion, redux, openMatte, despecialized, rogueCut

    public var displayName: String {
        switch self {
        case .extended: "Extended"
        case .directorsCut: "Director's Cut"
        case .theatrical: "Theatrical"
        case .unrated: "Unrated"
        case .uncut: "Uncut"
        case .imax: "IMAX"
        case .remastered: "Remastered"
        case .restored: "Restored"
        case .specialEdition: "Special Edition"
        case .ultimateEdition: "Ultimate Edition"
        case .finalCut: "Final Cut"
        case .collectorsEdition: "Collector's Edition"
        case .anniversaryEdition: "Anniversary Edition"
        case .criterion: "Criterion"
        case .redux: "Redux"
        case .openMatte: "Open Matte"
        case .despecialized: "Despecialized"
        case .rogueCut: "Rogue Cut"
        }
    }
}

public enum ReleaseFlag: String, Sendable, Hashable, Codable, CaseIterable {
    case sample
    case extra            // featurette, trailer, bonus, NCOP/NCED, "Extras" folder...
    case hardcodedSubs
    case subbed           // soft/unspecified subtitles advertised in the name
    case dubbed
    case threeD
    case proper
    case repack
    case real
    case internalRelease
    case batch
    case subtitleFile     // the file itself is a subtitle (.srt, .ass...)
    case archive          // .rar/.zip/.7z/.r00 ...
    case nonMedia         // .nfo/.txt/.jpg/.exe ...
}

/// A calendar date for daily/date-based episodes. No time zone semantics.
public struct AirDate: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (l: AirDate, r: AirDate) -> Bool {
        (l.year, l.month, l.day) < (r.year, r.month, r.day)
    }

    /// ISO-8601 style `YYYY-MM-DD`.
    public var description: String {
        func pad(_ v: Int, _ w: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }
}

/// Structured result of parsing a release name or a file path inside a torrent.
public struct ParsedRelease: Sendable, Hashable, Codable {
    /// The string that was parsed (file name or release name).
    public var input: String
    /// Cleaned title (separators turned into spaces, no year/season/quality).
    public var title: String
    /// Release year (movies, or year-disambiguated series).
    public var year: Int?
    public var kind: MediaKind

    /// Season numbers. A range such as S01-S03 is expanded to `[1, 2, 3]`. `[0]` means specials.
    public var seasons: [Int]
    /// Episode numbers within `seasons` (multi-episode ranges expanded).
    public var episodes: [Int]
    /// Absolute episode numbers (anime). Batch ranges are expanded.
    public var absoluteEpisodes: [Int]
    public var airDate: AirDate?
    /// Season 0 / OVA / "Special(s)".
    public var isSpecial: Bool

    public var resolution: Resolution?
    public var source: Source?
    public var videoCodec: VideoCodec?
    public var hdr: [HDRFormat]
    public var bitDepth: Int?
    public var audioCodecs: [AudioCodec]
    /// Channel layout of the first audio track mentioned, e.g. "5.1".
    public var audioChannels: String?
    public var languages: [Language]

    public var releaseGroup: String?
    /// 8-hex-digit CRC32 from anime names (upper-case).
    public var crc32: String?
    /// 1 normally; 2 for PROPER/REPACK/v2, 3 for v3/REPACK2.
    public var version: Int
    public var editions: [Edition]
    /// Streaming service tag, canonical upper-case (AMZN, NF, DSNP, ATVP, HMAX...).
    public var streamingService: String?
    /// Lower-case file extension when the input looked like a file ("mkv").
    public var container: String?
    /// Text between the episode marker and the first quality tag, when present.
    public var episodeTitle: String?
    public var flags: Set<ReleaseFlag>
    /// Tokens after the title that matched nothing (debugging aid).
    public var unparsedTokens: [String]

    public init(
        input: String = "",
        title: String = "",
        year: Int? = nil,
        kind: MediaKind = .unknown,
        seasons: [Int] = [],
        episodes: [Int] = [],
        absoluteEpisodes: [Int] = [],
        airDate: AirDate? = nil,
        isSpecial: Bool = false,
        resolution: Resolution? = nil,
        source: Source? = nil,
        videoCodec: VideoCodec? = nil,
        hdr: [HDRFormat] = [],
        bitDepth: Int? = nil,
        audioCodecs: [AudioCodec] = [],
        audioChannels: String? = nil,
        languages: [Language] = [],
        releaseGroup: String? = nil,
        crc32: String? = nil,
        version: Int = 1,
        editions: [Edition] = [],
        streamingService: String? = nil,
        container: String? = nil,
        episodeTitle: String? = nil,
        flags: Set<ReleaseFlag> = [],
        unparsedTokens: [String] = []
    ) {
        self.input = input
        self.title = title
        self.year = year
        self.kind = kind
        self.seasons = seasons
        self.episodes = episodes
        self.absoluteEpisodes = absoluteEpisodes
        self.airDate = airDate
        self.isSpecial = isSpecial
        self.resolution = resolution
        self.source = source
        self.videoCodec = videoCodec
        self.hdr = hdr
        self.bitDepth = bitDepth
        self.audioCodecs = audioCodecs
        self.audioChannels = audioChannels
        self.languages = languages
        self.releaseGroup = releaseGroup
        self.crc32 = crc32
        self.version = version
        self.editions = editions
        self.streamingService = streamingService
        self.container = container
        self.episodeTitle = episodeTitle
        self.flags = flags
        self.unparsedTokens = unparsedTokens
    }

    /// True for season packs, multi-season packs, complete series and anime batches.
    public var isPack: Bool {
        switch kind {
        case .seasonPack, .multiSeason, .completeSeries: true
        case .animeAbsolute: absoluteEpisodes.count > 1
        default: false
        }
    }

    public var isProperOrRepack: Bool { flags.contains(.proper) || flags.contains(.repack) || version > 1 }

    /// Lower-case, punctuation-free title suitable for matching against metadata.
    public var normalizedTitle: String { ReleaseParser.normalizeTitle(title) }
}
