import Foundation

// Wire-format types for TMDB v3. Everything is optional so missing/null fields never fail a decode;
// mapping to the domain models supplies defaults and drops entries that lack an identity.

enum TMDBDate {
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if s.count == 10 {
            return try? Date(s, strategy: Date.ISO8601FormatStyle().year().month().day())
        }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return d }
        return nil
    }
}

extension JSONDecoder {
    /// snake_case -> camelCase, digits kept inline (`iso_3166_1` -> `iso31661`).
    static var tmdb: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let last = keys.last!
            guard last.intValue == nil else { return last }
            let parts = last.stringValue.replacingOccurrences(of: "/", with: "_")
                .split(separator: "_", omittingEmptySubsequences: true)
            guard parts.count > 1 else { return last }
            let camel = parts.first!.lowercased() + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            return AnyKey(stringValue: camel)!
        }
        return d
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct PageDTO<T: Decodable & Sendable>: Decodable, Sendable {
    var page: Int?
    var totalPages: Int?
    var totalResults: Int?
    var results: [T]?

    func map<U: Sendable & Codable & Equatable>(_ f: (T) -> U?) -> Page<U> {
        let items = (results ?? []).compactMap(f)
        return Page(page: page ?? 1, totalPages: totalPages ?? 1, totalResults: totalResults ?? items.count, results: items)
    }
}

struct ResultDTO: Decodable, Sendable {
    var id: Int?
    var mediaType: String?
    var title: String?
    var originalTitle: String?
    var name: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var profilePath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var voteCount: Int?
    var popularity: Double?
    var genreIds: [Int]?
    var originCountry: [String]?
    var originalLanguage: String?
    var knownForDepartment: String?

    func movie() -> MovieSummary? {
        guard let id, let title else { return nil }
        return MovieSummary(
            id: id, title: title, originalTitle: originalTitle, overview: overview,
            posterPath: posterPath.map(ImagePath.init), backdropPath: backdropPath.map(ImagePath.init),
            releaseDate: TMDBDate.parse(releaseDate), voteAverage: voteAverage, voteCount: voteCount,
            popularity: popularity, genreIDs: genreIds ?? [], originalLanguage: originalLanguage)
    }

    func series() -> SeriesSummary? {
        guard let id, let name else { return nil }
        return SeriesSummary(
            id: id, name: name, originalName: originalName, overview: overview,
            posterPath: posterPath.map(ImagePath.init), backdropPath: backdropPath.map(ImagePath.init),
            firstAirDate: TMDBDate.parse(firstAirDate), voteAverage: voteAverage, voteCount: voteCount,
            popularity: popularity, genreIDs: genreIds ?? [], originCountry: originCountry ?? [],
            originalLanguage: originalLanguage)
    }

    func person() -> PersonSummary? {
        guard let id, let name else { return nil }
        return PersonSummary(id: id, name: name, profilePath: profilePath.map(ImagePath.init),
                             knownForDepartment: knownForDepartment)
    }

    /// For endpoints that mix media types (search/multi, trending/all).
    func mixed() -> SearchResult? {
        switch mediaType {
        case "movie": return movie().map(SearchResult.movie)
        case "tv": return series().map(SearchResult.series)
        case "person": return person().map(SearchResult.person)
        default: return nil
        }
    }
}

struct GenreDTO: Decodable, Sendable {
    var id: Int?
    var name: String?
    var model: Genre? { id.flatMap { id in name.map { Genre(id: id, name: $0) } } }
}

struct GenresDTO: Decodable, Sendable { var genres: [GenreDTO]? }

struct ConfigurationDTO: Decodable, Sendable {
    struct Images: Decodable, Sendable {
        var secureBaseUrl: String?
        var posterSizes: [String]?
        var backdropSizes: [String]?
        var profileSizes: [String]?
        var stillSizes: [String]?
        var logoSizes: [String]?
    }
    var images: Images?

