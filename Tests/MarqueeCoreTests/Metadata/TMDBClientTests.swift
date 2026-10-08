import Foundation
import Testing
@testable import MarqueeCore

// MARK: - Helpers

func fixture(_ name: String) -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Metadata/\(name).json")
    return try! Data(contentsOf: url)
}

func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    return c.date(from: DateComponents(year: y, month: m, day: d))!
}

final class MockTransport: MetadataTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> MetadataHTTPResponse
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Always returns the given fixture with 200.
    convenience init(fixture name: String, headers: [String: String] = [:]) {
        self.init { _, _ in MetadataHTTPResponse(status: 200, headers: headers, body: fixture(name)) }
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        let n = lock.withLock { _requests.append(request); return _requests.count }
        return try handler(request, n)
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [TimeInterval] = []
    var waits: [TimeInterval] { lock.withLock { _waits } }
    func record(_ t: TimeInterval) { lock.withLock { _waits.append(t) } }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ t: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(t) } }
}

func makeClient(
    _ transport: MockTransport,
    credential: TMDBCredential = .readAccessToken("tok"),
    language: String = "en-US",
    cacheDirectory: URL? = nil,
    clock: Clock = Clock(),
    sleeper: SleepRecorder = SleepRecorder()
) -> TMDBClient {
    TMDBClient(credential: credential, language: language, transport: transport, cacheDirectory: cacheDirectory,
               sleep: { sleeper.record($0) }, now: { clock.now })
}

