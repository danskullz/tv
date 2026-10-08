import Foundation
import Testing
@testable import MarqueeCore

struct TorznabQueryBuilderTests {
    let def = makeDefinition()

    private func plan(_ q: TorznabQuery, caps: String = "caps.xml", definition: IndexerDefinition? = nil) throws -> TorznabRequestPlan {
        try TorznabQueryBuilder.plan(for: q, definition: definition ?? def, capabilities: fixtureCaps(caps))
    }

    // MARK: Generic

    @Test func genericSearchUsesTextOnly() throws {
        let p = try plan(.generic("some thing"))
        #expect(p.function == .search)
        #expect(p.value("q") == "some thing")
        #expect(p.value("cat") == nil)
        #expect(p.value("extended") == "1")
        #expect(!p.usedTextFallback)
    }

    @Test func genericWithoutTextIsRecentReleasesFeed() throws {
        let p = try plan(.generic())
        #expect(p.value("q") == nil)
        #expect(p.function == .search)
    }

    @Test func genericUsesConfiguredAndExplicitCategories() throws {
        let configured = makeDefinition(categories: [5030, 2040])
        #expect(try plan(.generic("x"), definition: configured).value("cat") == "5030,2040")
        #expect(try plan(.generic("x", categories: [3000]), definition: configured).value("cat") == "3000")
    }

    // MARK: TV

    @Test func tvByTvdbIDSeasonAndEpisode() throws {
        let p = try plan(.tv(title: "Example Show", season: 1, episode: 2, tvdbID: 81189))
        #expect(p.function == .tvSearch)
        #expect(p.value("tvdbid") == "81189")
        #expect(p.value("season") == "1")
        #expect(p.value("ep") == "2")
        #expect(p.value("q") == nil, "q is omitted when an id is used")
        #expect(p.value("cat") == "5000")
        #expect(!p.usedTextFallback)
    }

    @Test func tvSendsAllSupportedIDs() throws {
        let p = try plan(.tv(title: "x", imdbID: "tt0903747", tvdbID: 81189, tmdbID: 1396))
        #expect(p.value("imdbid") == "0903747")
        #expect(p.value("tvdbid") == "81189")
        #expect(p.value("tmdbid") == "1396")
    }

    @Test func tvFallsBackToTextWhenIDUnsupported() throws {
        // caps-limited: tv-search supports only q
        let p = try plan(.tv(title: "Example Show", season: 1, episode: 2, tvdbID: 81189), caps: "caps-limited.xml")
        #expect(p.function == .tvSearch)
        #expect(p.value("tvdbid") == nil)
        #expect(p.value("season") == nil)
        #expect(p.value("q") == "Example Show S01E02")
        #expect(p.usedTextFallback)
    }

    @Test func tvSeasonPackSearchUsesSeasonOnly() throws {
        let p = try plan(.tv(title: "Example Show", season: 3))
        #expect(p.value("q") == "Example Show")
        #expect(p.value("season") == "3")
        #expect(p.value("ep") == nil)
        let text = try plan(.tv(title: "Example Show", season: 3), caps: "caps-limited.xml")
        #expect(text.value("q") == "Example Show S03")
    }

    @Test func tvFallsBackToGenericSearchWhenTVSearchMissing() throws {
        let p = try plan(.tv(title: "Example Show", season: 1, episode: 2, tvdbID: 81189), caps: "caps-basic.xml")
        #expect(p.function == .search)
        #expect(p.value("q") == "Example Show S01E02")
        #expect(p.usedTextFallback)
        #expect(p.value("tvdbid") == nil)
    }

