import Foundation
import Synchronization
import Testing
@testable import MarqueeCore

private struct LeakyError: Error, CustomStringConvertible {
    var description: String { "connection failed for https://indexer.example.invalid/api?t=search&apikey=SECRETKEY123" }
}

private func makeClient(
    _ definition: IndexerDefinition = makeDefinition(),
    transport: FakeIndexerTransport,
    clock: FakeIndexerClock = FakeIndexerClock(),
    secrets: SecretStore? = nil,
    configure: (inout IndexerClientConfiguration) -> Void = { _ in }
) -> IndexerClient {
    var config = IndexerClientConfiguration()
    configure(&config)
    return IndexerClient(
        definition: definition, secrets: secrets ?? makeSecrets(for: [definition]), transport: transport, clock: clock,
        configuration: config, random: { 1.0 })
}

private func response(_ status: Int, _ headers: [String: String] = [:], body: String = "") -> IndexerHTTPResponse {
    IndexerHTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
}

struct IndexerClientSearchTests {
    @Test func configuredFlareSolverrAddressIsForwardedToTransport() async throws {
        var definition = makeDefinition()
        definition.flareSolverrURL = URL(string: "http://localhost:8191")
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = makeClient(definition, transport: transport)

        _ = try await client.search(.generic("example"))

        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.flareSolverrURL == definition.flareSolverrURL })
        #expect(transport.requests.allSatisfy { $0.timeout >= 90 })
    }

    @Test func searchSendsExpectedRequestAndParsesResults() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("tv-results.xml"))
        let def = makeDefinition(apiPath: "/torznab/api")
        let client = makeClient(def, transport: transport)

        let result = try await client.search(.tv(title: "Example Show", season: 1, episode: 2, tvdbID: 81189))

        #expect(result.releases.count == 4)
        #expect(result.skippedItems == 1)
        #expect(result.totalAvailable == 5)
        #expect(!result.usedTextFallback)
        #expect(result.releases.allSatisfy { $0.indexerID == def.id && $0.indexerName == "Example" })

        let search = try #require(transport.searchRequests.first)
        #expect(search.url.host == "indexer.example.invalid")
        #expect(search.url.path == "/torznab/api")
        #expect(search.url.queryValue("t") == "tvsearch")
        #expect(search.url.queryValue("apikey") == "SECRETKEY123")
        #expect(search.url.queryValue("tvdbid") == "81189")
        #expect(search.url.queryValue("season") == "1")
        #expect(search.url.queryValue("ep") == "2")
        #expect(search.headers["User-Agent"] == "Marquee")
        #expect(search.timeout == 20)
    }

    @Test func movieSearchParsesAndUsesMovieFunction() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("movie-results.xml"))
        let client = makeClient(transport: transport)
        let result = try await client.search(.movie(title: "Example Movie", year: 2021, imdbID: "tt1375666"))
        #expect(result.releases.count == 2)
        #expect(transport.searchRequests[0].url.queryValue("t") == "movie")
        #expect(transport.searchRequests[0].url.queryValue("imdbid") == "1375666")
    }

    @Test func emptyResultsAreNotAnError() async throws {
        let client = makeClient(transport: FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml")))
        let result = try await client.search(.generic("nothing"))
        #expect(result.releases.isEmpty)
    }

    @Test func capabilitiesAreFetchedOnceAndCached() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = makeClient(transport: transport)
        _ = try await client.search(.generic("a"))
        _ = try await client.search(.generic("b"))
        _ = try await client.capabilities()
        #expect(transport.requests.filter { $0.url.queryValue("t") == "caps" }.count == 1)
    }

    @Test func concurrentFirstUseSharesOneCapsRequest() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = makeClient(transport: transport)
        async let a = client.search(.generic("a"))
        async let b = client.search(.generic("b"))
        _ = try await (a, b)
        #expect(transport.requests.filter { $0.url.queryValue("t") == "caps" }.count == 1)
    }

    @Test func capabilitiesExpireAfterTTL() async throws {
        let clock = FakeIndexerClock()
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = makeClient(transport: transport, clock: clock) { $0.capsTTL = 3600 }
        _ = try await client.capabilities()
        clock.advance(by: 1800)
        _ = try await client.capabilities()
        #expect(transport.requests.count == 1)
        clock.advance(by: 3600)
        _ = try await client.capabilities()
        #expect(transport.requests.count == 2)
    }

    @Test func updatingAddressDropsCachedCapabilities() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let def = makeDefinition()
        let client = makeClient(def, transport: transport)
        _ = try await client.capabilities()
        var moved = def
        moved.baseURL = URL(string: "https://other.example.invalid")!
        await client.update(definition: moved)
        _ = try await client.capabilities()
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].url.host == "other.example.invalid")
    }

    @Test func unsupportedSearchFailsWithoutSendingASearchRequest() async throws {
        let transport = FakeIndexerTransport(caps: IndexerFixtures.data("caps-basic.xml"), search: Data())
        let client = makeClient(transport: transport)
        await #expect(throws: IndexerError.self) { try await client.search(.tv(tvdbID: 1)) }
        #expect(transport.searchRequests.isEmpty)
    }

    @Test func textFallbackIsReported() async throws {
        let transport = FakeIndexerTransport(caps: IndexerFixtures.data("caps-basic.xml"), search: IndexerFixtures.data("empty-results.xml"))
        let client = makeClient(transport: transport)
        let result = try await client.search(.tv(title: "Example Show", season: 1, episode: 2, tvdbID: 81189))
        #expect(result.usedTextFallback)
        #expect(transport.searchRequests[0].url.queryValue("t") == "search")
        #expect(transport.searchRequests[0].url.queryValue("q") == "Example Show S01E02")
    }

    @Test func minimumSeedersFiltersKnownLowSeedReleases() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("tv-results.xml"))
        let client = makeClient(makeDefinition(minimumSeeders: 10), transport: transport)
        let result = try await client.search(.generic("x"))
        // 152 stays; 8 and 0 are dropped; unknown seeders (nil) are kept.
        #expect(result.releases.map(\.seeders) == [152, nil])
        #expect(result.filteredBySeeders == 2)
    }

    @Test func partialFeedIsReturnedNotThrown() async throws {
        let client = makeClient(transport: FakeIndexerTransport(search: IndexerFixtures.data("malformed.xml")))
        let result = try await client.search(.generic("x"))
        #expect(result.isPartial)
        #expect(result.releases.count == 1)
    }

    @Test func testReturnsLatencyAndCapabilities() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("tv-results.xml"))
        let client = makeClient(transport: transport)
        let result = try await client.test()
        #expect(result.capabilities.serverTitle == "Example Torznab")
        #expect(result.sampleReleaseCount == 4)
        #expect(transport.searchRequests[0].url.queryValue("limit") == "1")
    }

    @Test func missingKeyOmitsParameter() async throws {
        let def = makeDefinition()
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
        let client = makeClient(def, transport: transport, secrets: InMemorySecretStore())
        _ = try await client.search(.generic("x"))
        #expect(transport.requests.allSatisfy { $0.url.queryValue("apikey") == nil })
    }
}

