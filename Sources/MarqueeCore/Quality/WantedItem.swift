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
            case .seasonPack, .multiSeason:
                if parsed.seasons.contains(n) { return .pack }
                // Specials ship inside complete/multi-season packs, which rarely
                // name season 0: a multi-season pack is the expected source for them.
                if n == 0, parsed.kind == .multiSeason { return .pack }
                return mismatch
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
            case .movie, .unknown:
                // Omake batches ("<Show> - Omake") parse movie-shaped: bonus shorts with
                // no season numbering. They belong to season 0 and to nothing else.
                if season == 0, parsed.isSpecial { return .pack }
                return mismatch
            case .seasonPack, .multiSeason:
                guard let season else { return mismatch }
                if parsed.seasons.contains(season) { return .pack }
                // Specials ship inside complete/multi-season packs, which rarely
                // name season 0: a multi-season pack is the expected source for them,
                // while a single-season pack almost certainly is not.
                if season == 0, parsed.kind == .multiSeason { return .pack }
                return mismatch
            case .completeSeries:
                return .pack
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
            // Per-season lengths are unknown, and seasons vary wildly (a 24-episode combined
            // season next to a 5-episode OVA). Scaling by the season count false-rejects honest
            // complete packs, so multi-season packs are sized like one season: still catches
            // grossly mislabeled junk, never blocks a real pack.
            guard let episodeCount else { return nil }
            return runtimeMinutes * Double(episodeCount)
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
    private struct Entry: Hashable, Sendable {
        var reason: String
        var episodeID: UUID?
    }

    private var byHash: [String: Entry] = [:]
    private var byTitle: [String: Entry] = [:]

    public init() {}

    public init(entries: [BlocklistEntry]) {
        for entry in entries {
            add(infoHash: entry.infoHash, title: entry.releaseTitle, reason: entry.reason, episodeID: entry.episodeId)
        }
    }

    public mutating func add(infoHash: String?, title: String?, reason: String, episodeID: UUID? = nil) {
        if let infoHash { byHash[infoHash.lowercased()] = Entry(reason: reason, episodeID: episodeID) }
        if let title { byTitle[title.lowercased()] = Entry(reason: reason, episodeID: episodeID) }
    }

    /// The recorded reason when the release is blocklisted (matched by info hash, else exact title).
    /// Entries recorded for one episode don't poison other episodes: a pack missing S00E02 can
    /// still serve S01E01. Global entries (no episode) always apply; a nil `episodeID` query
    /// applies everything, preserving previous behavior for movies and library-wide searches.
    public func reason(for release: IndexerRelease, episodeID: UUID? = nil) -> String? {
        if isEmpty { return nil }
        func applies(_ entry: Entry) -> Bool {
            guard let scoped = entry.episodeID else { return true }
            guard let episodeID else { return true }
            return scoped == episodeID
        }
        if let hash = release.infoHash?.lowercased(), let entry = byHash[hash], applies(entry) { return entry.reason }
        if let entry = byTitle[release.title.lowercased()], applies(entry) { return entry.reason }
        return nil
    }

    public var isEmpty: Bool { byHash.isEmpty && byTitle.isEmpty }
}