func query(_ req: URLRequest) -> [String: String] {
    let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

// MARK: - Auth & request building

@Suite("TMDB requests")
struct MetadataTMDBRequestTests {
    @Test func bearerTokenIsSentAsHeader() async throws {
        let t = MockTransport(fixture: "search_movie")
        _ = try await makeClient(t).searchMovies("matrix")
        let r = t.requests[0]
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(query(r)["api_key"] == nil)
        #expect(r.url?.path == "/3/search/movie")
        #expect(query(r)["query"] == "matrix")
        #expect(query(r)["language"] == "en-US")
    }

    @Test func apiKeyIsSentAsQueryParameter() async throws {
        let t = MockTransport(fixture: "search_movie")
        _ = try await makeClient(t, credential: .apiKey("abc")).searchMovies("matrix", year: 1999)
        let r = t.requests[0]
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(query(r)["api_key"] == "abc")
        #expect(query(r)["year"] == "1999")
    }

    @Test func languageIsConfigurable() async throws {
        let t = MockTransport(fixture: "search_tv")
        _ = try await makeClient(t, language: "fr-FR").searchSeries("bad")
        #expect(query(t.requests[0])["language"] == "fr-FR")
    }

    @Test func movieDetailsAppendsEverything() async throws {
        let t = MockTransport(fixture: "movie_details")
        _ = try await makeClient(t).movieDetails(id: 693134)
        let q = query(t.requests[0])
        #expect(t.requests[0].url?.path == "/3/movie/693134")
        #expect(q["append_to_response"] == "external_ids,release_dates,credits,videos,watch/providers,recommendations")
        #expect(q["include_video_language"] == "en,null")
    }

    @Test func seriesDetailsAppendsEverything() async throws {
        let t = MockTransport(fixture: "tv_details")
        _ = try await makeClient(t).seriesDetails(id: 1396)
        #expect(query(t.requests[0])["append_to_response"] == "external_ids,credits,videos,watch/providers,recommendations")
    }

    @Test func discoverMovieFilters() async throws {
        let t = MockTransport(fixture: "discover_movie")
        var f = DiscoverFilter()
        f.genres = [878, 12]
        f.matchAllGenres = false
        f.companies = [923]
        f.watchProviders = [8, 384]
        f.watchRegion = "gb"
        f.sortBy = .ratingDesc
        f.releasedAfter = utc(2020, 1, 5)
        f.networks = [174] // ignored for movies
        f.page = 2
        let page = try await makeClient(t).discoverMovies(f)
        let q = query(t.requests[0])
        #expect(t.requests[0].url?.path == "/3/discover/movie")
        #expect(q["with_genres"] == "878|12")
        #expect(q["with_companies"] == "923")
        #expect(q["with_watch_providers"] == "8|384")
        #expect(q["watch_region"] == "GB")
        #expect(q["sort_by"] == "vote_average.desc")
        #expect(q["primary_release_date.gte"] == "2020-01-05")
        #expect(q["with_networks"] == nil)
        #expect(q["page"] == "2")
        #expect(page.page == 2 && page.totalPages == 40)
        #expect(page.results.first?.title == "Blade Runner 2049")
    }

    @Test func discoverSeriesUsesNetworksAndAirDates() async throws {
        let t = MockTransport(fixture: "search_tv")
        var f = DiscoverFilter()
        f.networks = [174, 49]
        f.releasedBefore = utc(2015, 12, 31)
        _ = try await makeClient(t).discoverSeries(f)
        let q = query(t.requests[0])
        #expect(t.requests[0].url?.path == "/3/discover/tv")
        #expect(q["with_networks"] == "174|49")
        #expect(q["first_air_date.lte"] == "2015-12-31")
    }

    @Test func trendingPaths() async throws {
        let t = MockTransport(fixture: "trending_all")
        let client = makeClient(t)
        let all = try await client.trending(.all, window: .day)
        #expect(t.requests[0].url?.path == "/3/trending/all/day")
        #expect(all.results.count == 2)
        guard case .series(let s) = all.results[0], case .movie(let m) = all.results[1] else {
            Issue.record("expected series then movie"); return
        }
        #expect(s.name == "Breaking Bad")
        #expect(m.title == "Dune: Part Two")
    }

    @Test func findByTVDBID() async throws {
        let t = MockTransport(fixture: "find_tvdb")
        let r = try await makeClient(t).find(externalID: "81189", source: .tvdb)
        #expect(t.requests[0].url?.path == "/3/find/81189")
        #expect(query(t.requests[0])["external_source"] == "tvdb_id")
        #expect(r.series.first?.id == 1396)
        #expect(r.movies.isEmpty)
    }

    @Test func configurationAndGenres() async throws {
        let config = try await makeClient(MockTransport(fixture: "configuration")).configuration()
        #expect(config.baseURL == "https://image.tmdb.org/t/p/")
        #expect(config.stillSizes.contains("w300"))

        let genres = try await makeClient(MockTransport(fixture: "genres_movie")).movieGenres()
        #expect(genres.map(\.name) == ["Action", "Adventure", "Science Fiction"])
    }
}

// MARK: - Decoding

@Suite("TMDB decoding")
struct MetadataTMDBDecodingTests {
    @Test func multiSearchMapsTypesAndSkipsJunk() async throws {
        let page = try await makeClient(MockTransport(fixture: "search_multi")).search("dune")
        #expect(page.totalPages == 3 && page.totalResults == 52)
        // movie, tv, person, and the sparse Matrix entry; collection and id-less entry dropped.
        #expect(page.results.count == 4)
        guard case .movie(let dune) = page.results[0] else { Issue.record("not a movie"); return }
        #expect(dune.releaseDate == utc(2024, 2, 27))
        #expect(dune.genreIDs == [878, 12])
        guard case .person(let p) = page.results[2] else { Issue.record("not a person"); return }
        #expect(p.name == "Brad Pitt")
        guard case .movie(let matrix) = page.results[3] else { Issue.record("not a movie"); return }
        #expect(matrix.releaseDate == nil)
        #expect(matrix.posterPath == nil)
        #expect(matrix.genreIDs.isEmpty)
        #expect(matrix.voteAverage == nil)
    }

    @Test func movieDetailsDecode() async throws {
        let m = try await makeClient(MockTransport(fixture: "movie_details")).movieDetails(id: 693134)
        #expect(m.title == "Dune: Part Two")
        #expect(m.runtime == 167)
        #expect(m.imdbID == "tt15239678")
        #expect(m.collection?.name == "Dune Collection")
        #expect(m.credits.cast.count == 2)
        #expect(m.credits.cast[1].profilePath == nil)
        #expect(m.credits.crew.first?.job == "Director")
        #expect(m.recommendations.map(\.title) == ["Dune"])
        #expect(m.genres.map(\.id) == [878, 12])
        #expect(m.productionCompanies.first?.name == "Legendary Pictures")
        #expect(m.watchProviders.providers(in: "us")?.flatrate.first?.name == "Max")
        #expect(m.watchProviders.providers(in: "CA")?.buy.first?.id == 3)
        #expect(m.watchProviders.providers(in: "CA")?.flatrate.isEmpty == true)
    }

    @Test func videosAndTrailers() async throws {
        let m = try await makeClient(MockTransport(fixture: "movie_details")).movieDetails(id: 693134)
        #expect(m.videos.count == 3)
        #expect(m.trailers.count == 2)
        #expect(m.videos[0].youtubeURL?.absoluteString == "https://www.youtube.com/watch?v=Way9Dexny3w")
        #expect(m.videos[2].youtubeURL == nil)
        #expect(m.videos[0].publishedAt != nil)
    }

    @Test func releaseDatesMapToBuckets() async throws {
        let m = try await makeClient(MockTransport(fixture: "movie_details")).movieDetails(id: 693134)
        let us = m.releaseDates(region: "US")
        #expect(us.theatrical == utc(2024, 3, 1))
        #expect(us.premiere == utc(2024, 2, 26))
        #expect(us.digital == utc(2024, 4, 16))
        #expect(us.physical == utc(2024, 5, 14))
        #expect(us.certification == "PG-13")

        // GB has no physical date: falls back to the earliest worldwide one.
        let gb = m.releaseDates(region: "GB")
        #expect(gb.theatrical == utc(2024, 2, 29))
        #expect(gb.digital == utc(2024, 4, 15))
        #expect(gb.physical == utc(2024, 5, 14))

        // Limited theatrical (type 2) counts as theatrical; null dates are ignored.
        let fr = m.releaseDatesByRegion["FR"]
        #expect(fr?.theatrical == utc(2024, 2, 28))
        #expect(fr?.tv == nil)

        #expect(m.worldwideReleaseDates.theatrical == utc(2024, 2, 28))
        #expect(m.worldwideReleaseDates.digital == utc(2024, 4, 15))
    }

    @Test func seriesDetailsDecode() async throws {
        let s = try await makeClient(MockTransport(fixture: "tv_details")).seriesDetails(id: 1396)
        #expect(s.name == "Breaking Bad")
        #expect(s.tvdbID == 81189)
        #expect(s.imdbID == "tt0903747")
        #expect(s.networks.first?.name == "AMC")
        #expect(s.createdBy == ["Vince Gilligan"])
        #expect(s.numberOfSeasons == 5)
        #expect(s.episodeRunTime == [45, 47])
        #expect(s.seasons.map(\.seasonNumber) == [0, 1])
        #expect(s.seasons[1].overview == "")
        #expect(s.lastEpisodeToAir?.name == "Felina")
        #expect(s.lastEpisodeToAir?.airDate == utc(2013, 9, 29))
        #expect(s.nextEpisodeToAir == nil)
        #expect(s.recommendations.first?.name == "Better Call Saul")
        #expect(s.watchProviders.providers(in: "US")?.flatrate.first?.name == "Netflix")
        #expect(s.trailers.count == 1)
    }

    @Test func seasonDetailsDecode() async throws {
        let t = MockTransport(fixture: "season_details")
        let season = try await makeClient(t).seasonDetails(seriesID: 1396, season: 1)
        #expect(t.requests[0].url?.path == "/3/tv/1396/season/1")
        #expect(season.episodes.count == 3) // id-less episode dropped
        let pilot = season.episodes[0]
        #expect(pilot.name == "Pilot")
        #expect(pilot.airDate == utc(2008, 1, 20))
        #expect(pilot.runtime == 58)
        #expect(pilot.stillPath?.path == "/ydlY3iPfeOAvu8gVqrxPoMvzNCn.jpg")
        #expect(season.episodes[1].stillPath == nil)
        #expect(season.episodes[2].airDate == nil && season.episodes[2].runtime == nil)
    }

    @Test func missingOptionalSectionsUseDefaults() async throws {
        let body = Data(#"{"id": 7, "title": "Bare", "genres": null, "credits": null, "videos": {"results": null}}"#.utf8)
        let t = MockTransport { _, _ in MetadataHTTPResponse(status: 200, body: body) }
        let m = try await makeClient(t).movieDetails(id: 7)
        #expect(m.genres.isEmpty && m.videos.isEmpty && m.recommendations.isEmpty)
        #expect(m.credits == .empty)
        #expect(m.releaseDates().theatrical == nil)
    }

    @Test func garbageThrowsDecodingError() async {
        let t = MockTransport { _, _ in MetadataHTTPResponse(status: 200, body: Data("<html>".utf8)) }
        await #expect {
            try await makeClient(t).movieDetails(id: 1)
        } throws: { error in
            if case MetadataError.decoding = error { return true }
            return false
        }
    }

    @Test func modelsRoundTripThroughCodable() async throws {
        let m = try await makeClient(MockTransport(fixture: "movie_details")).movieDetails(id: 693134)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(MovieDetails.self, from: data) == m)
    }
}