struct ProwlarrClientTests {
    @Test func searchesEnabledTorrentIndexersAndMapsReleaseMetadata() async throws {
        var definition = makeDefinition(host: "prowlarr.example.invalid")
        definition.baseURL = URL(string: "https://prowlarr.example.invalid/prowlarr")!
        definition.implementation = "prowlarr"
        let indexers = #"[{"id":10,"enable":true,"protocol":"torrent"},{"id":20,"enable":true,"protocol":2},{"id":30,"enable":false,"protocol":"torrent"}]"#
        let releases = #"[{"guid":"release-10","title":"Show\nS01E02\t1080p","size":2048,"indexer":"Tracker One","indexerFlags":["G_Freeleech","DoubleUpload"],"publishDate":"2025-02-03T12:30:45.123Z","downloadUrl":"https://prowlarr.example.invalid/download/10","magnetUrl":"magnet:?xt=urn:btih:0123456789012345678901234567890123456789","infoUrl":"https://tracker.example.invalid/release/10","seeders":40,"leechers":4,"protocol":"torrent"},{"guid":"release-usenet","title":"Usenet result","downloadUrl":"https://prowlarr.example.invalid/download/nzb","protocol":2}]"#
        let transport = FakeIndexerTransport { request, _ in
            if request.url.path == "/prowlarr/api/v1/indexer" {
                return response(200, body: indexers)
            }
            #expect(request.url.path == "/prowlarr/api/v1/search")
            #expect(request.headers["X-Api-Key"] == "SECRETKEY123")
            #expect(request.url.queryValue("type") == "search")
            #expect(request.url.queryValue("indexerIds") == "10")
            #expect(request.url.queryValue("categories") == "5000")
            #expect(request.url.queryValue("query") == "Björk S01E02")
            return response(200, body: releases)
        }
        let client = makeClient(definition, transport: transport, secrets: makeSecrets(for: [definition]))

        let result = try await client.search(.tv(title: "Björk", season: 1, episode: 2))

        #expect(result.releases.count == 1)
        #expect(!result.isPartial)
        let release = try #require(result.releases.first)
        #expect(release.title == "Show S01E02 1080p")
        #expect(release.indexerName == "Tracker One")
        #expect(release.seeders == 40)
        #expect(release.leechers == 4)
        #expect(release.isFreeleech)
        #expect(release.indexerFlags == ["Freeleech", "DoubleUpload"])
        #expect(release.publishDate != nil)
        #expect(transport.requests.count == 2)
    }

