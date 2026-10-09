import Foundation
import MarqueeCore
import MarqueeUI

struct BrowseHit: Identifiable, Hashable, Sendable {
    enum Payload: Hashable, Sendable {
        case title(PosterItem)
        case person(PersonSummary)
    }

    let payload: Payload
    var id: String {
        switch payload {
        case .title(let item): item.id
        case .person(let person): "person:\(person.id)"
        }
    }
    var title: String {
        switch payload {
        case .title(let item): item.title
        case .person(let person): person.name
        }
    }
}

struct DiscoverSnapshot: Sendable {
    var featured: PosterItem?
    var trending: [PosterItem] = []
    var popularMovies: [PosterItem] = []
    var popularSeries: [PosterItem] = []
    var newReleases: [PosterItem] = []
    var upcoming: [PosterItem] = []
    var recommendations: [PosterItem] = []
    var genres: [Genre] = []
    var providers: [WatchProvider] = []
}

struct BrowseDetails: Sendable {
    var item: PosterItem
    var tagline: String?
    var overview: String
    var runtime: Int?
    var genres: [String]
    var score: Double?
    var imdbID: String?
    var certification: String?
    var cast: [CastMember]
    var crew: [CrewMember]
    var trailers: [Video]
    var providers: [WatchProvider]
    var collection: CollectionDetails?
    var recommendations: [PosterItem]
    var seasons: [SeasonDetails]
}

struct CalendarEvent: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case episode, movie }
    let id: String
    let titleID: String
    let title: String
    let subtitle: String
    let date: Date
    let kind: Kind
}

extension AppServices {
    func searchBrowse(_ query: String) async throws -> [BrowseHit] {
        guard let client = tmdb() else { throw MetadataError.invalidAPIKey }
        let page = try await client.search(query)
        let found = page.results.compactMap { result in
            switch result {
            case .movie(let movie): BrowseHit(payload: .title(Self.poster(movie)))
            case .series(let series): BrowseHit(payload: .title(Self.poster(series)))
            case .person(let person): BrowseHit(payload: .person(person))
            }
        }
        let existing = await catalogueLibraryIDs()
        return found.map { hit in
            guard case .title(var item) = hit.payload else { return hit }
            item.isInLibrary = existing.contains(item.id)
            return BrowseHit(payload: .title(item))
        }
    }

    func discoverSnapshot() async throws -> DiscoverSnapshot {
        guard let client = tmdb() else { throw MetadataError.invalidAPIKey }
        async let trending = client.trending(.all, window: .week)
        async let movies = client.popularMovies()
        async let series = client.popularSeries()
        async let genres = client.movieGenres()
        async let tvGenres = client.seriesGenres()
        async let providers = client.watchProviders(region: Self.regionCode)
        async let newMovies = client.discoverMovies(Self.dateFilter(after: -90, before: 0, sort: .releaseDateDesc))
        async let comingMovies = client.discoverMovies(Self.dateFilter(after: 1, before: 180, sort: .releaseDateAsc))
        let trendingPage = try await trending
        let moviePage = try await movies
        let seriesPage = try await series
        let recentPage = try await newMovies
        let upcomingPage = try await comingMovies
        var out = DiscoverSnapshot(
            featured: trendingPage.results.first.flatMap(Self.poster),
            trending: trendingPage.results.compactMap(Self.poster),
            popularMovies: moviePage.results.map(Self.poster),
            popularSeries: seriesPage.results.map(Self.poster),
            newReleases: recentPage.results.map(Self.poster), upcoming: upcomingPage.results.map(Self.poster),
            genres: (try? await genres) ?? [], providers: (try? await providers) ?? [])
        out.genres += (try? await tvGenres) ?? []
        var seen = Set<Int>()
        out.genres = out.genres.filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }

