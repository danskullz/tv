import Foundation
import Testing
@testable import MarqueeCore

struct BuiltInProviderDefaultTests {
    @Test func defaultListUsesStableIDsAndLeavesLocalServicesForConfiguration() {
        let records = DefaultIndexerProviders.records
        #expect(records.count == 9)
        #expect(Set(records.map(\.id)).count == records.count)
        #expect(records.first(where: { $0.implementation == "prowlarr" })?.enabled == false)
        #expect(records.first(where: { $0.implementation == "jackett" })?.enabled == false)
        #expect(records.first(where: { $0.implementation == "torrentproject" })?.enabled == false)
        #expect(records.first(where: { $0.implementation == "torlock" })?.enabled == true)
        #expect(records.allSatisfy { $0.credentialRef == nil || $0.credentialRef?.contains("apikey") == true })
    }

    @Test func firstRunSeederDoesNotRestoreRemovedDefaults() async throws {
        let suiteName = "MarqueeProviderSeedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let database = try AppDatabase.inMemory()
        let repository = GRDBIndexerRepository(database)

        let installed = try await DefaultIndexerProviderSeeder.installIfNeeded(into: repository, defaults: defaults)
        #expect(installed)
        #expect(try await repository.all().count == 9)
        let removed = try #require(DefaultIndexerProviders.records.first)
        try await repository.delete(id: removed.id)
        let installedAgain = try await DefaultIndexerProviderSeeder.installIfNeeded(into: repository, defaults: defaults)
        #expect(!installedAgain)
        #expect(try await repository.indexer(id: removed.id) == nil)
        #expect(defaults.bool(forKey: DefaultIndexerProviders.installedDefaultsKey))
    }
}

struct BuiltInProviderAdapterTests {
    private let sourceID = UUID(uuidString: "b0a9f4ef-1f68-4fd8-90b7-59f361e345c2")!
    private let base = URL(string: "https://provider.example.invalid")!

    @Test func buildsEncodedURLsForPublicSearchAPIs() throws {
        let query = TorznabQuery.tv(title: "Björk & Co", season: 2, episode: 3)
        let eztv = try BuiltInProviderSearch.url(provider: .eztv, server: URL(string: "https://eztvx.to")!, query: query)
        #expect(eztv.path == "/api/get-torrents")
        #expect(eztv.providerQueryValue("keywords") == "Björk & Co S02E03")

        let solid = try BuiltInProviderSearch.url(provider: .solidTorrents, server: base, query: query)
        #expect(solid.path == "/api/v1/search")
        #expect(solid.providerQueryValue("q") == "Björk & Co S02E03")

        let pirateBay = try BuiltInProviderSearch.url(provider: .pirateBay, server: base, query: query)
        #expect(pirateBay.path == "/q.php")
        #expect(pirateBay.providerQueryValue("cat") == "205")
    }

    @Test func mapsEztvJSONAndSanitizesNames() throws {
        let json = #"{"torrents":[{"id":7,"title":"Show\nS01E02 1080p","filename":"show.mkv","hash":"0123456789012345678901234567890123456789","magnet_url":"magnet:?xt=urn:btih:0123456789012345678901234567890123456789&dn=show","seeds":28,"peers":35,"date_released_unix":1791553102,"size_bytes":"1056159750"}]}"#
        let releases = try BuiltInProviderSearch.parse(
            Data(json.utf8), provider: .eztv, indexerID: sourceID, indexerName: "EZTV",
            query: .tv(title: "Show"), server: URL(string: "https://eztvx.to")!)
        let release = try #require(releases.first)
        #expect(release.title == "Show S01E02 1080p")
        #expect(release.size == 1_056_159_750)
        #expect(release.seeders == 28)
        #expect(release.leechers == 7)
        #expect(release.infoHash == "0123456789012345678901234567890123456789")
        #expect(release.publishDate != nil)
    }

