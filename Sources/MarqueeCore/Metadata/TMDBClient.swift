import Foundation

/// Credentials for TMDB v3. The user supplies either kind in Settings.
public enum TMDBCredential: Sendable, Equatable {
    /// "API Read Access Token" (v4 auth, sent as a Bearer header; works on v3 endpoints).
    case readAccessToken(String)
    /// Classic v3 `api_key` query parameter.
    case apiKey(String)
}

/// TMDB v3 client with response caching, ETag revalidation and 429 backoff.
public actor TMDBClient {
    public let language: String
    public var cachePolicy: TMDBCachePolicy

    private let credential: TMDBCredential
    private let transport: MetadataTransport
    private let cache: MetadataCache
    private let baseURL: URL
    private let maxRetries: Int
    private let maxRetryWait: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let decoder = JSONDecoder.tmdb

    /// - Parameters:
    ///   - cacheDirectory: optional on-disk cache location (nil = memory only).
    ///   - maxRetries: how many times a 429 is retried before `MetadataError.rateLimited` is thrown.
    ///   - maxRetryWait: a `Retry-After` longer than this is not waited out.
    public init(
        credential: TMDBCredential,
        language: String = "en-US",
        transport: MetadataTransport = URLSessionMetadataTransport(),
        cacheDirectory: URL? = nil,
        memoryCacheCapacity: Int = 256,
        cachePolicy: TMDBCachePolicy = TMDBCachePolicy(),
        baseURL: URL = URL(string: "https://api.themoviedb.org/3")!,
        maxRetries: Int = 3,
        maxRetryWait: TimeInterval = 30,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credential = credential
        self.language = language
        self.transport = transport
        self.cache = MetadataCache(capacity: memoryCacheCapacity, directory: cacheDirectory)
        self.cachePolicy = cachePolicy
        self.baseURL = baseURL
        self.maxRetries = maxRetries
        self.maxRetryWait = maxRetryWait
        self.sleep = sleep
        self.now = now
    }

    public func clearCache() async { await cache.clear() }

    // MARK: Search

    /// Movies, shows and people matching `query`.
    public func search(_ query: String, page: Int = 1, includeAdult: Bool = false) async throws -> Page<SearchResult> {
        let dto: PageDTO<ResultDTO> = try await get("search/multi", [
            .init(name: "query", value: query), .init(name: "page", value: String(page)),
            .init(name: "include_adult", value: String(includeAdult)),
        ], ttl: cachePolicy.search)
        return dto.map { $0.mixed() }
    }

    public func searchMovies(_ query: String, year: Int? = nil, page: Int = 1) async throws -> Page<MovieSummary> {
        var q: [URLQueryItem] = [.init(name: "query", value: query), .init(name: "page", value: String(page))]
        if let year { q.append(.init(name: "year", value: String(year))) }
        let dto: PageDTO<ResultDTO> = try await get("search/movie", q, ttl: cachePolicy.search)
        return dto.map { $0.movie() }
    }

    public func searchSeries(_ query: String, firstAirDateYear: Int? = nil, page: Int = 1) async throws -> Page<SeriesSummary> {
        var q: [URLQueryItem] = [.init(name: "query", value: query), .init(name: "page", value: String(page))]
        if let firstAirDateYear { q.append(.init(name: "first_air_date_year", value: String(firstAirDateYear))) }
        let dto: PageDTO<ResultDTO> = try await get("search/tv", q, ttl: cachePolicy.search)
        return dto.map { $0.series() }
    }

    // MARK: Details

    public func movieDetails(id: Int) async throws -> MovieDetails {
        let dto: MovieDetailsDTO = try await get("movie/\(id)", [
            .init(name: "append_to_response", value: "external_ids,release_dates,credits,videos,watch/providers,recommendations"),
            .init(name: "include_video_language", value: videoLanguages),
        ], ttl: cachePolicy.details)
        guard let m = dto.model else { throw MetadataError.decoding("movie \(id) is missing its id or title") }
        return m
    }

    public func seriesDetails(id: Int) async throws -> SeriesDetails {
        let dto: SeriesDetailsDTO = try await get("tv/\(id)", [
            .init(name: "append_to_response", value: "external_ids,credits,videos,watch/providers,recommendations"),
            .init(name: "include_video_language", value: videoLanguages),
        ], ttl: cachePolicy.details)
        guard let s = dto.model else { throw MetadataError.decoding("series \(id) is missing its id or name") }
        return s
    }

    public func seasonDetails(seriesID: Int, season: Int) async throws -> SeasonDetails {
        let dto: SeasonDTO = try await get("tv/\(seriesID)/season/\(season)", [], ttl: cachePolicy.season)
        guard let s = dto.details else { throw MetadataError.decoding("season \(season) of series \(seriesID) is incomplete") }
        return s
    }

    // MARK: Trending & discover

    public func trending(_ media: TrendingMedia = .all, window: TrendingWindow = .week, page: Int = 1) async throws -> Page<SearchResult> {
        let dto: PageDTO<ResultDTO> = try await get("trending/\(media.rawValue)/\(window.rawValue)",
                                                    [.init(name: "page", value: String(page))], ttl: cachePolicy.trending)
        return dto.map { r in
            switch media {
            case .movie: return r.movie().map(SearchResult.movie)
            case .tv: return r.series().map(SearchResult.series)
            case .all: return r.mixed()
            }
        }
    }

    public func trendingMovies(window: TrendingWindow = .week, page: Int = 1) async throws -> Page<MovieSummary> {
        let dto: PageDTO<ResultDTO> = try await get("trending/movie/\(window.rawValue)",
                                                    [.init(name: "page", value: String(page))], ttl: cachePolicy.trending)
        return dto.map { $0.movie() }
    }

    public func trendingSeries(window: TrendingWindow = .week, page: Int = 1) async throws -> Page<SeriesSummary> {
        let dto: PageDTO<ResultDTO> = try await get("trending/tv/\(window.rawValue)",
                                                    [.init(name: "page", value: String(page))], ttl: cachePolicy.trending)
        return dto.map { $0.series() }
    }

    public func discoverMovies(_ filter: DiscoverFilter = DiscoverFilter()) async throws -> Page<MovieSummary> {
        let dto: PageDTO<ResultDTO> = try await get("discover/movie", discoverQuery(filter, tv: false), ttl: cachePolicy.discover)
        return dto.map { $0.movie() }
    }

    public func discoverSeries(_ filter: DiscoverFilter = DiscoverFilter()) async throws -> Page<SeriesSummary> {
        let dto: PageDTO<ResultDTO> = try await get("discover/tv", discoverQuery(filter, tv: true), ttl: cachePolicy.discover)
        return dto.map { $0.series() }
    }

    // MARK: Reference data

    public func configuration() async throws -> ImageConfiguration {
        let dto: ConfigurationDTO = try await get("configuration", [], ttl: cachePolicy.configuration, localized: false)
        return dto.model
    }

    public func movieGenres() async throws -> [Genre] {
        let dto: GenresDTO = try await get("genre/movie/list", [], ttl: cachePolicy.genres)
        return (dto.genres ?? []).compactMap(\.model)
    }

    public func seriesGenres() async throws -> [Genre] {
        let dto: GenresDTO = try await get("genre/tv/list", [], ttl: cachePolicy.genres)
        return (dto.genres ?? []).compactMap(\.model)
    }

    /// Looks up titles by IMDb (`tt…`) or TVDB id.
    public func find(externalID: String, source: ExternalSource) async throws -> FindResults {
        let dto: FindDTO = try await get("find/\(externalID)", [.init(name: "external_source", value: source.rawValue)],
                                         ttl: cachePolicy.find)
        return FindResults(movies: (dto.movieResults ?? []).compactMap { $0.movie() },
                           series: (dto.tvResults ?? []).compactMap { $0.series() })
    }

    // MARK: Plumbing

    private var videoLanguages: String {
        let primary = language.split(separator: "-").first.map(String.init) ?? "en"
        return primary == "en" ? "en,null" : "\(primary),en,null"
    }

    private func discoverQuery(_ f: DiscoverFilter, tv: Bool) -> [URLQueryItem] {
        var q: [URLQueryItem] = [.init(name: "page", value: String(f.page)), .init(name: "sort_by", value: f.sortBy.rawValue)]
        func ids(_ xs: [Int], sep: String = ",") -> String { xs.map(String.init).joined(separator: sep) }
        if !f.genres.isEmpty { q.append(.init(name: "with_genres", value: ids(f.genres, sep: f.matchAllGenres ? "," : "|"))) }
        if !f.excludedGenres.isEmpty { q.append(.init(name: "without_genres", value: ids(f.excludedGenres))) }
        if tv, !f.networks.isEmpty { q.append(.init(name: "with_networks", value: ids(f.networks, sep: "|"))) }
        if !f.companies.isEmpty { q.append(.init(name: "with_companies", value: ids(f.companies, sep: "|"))) }
        if !f.watchProviders.isEmpty {
            q.append(.init(name: "with_watch_providers", value: ids(f.watchProviders, sep: "|")))
            q.append(.init(name: "watch_region", value: f.watchRegion.uppercased()))
        }
        let after = tv ? "first_air_date.gte" : "primary_release_date.gte"
        let before = tv ? "first_air_date.lte" : "primary_release_date.lte"
        if let d = f.releasedAfter { q.append(.init(name: after, value: Self.day(d))) }
        if let d = f.releasedBefore { q.append(.init(name: before, value: Self.day(d))) }
        if let l = f.originalLanguage { q.append(.init(name: "with_original_language", value: l)) }
        if let v = f.minVoteAverage { q.append(.init(name: "vote_average.gte", value: String(v))) }
        if let v = f.minVoteCount { q.append(.init(name: "vote_count.gte", value: String(v))) }
        return q
    }

    private static func day(_ d: Date) -> String {
        d.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    private func get<D: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem], ttl: TimeInterval,
                                              localized: Bool = true) async throws -> D {
        var items = query
        if localized { items.append(.init(name: "language", value: language)) }
        let data = try await fetch(path: path, query: items, ttl: ttl)
        do {
            return try decoder.decode(D.self, from: data)
        } catch {
            throw MetadataError.decoding(String(describing: error))
        }
    }

    private func cacheKey(path: String, query: [URLQueryItem]) -> String {
        let q = query.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(path)?\(q)"
    }

    private func makeRequest(path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw MetadataError.invalidRequest(path)
        }
        var items = query
        if case .apiKey(let key) = credential { items.append(.init(name: "api_key", value: key)) }
        comps.queryItems = items.isEmpty ? nil : items
        guard let url = comps.url else { throw MetadataError.invalidRequest(path) }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .readAccessToken(let token) = credential {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func fetch(path: String, query: [URLQueryItem], ttl: TimeInterval) async throws -> Data {
        let key = cacheKey(path: path, query: query)
        let cached = await cache.entry(for: key)
        if let cached, cached.expiresAt > now() { return cached.body }

        var request = try makeRequest(path: path, query: query)
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        var attempt = 0
        while true {
            let response: MetadataHTTPResponse
            do {
                response = try await transport.send(request)
            } catch let error as URLError {
                if Self.isOffline(error) {
                    if let cached { return cached.body } // stale beats nothing
                    throw MetadataError.offline
                }
                throw MetadataError.unknown(error.localizedDescription)
            }

            switch response.status {
            case 200..<300:
                let cc = CacheControl.parse(response.headers["cache-control"])
                if !cc.noStore {
                    let lifetime = cc.noCache ? 0 : (cc.maxAge ?? ttl)
                    let t = now()
                    await cache.store(CachedResponse(key: key, body: response.body, etag: response.headers["etag"],
                                                     storedAt: t, expiresAt: t.addingTimeInterval(lifetime)))
                }
                return response.body
            case 304:
                guard var c = cached else { throw MetadataError.server(status: 304, message: nil) }
                let cc = CacheControl.parse(response.headers["cache-control"])
                let t = now()
                c.storedAt = t
                c.expiresAt = t.addingTimeInterval(cc.noCache ? 0 : (cc.maxAge ?? ttl))
                await cache.store(c)
                return c.body
            case 401, 403:
                throw MetadataError.invalidAPIKey
            case 404:
                throw MetadataError.notFound
            case 429:
                let wait = Self.retryAfter(response.headers["retry-after"]) ?? 2
                attempt += 1
                if attempt > maxRetries || wait > maxRetryWait { throw MetadataError.rateLimited(retryAfter: wait) }
                try await sleep(wait)
            default:
                throw MetadataError.server(status: response.status, message: Self.statusMessage(response.body))
            }
        }
    }

    private static func isOffline(_ e: URLError) -> Bool {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff:
            return true
        default: return false
        }
    }

    private static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let n = TimeInterval(header.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, n)
    }

    private static func statusMessage(_ body: Data) -> String? {
        struct Body: Decodable { var statusMessage: String? }
        return (try? JSONDecoder.tmdb.decode(Body.self, from: body))?.statusMessage
    }
}
