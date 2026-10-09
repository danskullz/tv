import Foundation
import Synchronization

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
    public func url(size: ImageSize = .w500, configuration: ImageConfiguration = .current) -> URL? {
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

    private static let override = Mutex<ImageConfiguration?>(nil)

    /// The configuration image URLs are built with: TMDB's CDN unless a launch mode (fixtures) redirects it.
    public static var current: ImageConfiguration { override.withLock { $0 } ?? .default }

    /// Redirects every `ImagePath.url(size:)` to another base URL (fixture artwork served from disk).
    public static func setOverride(baseURL: String?) {
        override.withLock { $0 = baseURL.map { var c = ImageConfiguration.default; c.baseURL = $0; return c } }
    }
}

// MARK: - Shared

public struct Page<Element: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public var page: Int
    public var totalPages: Int
    public var totalResults: Int
    public var results: [Element]

    public init(page: Int = 1, totalPages: Int = 1, totalResults: Int? = nil, results: [Element]) {
        self.page = page
        self.totalPages = totalPages
        self.totalResults = totalResults ?? results.count
        self.results = results
    }

    public var hasMore: Bool { page < totalPages }
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

    /// Opens the original trailer on YouTube or TMDB in the user's browser.
    public var externalURL: URL? {
        youtubeURL ?? URL(string: "https://www.themoviedb.org/video/\(id)")
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

    public init(id: Int, title: String, originalTitle: String? = nil, overview: String? = nil, posterPath: ImagePath? = nil, backdropPath: ImagePath? = nil, releaseDate: Date? = nil, voteAverage: Double? = nil, voteCount: Int? = nil, popularity: Double? = nil, genreIDs: [Int] = [], originalLanguage: String? = nil) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.overview = overview; self.posterPath = posterPath; self.backdropPath = backdropPath; self.releaseDate = releaseDate; self.voteAverage = voteAverage; self.voteCount = voteCount; self.popularity = popularity; self.genreIDs = genreIDs; self.originalLanguage = originalLanguage
    }
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

    public init(id: Int, name: String, originalName: String? = nil, overview: String? = nil, posterPath: ImagePath? = nil, backdropPath: ImagePath? = nil, firstAirDate: Date? = nil, voteAverage: Double? = nil, voteCount: Int? = nil, popularity: Double? = nil, genreIDs: [Int] = [], originCountry: [String] = [], originalLanguage: String? = nil) {
        self.id = id; self.name = name; self.originalName = originalName; self.overview = overview; self.posterPath = posterPath; self.backdropPath = backdropPath; self.firstAirDate = firstAirDate; self.voteAverage = voteAverage; self.voteCount = voteCount; self.popularity = popularity; self.genreIDs = genreIDs; self.originCountry = originCountry; self.originalLanguage = originalLanguage
    }
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

    public init(id: Int, seasonNumber: Int, episodeNumber: Int, name: String, overview: String? = nil, airDate: Date? = nil, runtime: Int? = nil, stillPath: ImagePath? = nil, voteAverage: Double? = nil) {
        self.id = id; self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber; self.name = name; self.overview = overview; self.airDate = airDate; self.runtime = runtime; self.stillPath = stillPath; self.voteAverage = voteAverage
    }
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

    public init(id: Int, name: String, profilePath: ImagePath? = nil, knownForDepartment: String? = nil) {
        self.id = id; self.name = name; self.profilePath = profilePath; self.knownForDepartment = knownForDepartment
    }
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

// MARK: - People, collections, providers

public struct PersonDetails: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var biography: String?
    public var birthday: Date?
    public var deathday: Date?
    public var placeOfBirth: String?
    public var profilePath: ImagePath?
    public var knownForDepartment: String?
    public var homepage: String?
    public var imdbID: String?

    public init(id: Int, name: String, biography: String? = nil, birthday: Date? = nil, deathday: Date? = nil,
                placeOfBirth: String? = nil, profilePath: ImagePath? = nil, knownForDepartment: String? = nil,
                homepage: String? = nil, imdbID: String? = nil) {
        self.id = id; self.name = name; self.biography = biography; self.birthday = birthday
        self.deathday = deathday; self.placeOfBirth = placeOfBirth; self.profilePath = profilePath
        self.knownForDepartment = knownForDepartment; self.homepage = homepage; self.imdbID = imdbID
    }
}

/// One line of a person's filmography (a cast or crew credit on a movie or show).
public struct PersonCredit: Sendable, Codable, Hashable, Identifiable {
    public enum Media: String, Sendable, Codable { case movie, tv }
    public var media: Media
    public var titleID: Int
    public var title: String
    /// Character played (cast credits).
    public var character: String?
    /// Job held (crew credits), e.g. "Director".
    public var job: String?
    public var department: String?
    public var date: Date?
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var episodeCount: Int?
    public var overview: String?

    public var id: String { "\(media.rawValue)-\(titleID)-\(job ?? character ?? "")" }
    public var isCrew: Bool { job != nil }

    public init(media: Media, titleID: Int, title: String, character: String? = nil, job: String? = nil,
                department: String? = nil, date: Date? = nil, posterPath: ImagePath? = nil,
                backdropPath: ImagePath? = nil, voteAverage: Double? = nil, voteCount: Int? = nil,
                popularity: Double? = nil, episodeCount: Int? = nil, overview: String? = nil) {
        self.media = media; self.titleID = titleID; self.title = title; self.character = character
        self.job = job; self.department = department; self.date = date; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.voteAverage = voteAverage; self.voteCount = voteCount
        self.popularity = popularity; self.episodeCount = episodeCount; self.overview = overview
    }
}

public struct PersonCredits: Sendable, Codable, Hashable {
    public var cast: [PersonCredit]
    public var crew: [PersonCredit]
    public static let empty = PersonCredits(cast: [], crew: [])

    public init(cast: [PersonCredit], crew: [PersonCredit]) {
        self.cast = cast
        self.crew = crew
    }
}

public struct CollectionDetails: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var posterPath: ImagePath?
    public var backdropPath: ImagePath?
    /// Films in the collection, release order.
    public var parts: [MovieSummary]

    public init(id: Int, name: String, overview: String? = nil, posterPath: ImagePath? = nil,
                backdropPath: ImagePath? = nil, parts: [MovieSummary] = []) {
        self.id = id; self.name = name; self.overview = overview; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.parts = parts
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
