import Foundation
import Testing
@testable import MarqueeCore

struct TorznabCapsParsingTests {
    @Test func parsesServerLimitsAndSearchModes() {
        let caps = fixtureCaps()
        #expect(caps.serverTitle == "Example Torznab")
        #expect(caps.limits.max == 100)
        #expect(caps.limits.default == 50)
        #expect(caps.supports(.search))
        #expect(caps.supports(.tvSearch))
        #expect(caps.supports(.movieSearch))
        #expect(caps.searchModes["music-search"]?.available == false)
    }

    @Test func parsesSupportedParams() {
        let caps = fixtureCaps()
        #expect(caps.supports(.tvSearch, param: "season"))
        #expect(caps.supports(.tvSearch, param: "EP"))
        #expect(caps.supports(.tvSearch, param: "tvdbid"))
        #expect(caps.supports(.tvSearch, param: "imdbid"))
        #expect(caps.supports(.tvSearch, param: "tmdbid"))
        #expect(!caps.supports(.tvSearch, param: "rid"))
        #expect(caps.supports(.movieSearch, param: "imdbid"))
        #expect(caps.supports(.movieSearch, param: "year"))
        #expect(!caps.supports(.movieSearch, param: "season"))
        #expect(caps.supports(.search, param: "q"))
    }

    @Test func parsesCategoryTree() {
        let caps = fixtureCaps()
        #expect(caps.categories.map(\.id) == [2000, 3000, 5000, 100001])
        let tv = caps.categories.first { $0.id == 5000 }
        #expect(tv?.name == "TV")
        #expect(tv?.subcategories.map(\.id) == [5030, 5040, 5045])
        #expect(caps.containsCategory(5040))
        #expect(!caps.containsCategory(9999))
        #expect(caps.flattenedCategories.count == 11)
    }

    @Test func unavailableModesAreNotSupported() {
        let caps = fixtureCaps("caps-basic.xml")
        #expect(caps.supports(.search))
        #expect(!caps.supports(.tvSearch))
        #expect(!caps.supports(.tvSearch, param: "q"))
        #expect(!caps.supports(.movieSearch))
        #expect(caps.limits.max == 25)
    }

    @Test func missingSearchingElementDefaultsToTextSearch() throws {
        let xml = Data(#"<caps><server title="Old"/></caps>"#.utf8)
        let caps = try TorznabCapabilities.parse(xml)
        #expect(caps.supports(.search, param: "q"))
        #expect(!caps.supports(.tvSearch))
    }

    @Test func errorDocumentMapsToTypedError() {
        #expect(throws: IndexerError.authenticationFailed(detail: "Incorrect user credentials")) {
            try TorznabCapabilities.parse(IndexerFixtures.data("error-response.xml"))
        }
    }

    @Test func htmlChallengePageIsReportedAsMalformed() {
        do {
            _ = try TorznabCapabilities.parse(IndexerFixtures.data("challenge.html"))
            Issue.record("expected a throw")
        } catch let IndexerError.malformedResponse(detail) {
            #expect(detail.contains("web page"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func emptyAndGarbageBodiesAreMalformed() {
        #expect(throws: IndexerError.self) { try TorznabCapabilities.parse(Data()) }
        #expect(throws: IndexerError.self) { try TorznabCapabilities.parse(Data("not xml at all".utf8)) }
        #expect(throws: IndexerError.self) { try TorznabCapabilities.parse(IndexerFixtures.data("empty-results.xml")) }
    }
}

struct TorznabResultParsingTests {
    @Test func parsesFullTVItem() throws {
        let id = UUID()
        let feed = try parseFeed("tv-results.xml", indexer: id)
        let r = try #require(feed.releases.first)
        #expect(r.title == "Example.Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-GRP")
        #expect(r.indexerID == id)
        #expect(r.indexerName == "Example")
        #expect(r.guid == "https://indexer.example.invalid/details/1001")
        #expect(r.size == 2_254_857_830)
        #expect(r.seeders == 152)
        #expect(r.leechers == 12)
        #expect(r.peers == 164)
        #expect(r.grabs == 2301)
        #expect(r.infoHash == "c9e15763f722f23e98a29decdfae341b98d53056")
        #expect(r.downloadURL?.host == "indexer.example.invalid")
        #expect(r.downloadURL?.queryValue("file") == "Example.Show.S01E02")
        #expect(r.magnetURL?.scheme == "magnet")
        #expect(r.infoURL?.absoluteString == "https://indexer.example.invalid/details/1001#comments")
        #expect(r.categories == [5000, 5040])
        #expect(r.tvdbID == 81189)
        #expect(r.tmdbID == 1396)
        #expect(r.imdbID == "tt0903747")
        #expect(r.downloadVolumeFactor == 0)
        #expect(r.uploadVolumeFactor == 1)
        #expect(r.isFreeleech)
        #expect(r.minimumRatio == 1.0)
        #expect(r.minimumSeedTime == 172_800)
        let expected = Date(timeIntervalSince1970: 1_727_778_600)  // 2024-10-01T10:30:00Z
        #expect(r.publishDate == expected)
    }