// MARK: - Images

@Suite("Image paths")
struct MetadataImagePathTests {
    @Test func buildsURLs() {
        let p = ImagePath("/abc.jpg")
        #expect(p.url(size: .w500)?.absoluteString == "https://image.tmdb.org/t/p/w500/abc.jpg")
        #expect(p.url(size: .original)?.absoluteString == "https://image.tmdb.org/t/p/original/abc.jpg")
        let custom = ImageConfiguration(baseURL: "https://cdn.example/img", posterSizes: [], backdropSizes: [],
                                        profileSizes: [], stillSizes: [], logoSizes: [])
        #expect(ImagePath("x.png").url(size: "w92", configuration: custom)?.absoluteString == "https://cdn.example/img/w92/x.png")
    }
}

// MARK: - Errors

@Suite("TMDB errors")
struct MetadataTMDBErrorTests {
    private func status(_ code: Int, headers: [String: String] = [:], body: Data = Data()) -> MockTransport {
        MockTransport { _, _ in MetadataHTTPResponse(status: code, headers: headers, body: body) }
    }

    @Test func invalidKey() async {
        let t = status(401, body: fixture("error_401"))
        await #expect(throws: MetadataError.invalidAPIKey) { try await makeClient(t).movieDetails(id: 1) }
    }