    var model: ImageConfiguration {
        let d = ImageConfiguration.default
        guard let i = images else { return d }
        return ImageConfiguration(
            baseURL: i.secureBaseUrl ?? d.baseURL, posterSizes: i.posterSizes ?? d.posterSizes,
            backdropSizes: i.backdropSizes ?? d.backdropSizes, profileSizes: i.profileSizes ?? d.profileSizes,
            stillSizes: i.stillSizes ?? d.stillSizes, logoSizes: i.logoSizes ?? d.logoSizes)
    }
}

struct FindDTO: Decodable, Sendable {
    var movieResults: [ResultDTO]?
    var tvResults: [ResultDTO]?
}

struct ExternalIDsDTO: Decodable, Sendable {
    var id: Int?
    var imdbId: String?
    var tvdbId: Int?
    var model: ExternalIDs {
        ExternalIDs(imdbID: imdbId.flatMap { $0.isEmpty ? nil : $0 }, tvdbID: tvdbId, tmdbID: id)
    }
}

struct CreditsDTO: Decodable, Sendable {
    struct Cast: Decodable, Sendable {
        var id: Int?; var name: String?; var character: String?; var profilePath: String?; var order: Int?
    }
    struct Crew: Decodable, Sendable {
        var id: Int?; var name: String?; var job: String?; var department: String?; var profilePath: String?
    }
    var cast: [Cast]?
    var crew: [Crew]?

    var model: Credits {
        Credits(
            cast: (cast ?? []).compactMap { c in
                guard let id = c.id, let name = c.name else { return nil }
                return CastMember(id: id, name: name, character: c.character,
                                  profilePath: c.profilePath.map(ImagePath.init), order: c.order)
            },
            crew: (crew ?? []).compactMap { c in
                guard let id = c.id, let name = c.name else { return nil }
                return CrewMember(id: id, name: name, job: c.job, department: c.department,
                                  profilePath: c.profilePath.map(ImagePath.init))
            })
    }
}

struct VideosDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var id: String?; var key: String?; var name: String?; var site: String?
        var type: String?; var official: Bool?; var publishedAt: String?
    }
    var results: [Item]?

    var model: [Video] {
        (results ?? []).compactMap { v in
            guard let key = v.key, let site = v.site else { return nil }
            return Video(id: v.id ?? key, key: key, name: v.name ?? "", site: site, type: v.type ?? "",
                         official: v.official ?? false, publishedAt: TMDBDate.parse(v.publishedAt))
        }
    }
}

struct WatchProvidersDTO: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        var providerId: Int?; var providerName: String?; var logoPath: String?; var displayPriority: Int?
    }
    struct Region: Decodable, Sendable {
        var link: String?
        var flatrate: [Provider]?; var rent: [Provider]?; var buy: [Provider]?
        var ads: [Provider]?; var free: [Provider]?
    }
    var results: [String: Region]?

    var model: WatchProviders {
        func conv(_ ps: [Provider]?) -> [WatchProvider] {
            (ps ?? []).compactMap { p in
                guard let id = p.providerId, let name = p.providerName else { return nil }
                return WatchProvider(id: id, name: name, logoPath: p.logoPath.map(ImagePath.init),
                                     displayPriority: p.displayPriority)
            }
        }
        var out: [String: RegionProviders] = [:]
        for (code, r) in results ?? [:] {
            out[code.uppercased()] = RegionProviders(
                link: r.link.flatMap(URL.init(string:)), flatrate: conv(r.flatrate), rent: conv(r.rent),
                buy: conv(r.buy), ads: conv(r.ads), free: conv(r.free))
        }
        return WatchProviders(byRegion: out)
    }
}

struct ReleaseDatesDTO: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var type: Int?; var releaseDate: String?; var certification: String?
    }
    struct Region: Decodable, Sendable {
        var iso31661: String?
        var releaseDates: [Entry]?
    }
    var results: [Region]?

    /// TMDB types: 1 premiere, 2 theatrical (limited), 3 theatrical, 4 digital, 5 physical, 6 TV.
    var model: [String: ReleaseDates] {
        var out: [String: ReleaseDates] = [:]
        func earliest(_ a: Date?, _ b: Date) -> Date { a.map { min($0, b) } ?? b }
        for region in results ?? [] {
            guard let code = region.iso31661?.uppercased() else { continue }
            var r = ReleaseDates()
            for e in region.releaseDates ?? [] {
                if r.certification == nil, let c = e.certification, !c.isEmpty { r.certification = c }
                guard let type = e.type, let date = TMDBDate.parse(e.releaseDate) else { continue }
                switch type {
                case 1: r.premiere = earliest(r.premiere, date)
                case 2, 3: r.theatrical = earliest(r.theatrical, date)
                case 4: r.digital = earliest(r.digital, date)
                case 5: r.physical = earliest(r.physical, date)
                case 6: r.tv = earliest(r.tv, date)
                default: break
                }
            }
            out[code] = r
        }
        return out
    }
}