    @Test func feedMetadataAndSkippedItems() throws {
        let feed = try parseFeed("tv-results.xml")
        #expect(feed.total == 5)
        #expect(feed.offset == 0)
        #expect(feed.releases.count == 4)
        #expect(feed.skippedItems == 1)  // item with no link or magnet
        #expect(!feed.isPartial)
        #expect(!feed.releases.contains { $0.guid == "broken-1" })
    }

    @Test func magnetOnlyItemDerivesHashFromBase32AndComputesLeechers() throws {
        let feed = try parseFeed("tv-results.xml")
        let r = try #require(feed.releases.first { $0.title.contains("720p HDTV") })
        #expect(r.downloadURL == nil)
        #expect(r.magnetURL?.scheme == "magnet")
        #expect(r.infoHash?.count == 40)
        #expect(r.infoHash == InfoHash.fromMagnet("magnet:?xt=urn:btih:3I42H3S6NNFQ2MSVX7XZKYAYSCX5QBYJ"))
        #expect(r.seeders == 8)
        #expect(r.peers == 11)
        #expect(r.leechers == 3)
        #expect(r.size == 812_345_678)
        // Timezone name form of RFC 822 date
        #expect(r.publishDate == Date(timeIntervalSince1970: 1_727_734_510))
    }

    @Test func packWithOffsetTimezoneAndZeroSeeders() throws {
        let feed = try parseFeed("tv-results.xml")
        let r = try #require(feed.releases.first { $0.guid == "pack-2001" })
        #expect(r.seeders == 0)
        #expect(r.files == 10)
        #expect(r.size == 85_899_345_920)
        #expect(r.categories == [5045])
        #expect(r.publishDate == Date(timeIntervalSince1970: 1_727_589_600))  // 08:00 +0200 == 06:00Z
        #expect(r.downloadVolumeFactor == nil)
    }

    @Test func toleratesCDATABadNumbersAndBadHashes() throws {
        let feed = try parseFeed("tv-results.xml")
        let r = try #require(feed.releases.first { $0.guid == "cdata-1" })
        #expect(r.title == "Example Show & Friends S01E04 [1080p] <PROPER>")
        #expect(r.seeders == nil)
        #expect(r.infoHash == nil)
        #expect(r.size == 1_500_000_000)
        #expect(r.publishDate == Date(timeIntervalSince1970: 1_727_524_800))  // ISO 8601 publishdate attr
    }

    @Test func parsesMovieFeedWithNewznabNamespace() throws {
        let feed = try parseFeed("movie-results.xml")
        #expect(feed.releases.count == 2)
        #expect(feed.total == 2)
        let uhd = feed.releases[0]
        #expect(uhd.imdbID == "tt1375666")
        #expect(uhd.tmdbID == 27205)
        #expect(uhd.infoHash == "aabbccddeeff00112233445566778899aabbccdd")
        #expect(uhd.leechers == 40)
        #expect(uhd.categories == [2000, 2045])
        let hd = feed.releases[1]
        #expect(hd.imdbID == "tt1375666")  // bare digits normalised
        #expect(hd.leechers == 6)
        #expect(hd.infoHash == nil)
    }

    @Test func emptyResultsParseToEmptyFeed() throws {
        let feed = try parseFeed("empty-results.xml")
        #expect(feed.releases.isEmpty)
        #expect(feed.total == 0)
        #expect(feed.skippedItems == 0)
        #expect(!feed.isPartial)
    }

    @Test func errorResponseBecomesAuthenticationError() {
        #expect(throws: IndexerError.authenticationFailed(detail: "Incorrect user credentials")) {
            try parseFeed("error-response.xml")
        }
    }

