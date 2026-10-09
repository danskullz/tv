import Foundation

/// What the user (or the monitor) is looking for: a movie, one or more episodes, or a whole season.
public struct WantedItem: Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        case movie(year: Int?)
        /// One or more episodes. Provide whichever numbering the show uses; any available one may match.
        case episodes(season: Int?, numbers: [Int], absolute: [Int], airDate: AirDate?)
        case season(Int)
    }

    /// How a release relates to the wanted item.
    public enum Match: Sendable, Hashable {
        case exact
        /// The release covers the wanted item as part of a pack (season, multi-season, series, anime batch).
        case pack
        case mismatch(expected: String, found: String)
    }

    public var title: String
    public var aliases: [String]
    public var scope: Scope
    /// Runtime of the movie or of one episode, in minutes (for size limits and bitrate).
    public var runtimeMinutes: Double?
    /// Number of episodes in the wanted season, when known (sizes season packs).
    public var episodeCount: Int?

    private let normalizedTitles: Set<String>

    public init(
        title: String, aliases: [String] = [], scope: Scope, runtimeMinutes: Double? = nil, episodeCount: Int? = nil
    ) {
        self.title = title
        self.aliases = aliases
        self.scope = scope
        self.runtimeMinutes = runtimeMinutes
        self.episodeCount = episodeCount
        var names = Set(([title] + aliases).map(ReleaseParser.normalizeTitle))
        if case .movie(let year?) = scope { names.insert(ReleaseParser.normalizeTitle("\(title) \(year)")) }
        normalizedTitles = names
    }

    public static func movie(_ title: String, year: Int?, runtimeMinutes: Double?, aliases: [String] = []) -> WantedItem {
        WantedItem(title: title, aliases: aliases, scope: .movie(year: year), runtimeMinutes: runtimeMinutes)
    }

    public static func episode(
        _ series: String, season: Int?, episodes: [Int], absolute: [Int] = [], airDate: AirDate? = nil,
        runtimeMinutes: Double?, seasonEpisodeCount: Int? = nil, aliases: [String] = []
    ) -> WantedItem {
        WantedItem(
            title: series, aliases: aliases,
            scope: .episodes(season: season, numbers: episodes, absolute: absolute, airDate: airDate),
            runtimeMinutes: runtimeMinutes, episodeCount: seasonEpisodeCount)
    }

    public static func season(
        _ series: String, season: Int, episodeCount: Int?, runtimeMinutes: Double?, aliases: [String] = []
    ) -> WantedItem {
        WantedItem(title: series, aliases: aliases, scope: .season(season), runtimeMinutes: runtimeMinutes, episodeCount: episodeCount)
    }

    public var isMovie: Bool {
        if case .movie = scope { return true }
        return false
    }

    public var isSeason: Bool {
        if case .season = scope { return true }
        return false
    }

    public func matchesTitle(_ parsed: ParsedRelease) -> Bool {
        parsed.title == title || normalizedTitles.contains(parsed.normalizedTitle)
    }

    var expectedDescription: String {
        switch scope {
        case .movie(let year): return year.map { "\(title) (\($0))" } ?? title
        case .season(let n): return "\(title) season \(n)"
        case .episodes(let season, let numbers, let absolute, let airDate):
            if let airDate { return "\(title) \(airDate)" }
            if let season, !numbers.isEmpty { return "\(title) \(Self.code(season, numbers))" }
            if !absolute.isEmpty { return "\(title) episode \(absolute.map(String.init).joined(separator: ", "))" }
            return title
        }
    }

    static func code(_ season: Int, _ episodes: [Int]) -> String {
        let s = String(format: "S%02d", season)
        return s + episodes.map { String(format: "E%02d", $0) }.joined()
    }

    static func describe(_ p: ParsedRelease) -> String {
        switch p.kind {
        case .movie: return "a movie"
        case .episode: return p.seasons.first.map { code($0, p.episodes) } ?? "an episode"
        case .seasonPack: return "season \(p.seasons.map(String.init).joined(separator: ", "))"
        case .multiSeason: return "seasons \(p.seasons.map(String.init).joined(separator: ", "))"
        case .completeSeries: return "a complete series"
        case .daily: return p.airDate.map { "episode of \($0)" } ?? "a daily episode"
        case .animeAbsolute: return "anime episode \(p.absoluteEpisodes.map(String.init).joined(separator: "-"))"
        case .unknown: return "unidentified content"
        }
    }

    /// How `parsed` relates to this wanted item (title is checked separately).
    public func match(_ parsed: ParsedRelease) -> Match {
        var mismatch: Match { Match.mismatch(expected: expectedDescription, found: Self.describe(parsed)) }
        switch scope {
        case .movie:
            switch parsed.kind {
            case .movie, .unknown: return .exact
            default: return mismatch
            }
        case .season(let n):
            switch parsed.kind {
            case .seasonPack, .multiSeason: return parsed.seasons.contains(n) ? .pack : mismatch
            case .completeSeries: return .pack
            case .animeAbsolute: return parsed.isPack ? .pack : mismatch
            default: return mismatch
            }
        case .episodes(let season, let numbers, let absolute, let airDate):
            switch parsed.kind {
            case .episode:
                guard let season, !numbers.isEmpty else { return mismatch }
                return parsed.seasons.contains(season) && numbers.allSatisfy(parsed.episodes.contains) ? .exact : mismatch
            case .daily:
                guard let airDate, parsed.airDate == airDate else { return mismatch }
                return .exact
            case .animeAbsolute:
                if !absolute.isEmpty, absolute.allSatisfy(parsed.absoluteEpisodes.contains) {
                    return parsed.isPack ? .pack : .exact
                }
                return mismatch
            case .seasonPack, .multiSeason:
                guard let season, parsed.seasons.contains(season) else { return mismatch }
                return .pack
            case .completeSeries:
                return .pack
            default:
                return mismatch
            }
        }
    }

    /// Minutes of video the release should contain, or nil when it cannot be known (complete series,
    /// unknown season length or runtime).
    public func coveredRuntimeMinutes(for parsed: ParsedRelease) -> Double? {
        guard let runtimeMinutes, runtimeMinutes > 0 else { return nil }
        switch parsed.kind {
        case .movie, .unknown: return isMovie ? runtimeMinutes : nil
        case .episode: return runtimeMinutes * Double(max(1, parsed.episodes.count))
        case .daily: return runtimeMinutes
        case .animeAbsolute: return runtimeMinutes * Double(max(1, parsed.absoluteEpisodes.count))
        case .seasonPack, .multiSeason:
            guard let episodeCount else { return nil }
            return runtimeMinutes * Double(episodeCount * max(1, parsed.seasons.count))
        case .completeSeries: return nil
        }
    }
}