    @Test func tvWithOnlyUnsupportedIDAndNoTitleThrows() {
        #expect(throws: IndexerError.self) {
            try plan(.tv(season: 1, tvdbID: 81189), caps: "caps-limited.xml")
        }
        #expect(throws: IndexerError.self) {
            try plan(.tv(tvdbID: 81189), caps: "caps-basic.xml")
        }
    }

    @Test func tvCategoryDefaultsRespectIndexerCategories() throws {
        // caps-limited lists no TV category, so no default cat is sent.
        #expect(try plan(.tv(title: "x"), caps: "caps-limited.xml").value("cat") == nil)
        // Configured categories outside the TV range are ignored for TV searches.
        let mixed = makeDefinition(categories: [2040, 5040, 5045])
        #expect(try plan(.tv(title: "x"), definition: mixed).value("cat") == "5040,5045")
        let movieOnly = makeDefinition(categories: [2040])
        #expect(try plan(.tv(title: "x"), definition: movieOnly).value("cat") == "5000")
    }

    // MARK: Movie

    @Test func movieByIMDbAndTMDb() throws {
        let p = try plan(.movie(title: "Example Movie", year: 2021, imdbID: "tt1375666", tmdbID: 27205))
        #expect(p.function == .movieSearch)
        #expect(p.value("imdbid") == "1375666")
        #expect(p.value("tmdbid") == "27205")
        #expect(p.value("year") == "2021")
        #expect(p.value("q") == nil)
        #expect(p.value("cat") == "2000")
    }

    @Test func movieByTitleAndYear() throws {
        let p = try plan(.movie(title: "Example Movie", year: 2021))
        #expect(p.value("q") == "Example Movie")
        #expect(p.value("year") == "2021")
    }

    @Test func movieYearAppendedToTextWhenUnsupported() throws {
        let p = try plan(.movie(title: "Example Movie", year: 2021, imdbID: "tt1375666"), caps: "caps-limited.xml")
        #expect(p.value("q") == "Example Movie 2021")
        #expect(p.value("year") == nil)
        #expect(p.value("imdbid") == nil)
        #expect(p.usedTextFallback)
    }

    @Test func movieFallsBackToGenericSearch() throws {
        let p = try plan(.movie(title: "Example Movie", year: 2021, tmdbID: 27205), caps: "caps-basic.xml")
        #expect(p.function == .search)
        #expect(p.value("q") == "Example Movie 2021")
        #expect(p.usedTextFallback)
    }

    // MARK: Limits & paging

    @Test func limitIsCappedByServerMaxAndDefaultsFromCaps() throws {
        #expect(try plan(.generic("x")).value("limit") == "50")
        #expect(try plan(.generic("x", limit: 500)).value("limit") == "100")
        #expect(try plan(.generic("x", limit: 10)).value("limit") == "10")
        #expect(try plan(.generic("x", offset: 100)).value("offset") == "100")
        #expect(try plan(.generic("x", offset: 0)).value("offset") == nil)
    }

    // MARK: URL building

    @Test func urlContainsFunctionKeyAndEncodedValues() throws {
        let p = try plan(.tv(title: "Law & Order: C++", season: 1))
        let url = try TorznabEndpoint.url(definition: def, function: p.function.tParameter, parameters: p.parameters, apiKey: "SECRETKEY123")
        #expect(url.path == "/api")
        #expect(url.queryValue("t") == "tvsearch")
        #expect(url.queryValue("apikey") == "SECRETKEY123")
        #expect(url.queryValue("q") == "Law & Order: C++")
        #expect(url.absoluteString.contains("Law%20%26%20Order%3A%20C%2B%2B"))
    }

    @Test func urlJoinsBasePrefixAndApiPath() throws {
        let d = IndexerDefinition(
            name: "J", baseURL: URL(string: "http://localhost:9117/prefix/")!, apiPath: "api/v2.0/indexers/x/results/torznab/api")
        let url = try TorznabEndpoint.url(definition: d, function: "caps", parameters: [], apiKey: nil)
        #expect(url.path == "/prefix/api/v2.0/indexers/x/results/torznab/api")
        #expect(url.queryValue("t") == "caps")
        #expect(url.queryValue("apikey") == nil)
    }

    @Test func invalidBaseURLIsAConfigurationError() {
        let d = IndexerDefinition(name: "Bad", baseURL: URL(string: "ftp://example.invalid")!)
        #expect(throws: IndexerError.self) {
            try TorznabEndpoint.url(definition: d, function: "caps", parameters: [], apiKey: nil)
        }
    }
}