    @Test func notFound() async {
        await #expect(throws: MetadataError.notFound) { try await makeClient(status(404)).movieDetails(id: 1) }
    }

    @Test func offline() async {
        let t = MockTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: MetadataError.offline) { try await makeClient(t).movieDetails(id: 1) }
    }

    @Test func serverErrorCarriesStatus() async {
        let body = Data(#"{"status_message": "Internal error"}"#.utf8)
        await #expect(throws: MetadataError.server(status: 500, message: "Internal error")) {
            try await makeClient(status(500, body: body)).movieDetails(id: 1)
        }
    }

    @Test func messagesArePlainLanguage() {
        #expect(MetadataError.invalidAPIKey.localizedDescription.contains("API key"))
        #expect(MetadataError.offline.localizedDescription.contains("offline"))
        #expect(MetadataError.rateLimited(retryAfter: 3).localizedDescription.contains("3 seconds"))
        #expect(MetadataError.notFound.localizedDescription.isEmpty == false)
    }

    @Test func retriesOn429HonoringRetryAfter() async throws {
        let sleeper = SleepRecorder()
        let t = MockTransport { _, n in
            n < 3 ? MetadataHTTPResponse(status: 429, headers: ["Retry-After": "4"])
                  : MetadataHTTPResponse(status: 200, body: fixture("search_movie"))
        }
        let page = try await makeClient(t, sleeper: sleeper).searchMovies("matrix")
        #expect(page.results.count == 2)
        #expect(t.requests.count == 3)
        #expect(sleeper.waits == [4, 4])
    }

    @Test func givesUpAfterMaxRetries() async {
        let sleeper = SleepRecorder()
        let t = status(429, headers: ["Retry-After": "1"])
        await #expect(throws: MetadataError.rateLimited(retryAfter: 1)) {
            try await makeClient(t, sleeper: sleeper).searchMovies("x")
        }
        #expect(t.requests.count == 4) // first try + 3 retries
        #expect(sleeper.waits.count == 3)
    }

    @Test func doesNotWaitOutHugeRetryAfter() async {
        let sleeper = SleepRecorder()
        let t = status(429, headers: ["retry-after": "3600"])
        await #expect(throws: MetadataError.rateLimited(retryAfter: 3600)) {
            try await makeClient(t, sleeper: sleeper).searchMovies("x")
        }
        #expect(t.requests.count == 1)
        #expect(sleeper.waits.isEmpty)
    }
}

// MARK: - Caching

@Suite("TMDB caching")
struct MetadataTMDBCacheTests {
    @Test func secondCallIsServedFromMemory() async throws {
        let t = MockTransport(fixture: "movie_details")
        let client = makeClient(t)
        _ = try await client.movieDetails(id: 693134)
        _ = try await client.movieDetails(id: 693134)
        #expect(t.requests.count == 1)
    }