    @Test func mapsSolidTorrentsThePirateBayAndTorrentsCSVJSON() throws {
        let hash = "0123456789012345678901234567890123456789"
        let solid = #"{"success":true,"results":[{"id":"solid-1","infohash":"0123456789012345678901234567890123456789","title":"Solid release","size":1024,"seeders":8,"leechers":2,"createdAt":"2026-10-01T10:00:00Z"}]}"#
        let pirateBay = #"[{"id":"42","info_hash":"0123456789012345678901234567890123456789","name":"Pirate release","size":"2048","seeders":"9","leechers":"1","added":"1790000000"}]"#
        let csv = #"{"torrents":[{"id":3,"infohash":"0123456789012345678901234567890123456789","name":"CSV release","size_bytes":4096,"seeders":10,"leechers":3,"created_unix":1790000000}]}"#

        for (provider, body, expectedTitle, expectedSize) in [
            (BuiltInProvider.solidTorrents, solid, "Solid release", Int64(1024)),
            (.pirateBay, pirateBay, "Pirate release", 2048),
            (.torrentsCSV, csv, "CSV release", 4096),
        ] {
            let releases = try BuiltInProviderSearch.parse(
                Data(body.utf8), provider: provider, indexerID: sourceID, indexerName: provider.name,
                query: .generic("ubuntu"), server: base)
            let release = try #require(releases.first)
            #expect(release.title == expectedTitle)
            #expect(release.size == expectedSize)
            #expect(release.infoHash == hash)
            #expect(release.magnetURL?.scheme == "magnet")
            if provider == .solidTorrents { #expect(release.publishDate != nil) }
        }
    }

    @Test func parsesLimeTorrentsRowsAndDirectDownloadLinks() throws {
        let html = #"""
            <html><body>Search Results<table class="table2">
            <tr><th>Name</th></tr>
            <tr bgcolor="#F4F4F4"><td><a href="http://itorrents.net/torrent/0123456789012345678901234567890123456789.torrent">download</a><a href="/ubuntu-26-torrent-1.html">Ubuntu &amp; Linux</a></td><td>8 hours ago</td><td>1.5 GB</td><td>1,413</td><td>49</td></tr>
            </table></body></html>
            """#
        let releases = try BuiltInProviderSearch.parse(
            Data(html.utf8), provider: .limeTorrents, indexerID: sourceID, indexerName: "LimeTorrents",
            query: .generic("ubuntu"), server: URL(string: "https://www.limetorrents.fun")!)
        let release = try #require(releases.first)
        #expect(release.title == "Ubuntu & Linux")
        #expect(release.downloadURL?.host == "itorrents.net")
        #expect(release.seeders == 1413)
        #expect(release.leechers == 49)
        #expect(release.size == 1_500_000_000)
    }

    @Test func rejectsStaleTorrentProjectResponseInsteadOfShowingItAsResults() throws {
        #expect(throws: IndexerError.self) {
            try BuiltInProviderSearch.parse(
                Data(#"{"total":4,"torrents":"casino ads"}"#.utf8), provider: .torrentProject,
                indexerID: sourceID, indexerName: "TorrentProject", query: .generic("test"), server: base)
        }
    }

    @Test func clientRoutesBuiltinSearchThroughTheNativeAdapter() async throws {
        let hash = "0123456789012345678901234567890123456789"
        let json = #"{"torrents":[{"id":1,"title":"TV release","hash":"0123456789012345678901234567890123456789","magnet_url":"magnet:?xt=urn:btih:0123456789012345678901234567890123456789","seeds":12,"peers":15,"size_bytes":4096}]}"#
        let definition = IndexerDefinition(
            name: "EZTV", baseURL: URL(string: "https://eztvx.to")!, implementation: "eztv",
            minimumSeeders: 0, rateLimit: .unlimited)
        let transport = FakeIndexerTransport { request, _ in
            #expect(request.url.path == "/api/get-torrents")
            #expect(request.url.queryValue("keywords") == "Example S01E02")
            #expect(request.headers["Accept"]?.contains("application/json") == true)
            return IndexerHTTPResponse(statusCode: 200, body: Data(json.utf8))
        }
        let client = IndexerClient(
            definition: definition, secrets: InMemorySecretStore(), transport: transport,
            configuration: IndexerClientConfiguration())

        let result = try await client.search(.tv(title: "Example", season: 1, episode: 2))

        #expect(result.releases.first?.infoHash == hash)
        #expect(transport.requests.count == 1)
    }

    @Test func torlockUsesItsNativeTorznabFeedWithoutACapabilitiesRoundTrip() async throws {
        var definition = IndexerDefinition(
            name: "TorLock", baseURL: URL(string: "https://www.torlock.com")!, implementation: "torlock",
            apiPath: "/torznab/api", minimumSeeders: 0, rateLimit: .unlimited)
        definition.id = sourceID
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = IndexerClient(
            definition: definition, secrets: InMemorySecretStore(), transport: transport,
            configuration: IndexerClientConfiguration())

        let result = try await client.search(.generic("ubuntu"))

        #expect(result.releases.isEmpty)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url.path == "/torznab/api")
        #expect(transport.requests[0].url.queryValue("t") == "search")
    }

    @Test func torlockReusesAnIdenticalQueryForTheOneMinuteFairUseWindow() async throws {
        var definition = IndexerDefinition(
            name: "TorLock", baseURL: URL(string: "https://www.torlock.com")!, implementation: "torlock",
            apiPath: "/torznab/api", minimumSeeders: 0, rateLimit: .unlimited)
        definition.id = sourceID
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = IndexerClient(
            definition: definition, secrets: InMemorySecretStore(), transport: transport,
            clock: FakeIndexerClock(), configuration: IndexerClientConfiguration())

        _ = try await client.search(.generic("ubuntu"))
        _ = try await client.search(.generic("ubuntu"))

        #expect(transport.requests.count == 1)
    }
}

private extension URL {
    func providerQueryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
