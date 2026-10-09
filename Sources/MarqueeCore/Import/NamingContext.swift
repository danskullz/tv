import Foundation

/// Everything a naming template can draw on for one file.
public struct NamingContext: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case movie, episode }

    public var kind: Kind
    /// Movie or series title.
    public var title: String
    public var year: Int?
    public var seriesType: SeriesType
    public var season: Int?
    /// Episode numbers in the file (several for multi-episode files), ascending.
    public var episodes: [Int]
    public var absoluteEpisodes: [Int]
    public var airDate: AirDate?
    /// Titles of the episodes in the file, in order. Joined with " + " when there are several.
    public var episodeTitles: [String]
    /// Quality, group, editions, HDR, codecs and audio as parsed from the release and file names.
    public var parsed: ParsedRelease
    /// What the probe found in the file (wins over the names for resolution and codecs).
    public var media: MediaInfo?
    /// File name as downloaded, without a folder.
    public var originalFilename: String
    /// Lower-case extension without the dot.
    public var ext: String

    public init(
        kind: Kind, title: String, year: Int? = nil, seriesType: SeriesType = .standard, season: Int? = nil,
        episodes: [Int] = [], absoluteEpisodes: [Int] = [], airDate: AirDate? = nil, episodeTitles: [String] = [],
        parsed: ParsedRelease = ParsedRelease(), media: MediaInfo? = nil, originalFilename: String = "",
        ext: String = "mkv"
    ) {
        self.kind = kind
        self.title = title
        self.year = year
        self.seriesType = seriesType
        self.season = season
        self.episodes = episodes.sorted()
        self.absoluteEpisodes = absoluteEpisodes.sorted()
        self.airDate = airDate
        self.episodeTitles = episodeTitles
        self.parsed = parsed
        self.media = media
        self.originalFilename = originalFilename
        self.ext = ext.lowercased()
    }

    /// Release facts with the probe's findings filled in where the names said nothing.
    public var effectiveParsed: ParsedRelease {
        var p = parsed
        if p.resolution == nil, let media, let w = media.width, let h = media.height {
            p.resolution = Resolution.closest(width: w, height: h)
        }
        return p
    }

    /// Quality tier of the file.
    public var tier: QualityTier { QualityTier.derive(from: effectiveParsed) }
}

extension Resolution {
    /// Nearest standard resolution for a picture of `width` x `height`; wide letterboxed pictures
    /// (1920x800) still count as 1080p. `nil` for nothing resembling video.
    public static func closest(width: Int, height: Int) -> Resolution? {
        guard width > 0, height > 0 else { return nil }
        // Height a 16:9 frame of this width would have: letterboxing cuts height, not width.
        let effective = max(height, width * 9 / 16)
        switch effective {
        case 1800...: return .p2160
        case 900..<1800: return .p1080
        case 620..<900: return .p720
        case 530..<620: return .p576
        default: return .p480
        }
    }
}

extension QualityTier {
    /// Sonarr/Radarr-style label used in file names: `WEBDL-1080p`, `Bluray-2160p`, `Remux-1080p`.
    public var fileLabel: String {
        switch self {
        case .unknown: "Unknown"
        case .preRelease: "Pre-release"
        case .sdtv: "SDTV"
        case .dvd: "DVD"
        case .webRip480p: "WEBRip-480p"
        case .webDL480p: "WEBDL-480p"
        case .hdtv720p: "HDTV-720p"
        case .webRip720p: "WEBRip-720p"
        case .webDL720p: "WEBDL-720p"
        case .bluray720p: "Bluray-720p"
        case .hdtv1080p: "HDTV-1080p"
        case .webRip1080p: "WEBRip-1080p"
        case .webDL1080p: "WEBDL-1080p"
        case .bluray1080p: "Bluray-1080p"
        case .remux1080p: "Remux-1080p"
        case .hdtv2160p: "HDTV-2160p"
        case .webRip2160p: "WEBRip-2160p"
        case .webDL2160p: "WEBDL-2160p"
        case .bluray2160p: "Bluray-2160p"
        case .remux2160p: "Remux-2160p"
        }
    }

    /// Source part of ``fileLabel`` (`WEBDL`, `Bluray`...).
    public var sourceLabel: String {
        let label = fileLabel
        if let dash = label.firstIndex(of: "-") { return String(label[..<dash]) }
        return label
    }
}