struct CompanyDTO: Decodable, Sendable {
    var id: Int?; var name: String?; var logoPath: String?; var originCountry: String?
}

struct EpisodeDTO: Decodable, Sendable {
    var id: Int?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var name: String?
    var overview: String?
    var airDate: String?
    var runtime: Int?
    var stillPath: String?
    var voteAverage: Double?

    var model: EpisodeInfo? {
        guard let id, let episodeNumber else { return nil }
        return EpisodeInfo(id: id, seasonNumber: seasonNumber ?? 0, episodeNumber: episodeNumber,
                           name: name ?? "Episode \(episodeNumber)", overview: overview,
                           airDate: TMDBDate.parse(airDate), runtime: runtime,
                           stillPath: stillPath.map(ImagePath.init), voteAverage: voteAverage)
    }
}

struct SeasonDTO: Decodable, Sendable {
    var id: Int?
    var seasonNumber: Int?
    var name: String?
    var overview: String?
    var posterPath: String?
    var airDate: String?
    var episodeCount: Int?
    var episodes: [EpisodeDTO]?

    var summary: SeasonSummary? {
        guard let id, let seasonNumber else { return nil }
        return SeasonSummary(id: id, seasonNumber: seasonNumber, name: name ?? "Season \(seasonNumber)",
                             overview: overview, posterPath: posterPath.map(ImagePath.init),
                             airDate: TMDBDate.parse(airDate), episodeCount: episodeCount)
    }

    var details: SeasonDetails? {
        guard let id, let seasonNumber else { return nil }
        return SeasonDetails(id: id, seasonNumber: seasonNumber, name: name ?? "Season \(seasonNumber)",
                             overview: overview, posterPath: posterPath.map(ImagePath.init),
                             airDate: TMDBDate.parse(airDate), episodes: (episodes ?? []).compactMap(\.model))
    }
}

struct MovieDetailsDTO: Decodable, Sendable {
    struct Collection: Decodable, Sendable {
        var id: Int?; var name: String?; var posterPath: String?; var backdropPath: String?
    }
    var id: Int?
    var title: String?
    var originalTitle: String?
    var tagline: String?
    var overview: String?
    var status: String?
    var runtime: Int?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var voteAverage: Double?
    var voteCount: Int?
    var popularity: Double?
    var originalLanguage: String?
    var homepage: String?
    var imdbId: String?
    var genres: [GenreDTO]?
    var productionCompanies: [CompanyDTO]?
    var belongsToCollection: Collection?
    var externalIds: ExternalIDsDTO?
    var credits: CreditsDTO?
    var videos: VideosDTO?
    var watchProviders: WatchProvidersDTO?
    var recommendations: PageDTO<ResultDTO>?
    var releaseDates: ReleaseDatesDTO?