    @Test func otherErrorCodesBecomeAPIError() {
        #expect(throws: IndexerError.apiError(code: 910, description: "API is disabled")) {
            try parseFeed("error-api-disabled.xml")
        }
    }

    @Test func errorDescriptionNeverLeaksAPIKey() throws {
        let xml = #"<error code="900" description="Upstream failed: https://x.example.invalid/api?t=search&amp;apikey=SECRETKEY123&amp;q=a"/>"#
        do {
            _ = try TorznabResultParser.parse(Data(xml.utf8), indexerID: UUID())
            Issue.record("expected throw")
        } catch let IndexerError.apiError(_, description) {
            #expect(!description.contains("SECRETKEY123"))
            #expect(description.contains("apikey=REDACTED"))
        }
    }

    @Test func truncatedFeedKeepsCompleteItemsAndFlagsPartial() throws {
        let feed = try parseFeed("malformed.xml")
        #expect(feed.isPartial)
        #expect(feed.releases.count == 1)
        #expect(feed.releases[0].guid == "ok-1")
        #expect(feed.releases[0].seeders == 42)
    }

    @Test func malformedWithNoCompleteItemsThrows() {
        #expect(throws: IndexerError.self) { try parseFeed("malformed-no-items.xml") }
    }

    @Test func htmlPageIsMalformedNotACrash() {
        do {
            _ = try parseFeed("challenge.html")
            Issue.record("expected throw")
        } catch let IndexerError.malformedResponse(detail) {
            #expect(detail.contains("web page"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func wrongRootElementIsMalformed() {
        let xml = Data(#"<caps><server title="x"/></caps>"#.utf8)
        #expect(throws: IndexerError.self) { try TorznabResultParser.parse(xml, indexerID: UUID()) }
    }

    @Test func itemWithHashButNoLinkGetsConstructedMagnet() throws {
        let xml = """
            <rss xmlns:torznab="x"><channel><item><title>Hash Only Release</title><guid>h1</guid>
            <torznab:attr name="infohash" value="aabbccddeeff00112233445566778899aabbccdd"/></item></channel></rss>
            """
        let feed = try TorznabResultParser.parse(Data(xml.utf8), indexerID: UUID())
        let r = try #require(feed.releases.first)
        #expect(r.magnetURL?.absoluteString.contains("btih:aabbccddeeff00112233445566778899aabbccdd") == true)
    }

    @Test func releaseDescriptionRedactsLinks() throws {
        let feed = try parseFeed("tv-results.xml")
        let text = String(describing: feed.releases[0])
        #expect(!text.contains("SECRETKEY123"))
    }

    @Test func doesNotResolveExternalEntities() throws {
        let xml = """
            <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/hostname">]>
            <rss><channel><item><title>&xxe;</title><guid>g</guid><link>https://a.example.invalid/x</link></item></channel></rss>
            """
        let feed = try? TorznabResultParser.parse(Data(xml.utf8), indexerID: UUID())
        let hostname = (try? String(contentsOfFile: "/etc/hostname", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = feed?.releases.first?.title, let hostname, !hostname.isEmpty {
            #expect(title != hostname)
        }
    }
}

struct InfoHashTests {
    @Test func normalizesHexAndBase32() {
        #expect(InfoHash.normalize("C9E15763F722F23E98A29DECDFAE341B98D53056") == "c9e15763f722f23e98a29decdfae341b98d53056")
        #expect(InfoHash.normalize("not a hash") == nil)
        #expect(InfoHash.normalize("abc") == nil)
        // base32 of 20 zero bytes
        #expect(InfoHash.normalize(String(repeating: "A", count: 32)) == String(repeating: "0", count: 40))
    }

    @Test func extractsFromMagnetIncludingEncodedForm() {
        let hash = "c9e15763f722f23e98a29decdfae341b98d53056"
        #expect(InfoHash.fromMagnet("magnet:?xt=urn:btih:\(hash)&dn=x") == hash)
        #expect(InfoHash.fromMagnet("magnet:?dn=x&xt=urn%3Abtih%3A\(hash.uppercased())") == hash)
        #expect(InfoHash.fromMagnet("magnet:?dn=x") == nil)
        #expect(InfoHash.fromMagnet("https://example.invalid") == nil)
    }
}