    @Test func emptyEnabledSetFallsBackToAllIndexers() async throws {
        var definition = makeDefinition(host: "prowlarr.example.invalid")
        definition.implementation = "prowlarr"
        let transport = FakeIndexerTransport { request, _ in
            if request.url.path.hasSuffix("/indexer") { return response(200, body: "[]") }
            #expect(request.url.queryValue("indexerIds") == "-2")
            return response(200, body: "[]")
        }
        let client = makeClient(definition, transport: transport, secrets: makeSecrets(for: [definition]))
        let result = try await client.search(.generic("C++"))
        #expect(result.releases.isEmpty)
        #expect(transport.requests.last?.url.queryValue("query") == "C++")
    }

    @Test func connectionTestChecksAPIKeyAndSearchRoute() async throws {
        var definition = makeDefinition(host: "prowlarr.example.invalid")
        definition.implementation = "prowlarr"
        let transport = FakeIndexerTransport { request, _ in
            if request.url.path.hasSuffix("/indexer") { return response(200, body: "[]") }
            return response(200, body: "[]")
        }
        let client = makeClient(definition, transport: transport, secrets: makeSecrets(for: [definition]))

        let result = try await client.test()

        #expect(result.capabilities.serverTitle == "Prowlarr")
        #expect(result.sampleReleaseCount == 0)
        #expect(transport.requests.filter { $0.url.path.hasSuffix("/indexer") }.count == 2)
        #expect(transport.requests.last?.url.path.hasSuffix("/search") == true)
    }

    @Test func rejectsHTMLResponseWithActionableError() async throws {
        var definition = makeDefinition(host: "prowlarr.example.invalid")
        definition.implementation = "prowlarr"
        let transport = FakeIndexerTransport { _, _ in response(200, body: "<!doctype html><html>blocked</html>") }
        let client = makeClient(definition, transport: transport, secrets: makeSecrets(for: [definition]))

        await #expect(throws: IndexerError.malformedResponse(
            "Prowlarr returned an HTML page instead of JSON. Check the URL base, reverse proxy, or access challenge.")) {
            try await client.search(.generic("test"))
        }
    }
}