/// The file the library already has for the wanted item.
public struct CurrentFile: Sendable, Hashable, Codable {
    public var tier: QualityTier
    public var formatScore: Int
    public init(tier: QualityTier, formatScore: Int = 0) {
        self.tier = tier
        self.formatScore = formatScore
    }
}

/// Releases that must never be grabbed again (failed, wrong content, dead). Built from persisted
/// `BlocklistEntry` rows.
public struct ReleaseBlocklist: Sendable, Hashable {
    private var byHash: [String: String] = [:]
    private var byTitle: [String: String] = [:]

    public init() {}

    public init(entries: [BlocklistEntry]) {
        for entry in entries { add(infoHash: entry.infoHash, title: entry.releaseTitle, reason: entry.reason) }
    }

    public mutating func add(infoHash: String?, title: String?, reason: String) {
        if let infoHash { byHash[infoHash.lowercased()] = reason }
        if let title { byTitle[title.lowercased()] = reason }
    }

    /// The recorded reason when the release is blocklisted (matched by info hash, else exact title).
    public func reason(for release: IndexerRelease) -> String? {
        if isEmpty { return nil }
        if let hash = release.infoHash?.lowercased(), let reason = byHash[hash] { return reason }
        return byTitle[release.title.lowercased()]
    }

    public var isEmpty: Bool { byHash.isEmpty && byTitle.isEmpty }
}