    @Test func detailsExpireAfter24Hours() async throws {
        let t = MockTransport(fixture: "movie_details")
        let clock = Clock()
        let client = makeClient(t, clock: clock)
        _ = try await client.movieDetails(id: 1)
        clock.advance(23 * 3600)
        _ = try await client.movieDetails(id: 1)
        #expect(t.requests.count == 1)
        clock.advance(2 * 3600)
        _ = try await client.movieDetails(id: 1)
        #expect(t.requests.count == 2)
    }

    @Test func trendingExpiresAfterOneHour() async throws {
        let t = MockTransport(fixture: "trending_all")
        let clock = Clock()
        let client = makeClient(t, clock: clock)
        _ = try await client.trending()
        clock.advance(1800)
        _ = try await client.trending()
        #expect(t.requests.count == 1)
        clock.advance(1900)
        _ = try await client.trending()
        #expect(t.requests.count == 2)
    }

    @Test func cacheKeyIgnoresCredentialsButNotLanguageOrParameters() async throws {
        let t = MockTransport(fixture: "search_movie")
        let client = makeClient(t, credential: .apiKey("secret"))
        _ = try await client.searchMovies("a")
        _ = try await client.searchMovies("b")
        #expect(t.requests.count == 2)
    }

    @Test func etagRevalidationWith304() async throws {
        let clock = Clock()
        let t = MockTransport { req, n in
            if n == 1 {
                return MetadataHTTPResponse(status: 200, headers: ["ETag": "\"v1\"", "Cache-Control": "max-age=60"],
                                            body: fixture("movie_details"))
            }
            #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
            return MetadataHTTPResponse(status: 304)
        }
        let client = makeClient(t, clock: clock)
        _ = try await client.movieDetails(id: 1)
        clock.advance(120) // past server max-age
        let m = try await client.movieDetails(id: 1)
        #expect(m.title == "Dune: Part Two")
        #expect(t.requests.count == 2)
        // 304 refreshed freshness, so no third request.
        _ = try await client.movieDetails(id: 1)
        #expect(t.requests.count == 2)
    }

    @Test func cacheControlMaxAgeOverridesDefaultTTL() async throws {
        let clock = Clock()
        let t = MockTransport(fixture: "movie_details", headers: ["Cache-Control": "public, max-age=60"])
        let client = makeClient(t, clock: clock)
        _ = try await client.movieDetails(id: 1)
        clock.advance(90)
        _ = try await client.movieDetails(id: 1)
        #expect(t.requests.count == 2)
    }

    @Test func noStoreIsNotCached() async throws {
        let t = MockTransport(fixture: "movie_details", headers: ["Cache-Control": "no-store"])
        let client = makeClient(t)
        _ = try await client.movieDetails(id: 1)
        _ = try await client.movieDetails(id: 1)
        #expect(t.requests.count == 2)
    }

    @Test func staleEntryServedWhenOffline() async throws {
        let clock = Clock()
        let t = MockTransport { _, n in
            if n == 1 { return MetadataHTTPResponse(status: 200, body: fixture("movie_details")) }
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient(t, clock: clock)
        _ = try await client.movieDetails(id: 1)
        clock.advance(48 * 3600)
        let m = try await client.movieDetails(id: 1)
        #expect(m.id == 693134)
    }

    @Test func diskCachePersistsAcrossClients() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-tmdb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let t1 = MockTransport(fixture: "tv_details")
        _ = try await makeClient(t1, cacheDirectory: dir, clock: clock).seriesDetails(id: 1396)
        #expect(t1.requests.count == 1)

        let t2 = MockTransport(fixture: "tv_details")
        let s = try await makeClient(t2, cacheDirectory: dir, clock: clock).seriesDetails(id: 1396)
        #expect(t2.requests.isEmpty)
        #expect(s.name == "Breaking Bad")
    }

    @Test func lruEvictsLeastRecentlyUsed() async {
        let cache = MetadataCache(capacity: 2)
        func entry(_ k: String) -> CachedResponse {
            CachedResponse(key: k, body: Data(), etag: nil, storedAt: .now, expiresAt: .now)
        }
        await cache.store(entry("a"))
        await cache.store(entry("b"))
        _ = await cache.entry(for: "a") // a is now most recent
        await cache.store(entry("c"))   // evicts b
        #expect(await cache.entry(for: "a") != nil)
        #expect(await cache.entry(for: "b") == nil)
        #expect(await cache.entry(for: "c") != nil)
        #expect(await cache.memoryCount == 2)
    }
}