struct FlareSolverrTransportTests {
    @Test func wrapsTorznabURLAndReturnsSolvedResponse() async throws {
        let requests = Mutex<[IndexerHTTPRequest]>([])
        let base = FakeIndexerTransport { request, _ in
            requests.withLock { $0.append(request) }
            guard let body = request.body,
                let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { throw IndexerError.malformedResponse("Expected JSON request body.") }
            #expect(payload["cmd"] as? String == "request.get")
            #expect(payload["maxTimeout"] as? Int == 60_000)
            #expect((payload["url"] as? String)?.contains("apikey=KEY123") == true)
            return response(200, body: #"{"status":"ok","solution":{"status":200,"response":"<xml>solved</xml>"}}"#)
        }
        let transport = FlareSolverrIndexerTransport(base: base)
        let request = IndexerHTTPRequest(
            url: URL(string: "https://indexer.example.invalid/api?t=caps&apikey=KEY123")!,
            flareSolverrURL: URL(string: "http://localhost:8191"))

        let result = try await transport.send(request)

        #expect(result.statusCode == 200)
        #expect(String(decoding: result.body, as: UTF8.self) == "<xml>solved</xml>")
        let sent = try #require(requests.withLock { $0.first })
        #expect(sent.url.absoluteString == "http://localhost:8191/v1")
        #expect(sent.method == "POST")
        #expect(sent.headers["Content-Type"] == "application/json")
    }

    @Test func directRequestsBypassFlareSolverrAndPathIsNormalized() async throws {
        let base = FakeIndexerTransport { request, _ in response(200, body: "direct") }
        let transport = FlareSolverrIndexerTransport(base: base)
        let result = try await transport.send(IndexerHTTPRequest(url: URL(string: "https://indexer.invalid/api")!))
        #expect(String(decoding: result.body, as: UTF8.self) == "direct")
        #expect(try FlareSolverrIndexerTransport.endpoint(for: URL(string: "http://localhost:8191/v1")!).path == "/v1")
        #expect(try FlareSolverrIndexerTransport.endpoint(for: URL(string: "http://localhost:8191/proxy/v1/")!).path == "/proxy/v1")
    }

    @Test func rejectsMalformedSolverAddressAndResponse() async throws {
        let base = FakeIndexerTransport { _, _ in response(200, body: #"{"status":"error"}"#) }
        let transport = FlareSolverrIndexerTransport(base: base)
        await #expect(throws: IndexerError.self) {
            try await transport.send(IndexerHTTPRequest(
                url: URL(string: "https://indexer.invalid/api")!, flareSolverrURL: URL(string: "file:///tmp/solver")!))
        }
        await #expect(throws: IndexerError.self) {
            try await transport.send(IndexerHTTPRequest(
                url: URL(string: "https://indexer.invalid/api")!, flareSolverrURL: URL(string: "http://localhost:8191")!))
        }
    }
}

struct IndexerClientErrorTests {
    @Test func apiErrorBodyOn200IsTypedAndNotRetried() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("error-response.xml"))
        let client = makeClient(transport: transport)
        await #expect(throws: IndexerError.authenticationFailed(detail: "Incorrect user credentials")) {
            try await client.search(.generic("x"))
        }
        #expect(transport.searchRequests.count == 1)
    }

    @Test func errorBodyEchoingKeyIsRedacted() async throws {
        let body = #"<error code="900" description="Problem for key SECRETKEY123 at ?apikey=SECRETKEY123"/>"#
        let client = makeClient(transport: FakeIndexerTransport(search: Data(body.utf8)))
        do {
            _ = try await client.search(.generic("x"))
            Issue.record("expected throw")
        } catch let error as IndexerError {
            #expect(!error.technicalDetail.contains("SECRETKEY123"))
            #expect(!error.userMessage.contains("SECRETKEY123"))
        }
    }

    @Test func transportErrorsNeverLeakTheKey() async throws {
        let transport = FakeIndexerTransport { _, _ in throw LeakyError() }
        let client = makeClient(transport: transport)
        do {
            _ = try await client.capabilities()
            Issue.record("expected throw")
        } catch let error as IndexerError {
            guard case .network(let detail) = error else { Issue.record("expected network, got \(error)"); return }
            #expect(!detail.contains("SECRETKEY123"))
            #expect(!error.technicalDetail.contains("SECRETKEY123"))
        }
    }

    @Test func authAndNotFoundAreNotRetried() async throws {
        for (status, expected) in [(401, IndexerError.authenticationFailed(detail: "HTTP 401")), (404, .httpStatus(404)), (403, .httpStatus(403))] {
            let transport = FakeIndexerTransport { _, _ in response(status) }
            let client = makeClient(transport: transport)
            await #expect(throws: expected) { try await client.capabilities() }
            #expect(transport.requests.count == 1)
        }
    }

    @Test func htmlOn200IsMalformedNotRetried() async throws {
        let transport = FakeIndexerTransport(caps: IndexerFixtures.data("challenge.html"), search: Data())
        let client = makeClient(transport: transport)
        await #expect(throws: IndexerError.self) { try await client.capabilities() }
        #expect(transport.requests.count == 1)
    }

    @Test func oversizedResponseIsRejected() async throws {
        let transport = FakeIndexerTransport(search: IndexerFixtures.data("tv-results.xml"))
        let client = makeClient(transport: transport) { $0.maxResponseBytes = 100 }
        await #expect(throws: IndexerError.responseTooLarge) { try await client.capabilities() }
    }

    @Test func cancellationPropagatesAsCancellationError() async throws {
        let transport = FakeIndexerTransport { _, _ in
            try await Task.sleep(for: .seconds(30))
            return response(200)
        }
        let client = makeClient(transport: transport)
        let task = Task { try await client.capabilities() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

struct IndexerClientBackoffTests {
    /// caps request is call #1; searches are calls #2...
    private func scripted(_ replies: [IndexerHTTPResponse]) -> FakeIndexerTransport {
        FakeIndexerTransport { request, n in
            if request.url.queryValue("t") == "caps" { return IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("caps.xml")) }
            let index = min(n - 2, replies.count - 1)
            return replies[index]
        }
    }

    private let ok = IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("empty-results.xml"))

    @Test func retriesServerErrorsWithExponentialBackoff() async throws {
        let transport = scripted([response(503), response(500), ok])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock)
        let result = try await client.search(.generic("x"))
        #expect(result.releases.isEmpty)
        #expect(transport.searchRequests.count == 3)
        #expect(clock.sleeps == [1, 2])  // random fixed at 1.0 => no jitter reduction
    }

    @Test func jitterReducesDelay() async throws {
        let transport = scripted([response(503), ok])
        let clock = FakeIndexerClock()
        let def = makeDefinition()
        let client = IndexerClient(
            definition: def, secrets: makeSecrets(for: [def]), transport: transport, clock: clock,
            configuration: IndexerClientConfiguration(), random: { 0 })
        _ = try await client.search(.generic("x"))
        #expect(clock.sleeps == [0.5])  // base 1s, jitter 0.5, random 0
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let transport = scripted([response(503)])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock) { $0.maxAttempts = 3 }
        await #expect(throws: IndexerError.serverError(status: 503)) { try await client.search(.generic("x")) }
        #expect(transport.searchRequests.count == 3)
        #expect(clock.sleeps == [1, 2])
    }

    @Test func maxAttemptsOneDisablesRetry() async throws {
        let transport = scripted([response(503)])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock) { $0.maxAttempts = 1 }
        await #expect(throws: IndexerError.serverError(status: 503)) { try await client.search(.generic("x")) }
        #expect(transport.searchRequests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func backoffDelayIsCapped() async throws {
        let transport = scripted([response(503)])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock) {
            $0.maxAttempts = 6
            $0.backoffMax = 4
        }
        await #expect(throws: IndexerError.self) { try await client.search(.generic("x")) }
        #expect(clock.sleeps == [1, 2, 4, 4, 4])
    }

    @Test func honorsRetryAfterOn429() async throws {
        let transport = scripted([response(429, ["Retry-After": "7"]), ok])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock)
        _ = try await client.search(.generic("x"))
        #expect(clock.sleeps == [7])
    }

    @Test func retryAfterHeaderLookupIsCaseInsensitive() async throws {
        let transport = scripted([response(429, ["retry-after": "3"]), ok])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock)
        _ = try await client.search(.generic("x"))
        #expect(clock.sleeps == [3])
    }

    @Test func refusesToWaitLongerThanBackoffMax() async throws {
        let transport = scripted([response(429, ["Retry-After": "600"])])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock)
        await #expect(throws: IndexerError.rateLimited(retryAfter: 600)) { try await client.search(.generic("x")) }
        #expect(clock.sleeps.isEmpty)
        #expect(transport.searchRequests.count == 1)
    }

    @Test func retriesTimeoutsThenReportsTimeout() async throws {
        let transport = FakeIndexerTransport { request, _ in
            if request.url.queryValue("t") == "caps" { return IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("caps.xml")) }
            throw URLError(.timedOut)
        }
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock)
        await #expect(throws: IndexerError.timeout) { try await client.search(.generic("x")) }
        #expect(transport.searchRequests.count == 3)
        #expect(clock.sleeps == [1, 2])
    }

    @Test func non429ClientErrorsDoNotRetry() async throws {
        let transport = scripted([response(400)])
        let clock = FakeIndexerClock()
        let client = makeClient(transport: transport, clock: clock)
        await #expect(throws: IndexerError.httpStatus(400)) { try await client.search(.generic("x")) }
        #expect(transport.searchRequests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }
}