    var model: MovieDetails? {
        guard let id, let title else { return nil }
        var ext = externalIds?.model ?? ExternalIDs(imdbID: nil, tvdbID: nil, tmdbID: id)
        if ext.imdbID == nil, let imdbId, !imdbId.isEmpty { ext.imdbID = imdbId }
        let collection = belongsToCollection.flatMap { c in
            c.id.flatMap { id in c.name.map { name in
                CollectionRef(id: id, name: name, posterPath: c.posterPath.map(ImagePath.init),
                              backdropPath: c.backdropPath.map(ImagePath.init)) } }
        }
        return MovieDetails(
            id: id, title: title, originalTitle: originalTitle, tagline: tagline.flatMap { $0.isEmpty ? nil : $0 },
            overview: overview, status: status, runtime: runtime.flatMap { $0 > 0 ? $0 : nil },
            posterPath: posterPath.map(ImagePath.init), backdropPath: backdropPath.map(ImagePath.init),
            releaseDate: TMDBDate.parse(releaseDate), voteAverage: voteAverage, voteCount: voteCount,
            popularity: popularity, originalLanguage: originalLanguage, homepage: homepage,
            genres: (genres ?? []).compactMap(\.model),
            productionCompanies: (productionCompanies ?? []).compactMap { c in
                c.id.flatMap { id in c.name.map { Company(id: id, name: $0, logoPath: c.logoPath.map(ImagePath.init), originCountry: c.originCountry) } }
            },
            collection: collection, externalIDs: ext, credits: credits?.model ?? .empty,
            videos: videos?.model ?? [], watchProviders: watchProviders?.model ?? .empty,
            recommendations: (recommendations?.results ?? []).compactMap { $0.movie() },
            releaseDatesByRegion: releaseDates?.model ?? [:])
    }
}

struct SeriesDetailsDTO: Decodable, Sendable {
    struct NetworkDTO: Decodable, Sendable {
        var id: Int?; var name: String?; var logoPath: String?; var originCountry: String?
    }
    struct Creator: Decodable, Sendable { var name: String? }
    var id: Int?
    var name: String?
    var originalName: String?
    var tagline: String?
    var overview: String?
    var status: String?
    var type: String?
    var posterPath: String?
    var backdropPath: String?
    var firstAirDate: String?
    var lastAirDate: String?
    var inProduction: Bool?
    var numberOfSeasons: Int?
    var numberOfEpisodes: Int?
    var episodeRunTime: [Int]?
    var voteAverage: Double?
    var voteCount: Int?
    var popularity: Double?
    var originalLanguage: String?
    var homepage: String?
    var genres: [GenreDTO]?
    var networks: [NetworkDTO]?
    var createdBy: [Creator]?
    var seasons: [SeasonDTO]?
    var nextEpisodeToAir: EpisodeDTO?
    var lastEpisodeToAir: EpisodeDTO?
    var externalIds: ExternalIDsDTO?
    var credits: CreditsDTO?
    var videos: VideosDTO?
    var watchProviders: WatchProvidersDTO?
    var recommendations: PageDTO<ResultDTO>?

    var model: SeriesDetails? {
        guard let id, let name else { return nil }
        return SeriesDetails(
            id: id, name: name, originalName: originalName, tagline: tagline.flatMap { $0.isEmpty ? nil : $0 },
            overview: overview, status: status, type: type,
            posterPath: posterPath.map(ImagePath.init), backdropPath: backdropPath.map(ImagePath.init),
            firstAirDate: TMDBDate.parse(firstAirDate), lastAirDate: TMDBDate.parse(lastAirDate),
            inProduction: inProduction, numberOfSeasons: numberOfSeasons, numberOfEpisodes: numberOfEpisodes,
            episodeRunTime: episodeRunTime ?? [], voteAverage: voteAverage, voteCount: voteCount,
            popularity: popularity, originalLanguage: originalLanguage, homepage: homepage,
            genres: (genres ?? []).compactMap(\.model),
            networks: (networks ?? []).compactMap { n in
                n.id.flatMap { id in n.name.map { Network(id: id, name: $0, logoPath: n.logoPath.map(ImagePath.init), originCountry: n.originCountry) } }
            },
            createdBy: (createdBy ?? []).compactMap(\.name),
            seasons: (seasons ?? []).compactMap(\.summary),
            nextEpisodeToAir: nextEpisodeToAir?.model, lastEpisodeToAir: lastEpisodeToAir?.model,
            externalIDs: externalIds?.model ?? ExternalIDs(imdbID: nil, tvdbID: nil, tmdbID: id),
            credits: credits?.model ?? .empty, videos: videos?.model ?? [],
            watchProviders: watchProviders?.model ?? .empty,
            recommendations: (recommendations?.results ?? []).compactMap { $0.series() })
    }
}
