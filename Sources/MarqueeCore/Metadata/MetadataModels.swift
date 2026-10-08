import Foundation

// MARK: - Images

/// A TMDB-relative image path such as `/abc.jpg`.
public struct ImagePath: Sendable, Hashable, Codable {
    public let path: String

    public init(_ path: String) { self.path = path }

    public init(from decoder: Decoder) throws {
        path = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(path)
    }

    /// Full URL for a chosen size, e.g. `.w500` or `.original`.
    public func url(size: ImageSize = .w500, configuration: ImageConfiguration = .default) -> URL? {
        var base = configuration.baseURL
        if !base.hasSuffix("/") { base += "/" }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + size.rawValue + p)
    }
}

public struct ImageSize: Sendable, Hashable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let w92: ImageSize = "w92"
    public static let w154: ImageSize = "w154"
    public static let w185: ImageSize = "w185"
    public static let w300: ImageSize = "w300"
    public static let w342: ImageSize = "w342"
    public static let w500: ImageSize = "w500"
    public static let w780: ImageSize = "w780"
    public static let w1280: ImageSize = "w1280"
    public static let original: ImageSize = "original"
}

/// Result of `/configuration`: where images live and which sizes exist.
public struct ImageConfiguration: Sendable, Codable, Equatable {
    public var baseURL: String
    public var posterSizes: [String]
    public var backdropSizes: [String]
    public var profileSizes: [String]
    public var stillSizes: [String]
    public var logoSizes: [String]

    public static let `default` = ImageConfiguration(
        baseURL: "https://image.tmdb.org/t/p/",
        posterSizes: ["w92", "w154", "w185", "w342", "w500", "w780", "original"],
        backdropSizes: ["w300", "w780", "w1280", "original"],
        profileSizes: ["w45", "w185", "h632", "original"],
        stillSizes: ["w92", "w185", "w300", "original"],
        logoSizes: ["w45", "w92", "w154", "w185", "w300", "w500", "original"]
    )
}

// MARK: - Shared

public struct Page<Element: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public var page: Int
    public var totalPages: Int
    public var totalResults: Int
    public var results: [Element]
}

public struct Genre: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
}

public struct ExternalIDs: Sendable, Codable, Hashable {
    public var imdbID: String?
    public var tvdbID: Int?
    public var tmdbID: Int?
}

public struct CastMember: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: ImagePath?
    public var order: Int?
}

public struct CrewMember: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var job: String?
    public var department: String?
    public var profilePath: ImagePath?
}

public struct Credits: Sendable, Codable, Hashable {
    public var cast: [CastMember]
    public var crew: [CrewMember]
    public static let empty = Credits(cast: [], crew: [])
}

public struct Video: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var key: String
    public var name: String
    public var site: String
    public var type: String
    public var official: Bool
    public var publishedAt: Date?

    public var isTrailer: Bool { type == "Trailer" }

    /// YouTube watch URL when hosted on YouTube.
    public var youtubeURL: URL? {
        site == "YouTube" ? URL(string: "https://www.youtube.com/watch?v=\(key)") : nil
    }
}

public struct WatchProvider: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var logoPath: ImagePath?
    public var displayPriority: Int?
}

public struct RegionProviders: Sendable, Codable, Hashable {
    public var link: URL?
    public var flatrate: [WatchProvider]
    public var rent: [WatchProvider]
    public var buy: [WatchProvider]
    public var ads: [WatchProvider]
    public var free: [WatchProvider]
}

/// Where a title can legally be watched, keyed by ISO 3166-1 region code.
public struct WatchProviders: Sendable, Codable, Hashable {
    public var byRegion: [String: RegionProviders]
    public static let empty = WatchProviders(byRegion: [:])
    public func providers(in region: String) -> RegionProviders? { byRegion[region.uppercased()] }
}

public struct Company: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var logoPath: ImagePath?
    public var originCountry: String?
}

public struct CollectionRef: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
}

// MARK: - Movies

/// Release dates for one region, mapped to the buckets Radarr-style availability needs.
public struct ReleaseDates: Sendable, Codable, Hashable {
    public var premiere: Date?
    /// Earliest limited or wide theatrical release.
    public var theatrical: Date?
    public var digital: Date?
    public var physical: Date?
    public var tv: Date?
    public var certification: String?

    public static let empty = ReleaseDates()
    public init(premiere: Date? = nil, theatrical: Date? = nil, digital: Date? = nil,
                physical: Date? = nil, tv: Date? = nil, certification: String? = nil) {
        self.premiere = premiere; self.theatrical = theatrical; self.digital = digital
        self.physical = physical; self.tv = tv; self.certification = certification
    }
}

public struct MovieSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
    public var releaseDate: Date?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var genreIDs: [Int]
    public var originalLanguage: String?
}