struct IndexerClientRateLimitTests {
    private func transport() -> FakeIndexerTransport {
        FakeIndexerTransport(search: IndexerFixtures.data("empty-results.xml"))
    }

    @Test func sequentialRequestsAreSpacedByMinInterval() async throws {
        let clock = FakeIndexerClock()
        let def = makeDefinition(rateLimit: IndexerRateLimit(minInterval: 2, burst: 1))
        let client = makeClient(def, transport: transport(), clock: clock)
        _ = try await client.search(.generic("a"))  // caps (free) + search (waits 2)
        _ = try await client.search(.generic("b"))  // waits 2
        #expect(clock.sleeps == [2, 2])
    }

    @Test func burstAllowsImmediateRequests() async throws {
        let clock = FakeIndexerClock()
        let def = makeDefinition(rateLimit: IndexerRateLimit(minInterval: 5, burst: 3))
        let client = makeClient(def, transport: transport(), clock: clock)
        _ = try await client.search(.generic("a"))  // caps + search use 2 of 3 tokens
        _ = try await client.search(.generic("b"))  // third token
        #expect(clock.sleeps.isEmpty)
        _ = try await client.search(.generic("c"))  // bucket empty
        #expect(clock.sleeps == [5])
    }

    @Test func idleTimeRefillsTokens() async throws {
        let clock = FakeIndexerClock()
        let def = makeDefinition(rateLimit: IndexerRateLimit(minInterval: 2, burst: 1))
        let client = makeClient(def, transport: transport(), clock: clock)
        _ = try await client.capabilities()
        clock.advance(by: 10)
        _ = try await client.search(.generic("a"))
        #expect(clock.sleeps.isEmpty)
    }