        let recentlyWatched = try? await watchStates.continueWatching(limit: 1)
        if let recent = recentlyWatched?.first,
           let title = try? await library.title(id: recent.titleId), let id = title.tmdbId {
            if title.kind == .movie, let details = try? await client.movieDetails(id: id) {
                out.recommendations = details.recommendations.map(Self.poster)
            } else if let details = try? await client.seriesDetails(id: id) {
                out.recommendations = details.recommendations.map(Self.poster)
            }
        }
        let existing = await catalogueLibraryIDs()
        out.trending = Self.mark(out.trending, existing: existing)
        out.popularMovies = Self.mark(out.popularMovies, existing: existing)
        out.popularSeries = Self.mark(out.popularSeries, existing: existing)
        out.newReleases = Self.mark(out.newReleases, existing: existing)
        out.upcoming = Self.mark(out.upcoming, existing: existing)
        out.recommendations = Self.mark(out.recommendations, existing: existing)
        return out
    }

    func discoverFiltered(genre: Int? = nil, provider: Int? = nil) async throws -> [PosterItem] {
        guard let client = tmdb() else { throw MetadataError.invalidAPIKey }
        var filter = DiscoverFilter()
        if let genre { filter.genres = [genre] }
        if let provider { filter.watchProviders = [provider]; filter.watchRegion = Self.regionCode }
        let movieFilter = filter
        let seriesFilter = filter
        async let movies = client.discoverMovies(movieFilter)
        async let series = client.discoverSeries(seriesFilter)
        let moviePage = try await movies
        let seriesPage = try await series
        let existing = await catalogueLibraryIDs()
        return Self.mark(moviePage.results.map(Self.poster) + seriesPage.results.map(Self.poster), existing: existing)
    }

    func browseDetails(id: String) async throws -> BrowseDetails? {
        guard let (kind, tmdbID) = Self.parseCatalogueID(id), let client = tmdb() else { return nil }
        if kind == .movie {
            let d = try await client.movieDetails(id: tmdbID)
            let providers = d.watchProviders.providers(in: Self.regionCode)
            let collection: CollectionDetails?
            if let ref = d.collection { collection = try? await client.collection(id: ref.id) }
            else { collection = nil }
            var item = Self.poster(d)
            item.isInLibrary = await catalogueLibraryIDs().contains(item.id)
            return BrowseDetails(
                item: item, tagline: d.tagline, overview: d.overview ?? "", runtime: d.runtime,
                genres: d.genres.map(\.name), score: d.voteAverage, imdbID: d.imdbID,
                certification: d.releaseDates(region: Self.regionCode).certification,
                cast: d.credits.cast, crew: d.credits.crew, trailers: d.trailers,
                providers: Self.unique(providers.map { $0.flatrate + $0.free + $0.ads + $0.rent + $0.buy } ?? []),
                collection: collection, recommendations: d.recommendations.map(Self.poster), seasons: [])
        }
        let d = try await client.seriesDetails(id: tmdbID)
        var seasons: [SeasonDetails] = []
        await withTaskGroup(of: SeasonDetails?.self) { group in
            for season in d.seasons where season.seasonNumber >= 0 {
                group.addTask { try? await client.seasonDetails(seriesID: tmdbID, season: season.seasonNumber) }
            }
            for await season in group { if let season { seasons.append(season) } }
        }
        seasons.sort { $0.seasonNumber < $1.seasonNumber }
        let providers = d.watchProviders.providers(in: Self.regionCode)
        var item = Self.poster(d)
        item.isInLibrary = await catalogueLibraryIDs().contains(item.id)
        return BrowseDetails(
            item: item, tagline: d.tagline, overview: d.overview ?? "", runtime: d.episodeRunTime.first,
            genres: d.genres.map(\.name), score: d.voteAverage, imdbID: d.imdbID, certification: nil,
            cast: d.credits.cast, crew: d.credits.crew, trailers: d.trailers,
            providers: Self.unique(providers.map { $0.flatrate + $0.free + $0.ads + $0.rent + $0.buy } ?? []),
            collection: nil, recommendations: d.recommendations.map(Self.poster), seasons: seasons)
    }

    func personDetails(id: Int) async throws -> (PersonDetails, PersonCredits) {
        guard let client = tmdb() else { throw MetadataError.invalidAPIKey }
        async let person = client.person(id: id)
        async let credits = client.personCredits(id: id)
        return try await (person, credits)
    }

    private func catalogueLibraryIDs() async -> Set<String> {
        guard let titles = try? await library.titles(matching: MarqueeCore.LibraryFilter()) else { return [] }
        return Set(titles.compactMap { title in
            title.tmdbId.map { "\(title.kind == .movie ? "movie" : "tv"):\($0)" }
        })
    }

    private static func mark(_ items: [PosterItem], existing: Set<String>) -> [PosterItem] {
        BrowseDataShaping.unique(items, limit: 200, id: \.id).map { item in
            var item = item
            item.isInLibrary = existing.contains(item.id)
            return item
        }
    }

    private static func unique(_ providers: [WatchProvider]) -> [WatchProvider] {
        var ids = Set<Int>()
        return providers.filter { ids.insert($0.id).inserted }
    }

    func want(_ item: PosterItem) async throws -> Title {
        guard let (kind, tmdbID) = Self.parseCatalogueID(item.id) else {
            throw MetadataError.invalidAPIKey
        }
        let result = CatalogueResult(
            kind: kind, tmdbID: tmdbID, title: item.title, year: item.year == 0 ? nil : item.year,
            overview: "", posterURL: nil, existing: nil)
        return try await addToLibrary(result, preset: AppSettings.defaultPreset)
    }

    func calendarEvents(from now: Date = Date(), days: Int = 120) async throws -> [CalendarEvent] {
        let monitored = try await library.titles(matching: MarqueeCore.LibraryFilter(monitored: true))
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: days, to: now) ?? now
        var events: [CalendarEvent] = []
        for title in monitored {
            let key = title.id.uuidString
            if title.kind == .series {
                for episode in try await library.episodes(titleId: title.id)
                where episode.monitored && episode.airDate.map({ $0 >= now && $0 <= end }) == true {
                    guard let date = episode.airDate else { continue }
                    events.append(CalendarEvent(
                        id: episode.id.uuidString, titleID: key, title: title.title,
                        subtitle: "S\(episode.seasonNumber) · E\(episode.episodeNumber) · \(episode.title ?? "New episode")",
                        date: date, kind: .episode))
                }
            } else if let tmdbID = title.tmdbId, let client = tmdb(),
                      let d = try? await client.movieDetails(id: tmdbID), let date = d.releaseDate, date >= now, date <= end {
                events.append(CalendarEvent(id: key, titleID: key, title: title.title, subtitle: "Movie release", date: date, kind: .movie))
            }
        }
        if usesTMDBFixtures && events.isEmpty {
            for offset in [1, 4, 9] {
                if let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) {
                    events.append(CalendarEvent(
                        id: "fixture-\(offset)", titleID: "tv:1396", title: "Fixture Series",
                        subtitle: "S2 · E\(offset) · A new chapter", date: date, kind: .episode))
                }
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    func recentGrabs(for id: String) async -> [Grab] {
        guard let uuid = UUID(uuidString: id) else { return [] }
        return (try? await grabs.grabs(titleId: uuid, limit: 12)) ?? []
    }

    static var regionCode: String { Locale.current.region?.identifier ?? "US" }

    static func parseCatalogueID(_ id: String) -> (TitleKind, Int)? {
        let pieces = id.split(separator: ":")
        guard pieces.count == 2, let number = Int(pieces[1]) else { return nil }
        switch pieces[0] {
        case "movie": return (.movie, number)
        case "tv": return (.series, number)
        default: return nil
        }
    }

    static func poster(_ result: SearchResult) -> PosterItem? {
        switch result {
        case .movie(let movie): poster(movie)
        case .series(let series): poster(series)
        case .person: nil
        }
    }

    static func poster(_ movie: MovieSummary) -> PosterItem {
        makePoster(id: "movie:\(movie.id)", kind: .movie, title: movie.title, date: movie.releaseDate,
                   genres: movie.genreIDs, poster: movie.posterPath, backdrop: movie.backdropPath)
    }

    static func poster(_ movie: MovieDetails) -> PosterItem {
        PosterItem(id: "movie:\(movie.id)", kind: .movie, title: movie.title,
                   subtitle: movie.releaseDate.map { year($0).description } ?? "", year: movie.releaseDate.map(year) ?? 0,
                   poster: art(movie.posterPath, title: movie.title, symbol: "film"),
                   backdrop: art(movie.backdropPath ?? movie.posterPath, title: movie.title, symbol: "film", wide: true),
                   availability: movie.releaseDate.map { $0 > Date() ? .unaired : .missing } ?? .missing,
                   genres: movie.genres.map(\.name))
    }

    static func poster(_ series: SeriesSummary) -> PosterItem {
        makePoster(id: "tv:\(series.id)", kind: .series, title: series.name, date: series.firstAirDate,
                   genres: series.genreIDs, poster: series.posterPath, backdrop: series.backdropPath)
    }

    static func poster(_ series: SeriesDetails) -> PosterItem {
        PosterItem(id: "tv:\(series.id)", kind: .series, title: series.name,
                   subtitle: series.firstAirDate.map { year($0).description } ?? "", year: series.firstAirDate.map(year) ?? 0,
                   poster: art(series.posterPath, title: series.name, symbol: "tv"),
                   backdrop: art(series.backdropPath ?? series.posterPath, title: series.name, symbol: "tv", wide: true),
                   availability: series.firstAirDate.map { $0 > Date() ? .unaired : .missing } ?? .missing,
                   genres: series.genres.map(\.name))
    }

    private static func makePoster(id: String, kind: MarqueeUI.MediaKind, title: String, date: Date?, genres: [Int],
                                   poster: ImagePath?, backdrop: ImagePath?) -> PosterItem {
        PosterItem(id: id, kind: kind, title: title, subtitle: date.map { year($0).description } ?? "",
                   year: date.map(year) ?? 0, poster: art(poster, title: title, symbol: kind == .movie ? "film" : "tv"),
                   backdrop: art(backdrop ?? poster, title: title, symbol: kind == .movie ? "film" : "tv", wide: true),
                   availability: date.map { $0 > Date() ? .unaired : .missing } ?? .missing)
    }

    private static func art(_ path: ImagePath?, title: String, symbol: String, wide: Bool = false) -> Artwork {
        let placeholder = PlaceholderArt(hue: RealLibrary.hue(title), symbol: wide ? "" : symbol)
        if let url = path?.url(size: wide ? .w1280 : .w342) { return .remote(url, placeholder: placeholder) }
        return .generated(placeholder)
    }

    private static func year(_ date: Date) -> Int { Calendar(identifier: .gregorian).component(.year, from: date) }

    static func poster(_ credit: PersonCredit) -> PosterItem {
        makePoster(id: "\(credit.media == .movie ? "movie" : "tv"):\(credit.titleID)",
                   kind: credit.media == .movie ? .movie : .series, title: credit.title, date: credit.date,
                   genres: [], poster: credit.posterPath, backdrop: credit.backdropPath)
    }

    private static func dateFilter(after: Int, before: Int, sort: DiscoverSort) -> DiscoverFilter {
        var filter = DiscoverFilter()
        let calendar = Calendar(identifier: .gregorian)
        filter.releasedAfter = calendar.date(byAdding: .day, value: after, to: Date())
        filter.releasedBefore = calendar.date(byAdding: .day, value: before, to: Date())
        filter.sortBy = sort
        return filter
    }
}