public struct MovieDetails: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var tagline: String?
    public var overview: String?
    public var status: String?
    public var runtime: Int?
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
    public var releaseDate: Date?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var originalLanguage: String?
    public var homepage: String?
    public var genres: [Genre]
    public var productionCompanies: [Company]
    public var collection: CollectionRef?
    public var externalIDs: ExternalIDs
    public var credits: Credits
    public var videos: [Video]
    public var watchProviders: WatchProviders
    public var recommendations: [MovieSummary]
    /// Release dates keyed by ISO 3166-1 region.
    public var releaseDatesByRegion: [String: ReleaseDates]

    public var imdbID: String? { externalIDs.imdbID }
    public var trailers: [Video] { videos.filter(\.isTrailer) }

    /// Earliest date per bucket across all regions.
    public var worldwideReleaseDates: ReleaseDates {
        var out = ReleaseDates()
        for r in releaseDatesByRegion.values {
            out.premiere = earliest(out.premiere, r.premiere)
            out.theatrical = earliest(out.theatrical, r.theatrical)
            out.digital = earliest(out.digital, r.digital)
            out.physical = earliest(out.physical, r.physical)
            out.tv = earliest(out.tv, r.tv)
        }
        return out
    }

    /// Release dates for a region; buckets missing there fall back to the earliest worldwide date.
    public func releaseDates(region: String = "US") -> ReleaseDates {
        let local = releaseDatesByRegion[region.uppercased()] ?? .empty
        let world = worldwideReleaseDates
        return ReleaseDates(
            premiere: local.premiere ?? world.premiere,
            theatrical: local.theatrical ?? world.theatrical,
            digital: local.digital ?? world.digital,
            physical: local.physical ?? world.physical,
            tv: local.tv ?? world.tv,
            certification: local.certification
        )
    }

    private func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return min(a, b)
        default: return a ?? b
        }
    }
}

// MARK: - TV

public struct SeriesSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var overview: String?
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
    public var firstAirDate: Date?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var genreIDs: [Int]
    public var originCountry: [String]
    public var originalLanguage: String?
}

public struct EpisodeInfo: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var name: String
    public var overview: String?
    public var airDate: Date?
    /// Minutes.
    public var runtime: Int?
    public var stillPath: ImagePath?
    public var voteAverage: Double?
}

public struct SeasonSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var seasonNumber: Int
    public var name: String
    public var overview: String?
    public var posterPath: ImagePath?
    public var airDate: Date?
    public var episodeCount: Int?
}

public struct SeasonDetails: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var seasonNumber: Int
    public var name: String
    public var overview: String?
    public var posterPath: ImagePath?
    public var airDate: Date?
    public var episodes: [EpisodeInfo]
}

public struct Network: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var logoPath: ImagePath?
    public var originCountry: String?
}

public struct SeriesDetails: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var tagline: String?
    public var overview: String?
    public var status: String?
    public var type: String?
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
    public var firstAirDate: Date?
    public var lastAirDate: Date?
    public var inProduction: Bool?
    public var numberOfSeasons: Int?
    public var numberOfEpisodes: Int?
    /// Typical episode runtimes in minutes.
    public var episodeRunTime: [Int]
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var originalLanguage: String?
    public var homepage: String?
    public var genres: [Genre]
    public var networks: [Network]
    public var createdBy: [String]
    public var seasons: [SeasonSummary]
    public var nextEpisodeToAir: EpisodeInfo?
    public var lastEpisodeToAir: EpisodeInfo?
    public var externalIDs: ExternalIDs
    public var credits: Credits
    public var videos: [Video]
    public var watchProviders: WatchProviders
    public var recommendations: [SeriesSummary]

    public var imdbID: String? { externalIDs.imdbID }
    public var tvdbID: Int? { externalIDs.tvdbID }
    public var trailers: [Video] { videos.filter(\.isTrailer) }
}

// MARK: - Mixed results

public struct PersonSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var profilePath: ImagePath?
    public var knownForDepartment: String?
}

/// An entry from search/multi or trending/all.
public enum SearchResult: Sendable, Codable, Hashable {
    case movie(MovieSummary)
    case series(SeriesSummary)
    case person(PersonSummary)

    public var id: Int {
        switch self {
        case .movie(let m): m.id
        case .series(let s): s.id
        case .person(let p): p.id
        }
    }
}

public struct FindResults: Sendable, Codable, Hashable {
    public var movies: [MovieSummary]
    public var series: [SeriesSummary]
}

// MARK: - Request options

public enum TrendingMedia: String, Sendable { case all, movie, tv }
public enum TrendingWindow: String, Sendable { case day, week }
public enum ExternalSource: String, Sendable { case imdb = "imdb_id", tvdb = "tvdb_id" }

public enum DiscoverSort: String, Sendable {
    case popularityDesc = "popularity.desc"
    case popularityAsc = "popularity.asc"
    case ratingDesc = "vote_average.desc"
    case releaseDateDesc = "primary_release_date.desc"
    case releaseDateAsc = "primary_release_date.asc"
    case firstAirDateDesc = "first_air_date.desc"
    case firstAirDateAsc = "first_air_date.asc"
    case revenueDesc = "revenue.desc"
}

/// Common discover filters. Irrelevant fields (e.g. `networks` for movies) are ignored.
public struct DiscoverFilter: Sendable, Equatable {
    public var genres: [Int] = []
    /// When true, titles must match all genres; otherwise any.
    public var matchAllGenres = true
    public var excludedGenres: [Int] = []
    /// TV only.
    public var networks: [Int] = []
    /// Production companies / studios.
    public var companies: [Int] = []
    public var watchProviders: [Int] = []
    /// Region used with `watchProviders` (ISO 3166-1).
    public var watchRegion: String = "US"
    public var sortBy: DiscoverSort = .popularityDesc
    public var releasedAfter: Date?
    public var releasedBefore: Date?
    public var originalLanguage: String?
    public var minVoteAverage: Double?
    public var minVoteCount: Int?
    public var page: Int = 1

    public init() {}
}