    @Test func concurrentRequestsAreStaggered() async throws {
        let clock = FakeIndexerClock()
        let def = makeDefinition(rateLimit: IndexerRateLimit(minInterval: 2, burst: 1))
        let client = makeClient(def, transport: transport(), clock: clock)
        _ = try await client.capabilities()
        async let a = client.search(.generic("a"))
        async let b = client.search(.generic("b"))
        _ = try await (a, b)
        #expect(clock.sleeps.count == 2)
        #expect(clock.sleeps.allSatisfy { $0 >= 2 })
    }

    @Test func retriesAlsoConsumeRateLimitTokens() async throws {
        let clock = FakeIndexerClock()
        let t = FakeIndexerTransport { request, n in
            if request.url.queryValue("t") == "caps" { return IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("caps.xml")) }
            return n == 2 ? response(503) : IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("empty-results.xml"))
        }
        let def = makeDefinition(rateLimit: IndexerRateLimit(minInterval: 10, burst: 1))
        let client = makeClient(def, transport: t, clock: clock)
        _ = try await client.search(.generic("a"))
        // caps free; search #1 waits 10; 503 -> backoff 1s; retry waits for the next token (9s more)
        #expect(clock.sleeps == [10, 1, 9])
    }

    @Test func retryAfterBlocksFurtherRequests() async throws {
        let clock = FakeIndexerClock()
        let t = FakeIndexerTransport { request, n in
            if request.url.queryValue("t") == "caps" { return IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("caps.xml")) }
            return n == 2 ? response(429, ["Retry-After": "20"]) : IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data("empty-results.xml"))
        }
        let client = makeClient(transport: t, clock: clock) { $0.backoffMax = 30 }
        _ = try await client.search(.generic("a"))
        #expect(clock.sleeps == [20])
    }

    @Test func updatingRateLimitTakesEffect() async throws {
        let clock = FakeIndexerClock()
        var def = makeDefinition(rateLimit: IndexerRateLimit(minInterval: 100, burst: 1))
        let client = makeClient(def, transport: transport(), clock: clock)
        _ = try await client.capabilities()
        def.rateLimit = .unlimited
        await client.update(definition: def)
        _ = try await client.search(.generic("a"))
        #expect(clock.sleeps.isEmpty)
    }
}
