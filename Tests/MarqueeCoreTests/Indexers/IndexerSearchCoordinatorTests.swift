import Foundation
import Synchronization
import Testing
@testable import MarqueeCore

private func ok(_ fixture: String) -> IndexerHTTPResponse {
    IndexerHTTPResponse(statusCode: 200, body: IndexerFixtures.data(fixture))
}

/// Routes by host: `routes[host]` decides the reply for search requests; caps always succeed.
private func routedTransport(
    _ routes: [String: @Sendable () async throws -> IndexerHTTPResponse]
) -> FakeIndexerTransport {
    FakeIndexerTransport { request, _ in
        if request.url.queryValue("t") == "caps" { return ok("caps.xml") }
        guard let route = routes[request.url.host ?? ""] else { return IndexerHTTPResponse(statusCode: 404) }
        return try await route()
    }
}

private func makeCoordinator(
    _ definitions: [IndexerDefinition], transport: FakeIndexerTransport,
    timeout: TimeInterval = 5, threshold: Int = 3
) async -> IndexerSearchCoordinator {
    var clientConfig = IndexerClientConfiguration()
    clientConfig.maxAttempts = 1
    let coordinator = IndexerSearchCoordinator(
        secrets: makeSecrets(for: definitions), transport: transport,
        clientConfiguration: clientConfig,
        configuration: IndexerCoordinatorConfiguration(perIndexerTimeout: timeout, failureThreshold: threshold))
    await coordinator.setIndexers(definitions)
    return coordinator
}

@Suite(.timeLimit(.minutes(1)))
struct IndexerSearchCoordinatorTests {
    @Test func mergesDedupesAndSortsAcrossIndexers() async throws {
        let a = makeDefinition(name: "Alpha", host: "a.example.invalid", priority: 10)
        let b = makeDefinition(name: "Beta", host: "b.example.invalid", priority: 20)
        let transport = routedTransport([
            "a.example.invalid": { ok("tv-results.xml") },
            "b.example.invalid": { ok("tv-results.xml") },
        ])
        let coordinator = await makeCoordinator([a, b], transport: transport)

        let result = await coordinator.search(.tv(title: "Example Show", season: 1, tvdbID: 81189))

        #expect(result.outcomes.count == 2)
        #expect(result.succeededCount == 2)
        #expect(result.releases.count == 4)
        #expect(result.duplicatesRemoved == 4)
        #expect(result.releases.map(\.seeders) == [152, 8, 0, nil])
        // Same seeders everywhere, so the higher-priority indexer (lower number) wins.
        #expect(result.releases.allSatisfy { $0.indexerID == a.id })
        #expect(result.releases.allSatisfy { $0.alsoFoundOn == [b.id] })
    }

    @Test func oneFailingIndexerDoesNotBreakTheSearch() async throws {
        let good = makeDefinition(name: "Good", host: "good.example.invalid")
        let bad = makeDefinition(name: "Bad", host: "bad.example.invalid")
        let transport = routedTransport([
            "good.example.invalid": { ok("movie-results.xml") },
            "bad.example.invalid": { IndexerHTTPResponse(statusCode: 503) },
        ])
        let coordinator = await makeCoordinator([good, bad], transport: transport)

        let result = await coordinator.search(.movie(title: "Example Movie", imdbID: "tt1375666"))

        #expect(result.releases.count == 2)
        #expect(result.succeededCount == 1)
        #expect(result.failedCount == 1)
        let failure = try #require(result.outcomes.first { $0.indexerID == bad.id })
        #expect(failure.status == .failure(.serverError(status: 503)))
        let success = try #require(result.outcomes.first { $0.indexerID == good.id })
        #expect(success.status == .success(releaseCount: 2))
        #expect(success.latency >= 0)
    }

    @Test func searchesRunInParallel() async throws {
        let defs = (0..<4).map { makeDefinition(name: "I\($0)", host: "h\($0).example.invalid") }
        let routes = Dictionary(uniqueKeysWithValues: defs.map { d in
            (d.baseURL.host!, { @Sendable () async throws -> IndexerHTTPResponse in
                try await Task.sleep(for: .milliseconds(300))
                return ok("empty-results.xml")
            })
        })
        let coordinator = await makeCoordinator(defs, transport: routedTransport(routes))
        let start = ContinuousClock.now
        let result = await coordinator.search(.generic("x"))
        let elapsed = ContinuousClock.now - start
        #expect(result.succeededCount == 4)
        #expect(elapsed < .milliseconds(1100), "four 300ms searches should overlap, took \(elapsed)")
    }

    @Test func slowIndexerTimesOutWithoutBlockingOthers() async throws {
        let fast = makeDefinition(name: "Fast", host: "fast.example.invalid")
        let slow = makeDefinition(name: "Slow", host: "slow.example.invalid")
        let transport = routedTransport([
            "fast.example.invalid": { ok("movie-results.xml") },
            "slow.example.invalid": {
                try await Task.sleep(for: .seconds(60))
                return ok("movie-results.xml")
            },
        ])
        let coordinator = await makeCoordinator([fast, slow], transport: transport, timeout: 0.3)
        let start = ContinuousClock.now
        let result = await coordinator.search(.generic("x"))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(result.outcomes.first { $0.indexerID == slow.id }?.status == .failure(.timeout))
        #expect(result.releases.count == 2)
    }

    @Test func disabledIndexersAreSkippedAndFiltersApply() async throws {
        let on = makeDefinition(name: "On", host: "on.example.invalid", tags: ["tv"])
        let off = makeDefinition(name: "Off", host: "off.example.invalid", enabled: false)
        let other = makeDefinition(name: "Other", host: "other.example.invalid", tags: ["movies"])
        let transport = routedTransport([
            "on.example.invalid": { ok("empty-results.xml") },
            "off.example.invalid": { ok("empty-results.xml") },
            "other.example.invalid": { ok("empty-results.xml") },
        ])
        let coordinator = await makeCoordinator([on, off, other], transport: transport)

        #expect(await coordinator.search(.generic("x")).outcomes.count == 2)
        #expect(await coordinator.search(.generic("x"), tags: ["tv"]).outcomes.map(\.indexerID) == [on.id])
        #expect(await coordinator.search(.generic("x"), indexerIDs: [other.id]).outcomes.map(\.indexerID) == [other.id])
        #expect(!transport.requests.contains { $0.url.host == "off.example.invalid" })
    }

    @Test func noEnabledIndexersGivesEmptyResult() async throws {
        let coordinator = await makeCoordinator([], transport: routedTransport([:]))
        let result = await coordinator.search(.generic("x"))
        #expect(result.releases.isEmpty)
        #expect(result.outcomes.isEmpty)
    }

    @Test func unsupportedSearchIsReportedButNotCountedAgainstHealth() async throws {
        let basic = makeDefinition(name: "Basic", host: "basic.example.invalid")
        let transport = FakeIndexerTransport { request, _ in
            request.url.queryValue("t") == "caps" ? ok("caps-basic.xml") : ok("empty-results.xml")
        }
        let coordinator = await makeCoordinator([basic], transport: transport, threshold: 1)
        let result = await coordinator.search(.tv(tvdbID: 1))
        guard case .failure(.unsupportedSearch) = result.outcomes[0].status else {
            Issue.record("expected unsupportedSearch, got \(result.outcomes[0].status)")
            return
        }
        let health = try #require(await coordinator.health(for: basic.id))
        #expect(health.consecutiveFailures == 0)
        #expect(!health.isAutoDisabled)
    }

    // MARK: Health

    @Test func healthTracksSuccessesAndConsecutiveFailures() async throws {
        let d = makeDefinition(host: "flaky.example.invalid")
        let failing = Mutex(true)
        let transport = routedTransport([
            "flaky.example.invalid": {
                failing.withLock { $0 } ? IndexerHTTPResponse(statusCode: 500) : ok("empty-results.xml")
            }
        ])
        let coordinator = await makeCoordinator([d], transport: transport, threshold: 10)

        _ = await coordinator.search(.generic("x"))
        _ = await coordinator.search(.generic("x"))
        var health = try #require(await coordinator.health(for: d.id))
        #expect(health.consecutiveFailures == 2)
        #expect(health.totalFailures == 2)
        #expect(health.lastError == .serverError(status: 500))

        failing.withLock { $0 = false }
        _ = await coordinator.search(.generic("x"))
        health = try #require(await coordinator.health(for: d.id))
        #expect(health.consecutiveFailures == 0)
        #expect(health.totalFailures == 2)
        #expect(health.totalQueries == 3)
        #expect(health.lastSuccess != nil)
        #expect(health.lastLatency != nil)
        #expect(health.averageLatency != nil)
    }

    @Test func autoDisablesAfterConsecutiveFailuresAndEmitsEvent() async throws {
        let d = makeDefinition(name: "Doomed", host: "doomed.example.invalid")
        let transport = routedTransport(["doomed.example.invalid": { IndexerHTTPResponse(statusCode: 502) }])
        let coordinator = await makeCoordinator([d], transport: transport, threshold: 3)
        let events = await coordinator.events()

        for _ in 0..<3 { _ = await coordinator.search(.generic("x")) }

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .autoDisabled(
            indexerID: d.id, name: "Doomed", consecutiveFailures: 3, lastError: .serverError(status: 502)))

        let health = try #require(await coordinator.health(for: d.id))
        #expect(health.isAutoDisabled)
        #expect(await coordinator.indexers.first?.enabled == false)

        // Skipped from now on.
        let before = transport.searchRequests.count
        let result = await coordinator.search(.generic("x"))
        #expect(result.outcomes.isEmpty)
        #expect(transport.searchRequests.count == before)
    }

    @Test func eventEmittedExactlyOncePerDisable() async throws {
        let d = makeDefinition(host: "doomed.example.invalid")
        let transport = routedTransport(["doomed.example.invalid": { IndexerHTTPResponse(statusCode: 500) }])
        let coordinator = await makeCoordinator([d], transport: transport, threshold: 2)
        let events = await coordinator.events()
        for _ in 0..<5 { _ = await coordinator.search(.generic("x")) }
        await coordinator.reenable(id: d.id)

        var iterator = events.makeAsyncIterator()
        guard case .autoDisabled? = await iterator.next() else { Issue.record("expected autoDisabled"); return }
        guard case .reenabled? = await iterator.next() else { Issue.record("expected reenabled"); return }
    }

    @Test func successResetsStreakSoNoAutoDisable() async throws {
        let d = makeDefinition(host: "x.example.invalid")
        let calls = Mutex(0)
        let transport = routedTransport([
            "x.example.invalid": {
                let n = calls.withLock { $0 += 1; return $0 }
                return n % 3 == 0 ? ok("empty-results.xml") : IndexerHTTPResponse(statusCode: 500)
            }
        ])
        let coordinator = await makeCoordinator([d], transport: transport, threshold: 3)
        for _ in 0..<9 { _ = await coordinator.search(.generic("x")) }
        let health = try #require(await coordinator.health(for: d.id))
        #expect(!health.isAutoDisabled)
        #expect(health.totalFailures == 6)
    }

    @Test func reenableClearsStreakAndResumesSearching() async throws {
        let d = makeDefinition(host: "r.example.invalid")
        let failing = Mutex(true)
        let transport = routedTransport([
            "r.example.invalid": { failing.withLock { $0 } ? IndexerHTTPResponse(statusCode: 500) : ok("movie-results.xml") }
        ])
        let coordinator = await makeCoordinator([d], transport: transport, threshold: 2)
        for _ in 0..<2 { _ = await coordinator.search(.generic("x")) }
        #expect(try #require(await coordinator.health(for: d.id)).isAutoDisabled)

        failing.withLock { $0 = false }
        await coordinator.reenable(id: d.id)
        let result = await coordinator.search(.generic("x"))
        #expect(result.releases.count == 2)
        let health = try #require(await coordinator.health(for: d.id))
        #expect(!health.isAutoDisabled)
        #expect(health.consecutiveFailures == 0)
    }

    @Test func userReenablingViaUpsertResetsAutoDisabledState() async throws {
        let d = makeDefinition(host: "u.example.invalid")
        let transport = routedTransport(["u.example.invalid": { IndexerHTTPResponse(statusCode: 500) }])
        let coordinator = await makeCoordinator([d], transport: transport, threshold: 1)
        _ = await coordinator.search(.generic("x"))
        #expect(try #require(await coordinator.health(for: d.id)).isAutoDisabled)
        var edited = d
        edited.enabled = true
        await coordinator.upsert(edited)
        #expect(!(try #require(await coordinator.health(for: d.id)).isAutoDisabled))
    }

    @Test func setIndexersRemovesMissingAndKeepsHealthOfExisting() async throws {
        let a = makeDefinition(name: "A", host: "a.example.invalid")
        let b = makeDefinition(name: "B", host: "b.example.invalid")
        let transport = routedTransport([
            "a.example.invalid": { IndexerHTTPResponse(statusCode: 500) },
            "b.example.invalid": { ok("empty-results.xml") },
        ])
        let coordinator = await makeCoordinator([a, b], transport: transport, threshold: 10)
        _ = await coordinator.search(.generic("x"))
        await coordinator.setIndexers([a])
        #expect(await coordinator.indexers.map(\.id) == [a.id])
        #expect(await coordinator.health(for: a.id)?.consecutiveFailures == 1)
        #expect(await coordinator.health(for: b.id) == nil)
    }

    // MARK: Test all

    @Test func testAllReportsEachIndexerAndLeavesHealthAlone() async throws {
        let good = makeDefinition(name: "Good", host: "good.example.invalid")
        let bad = makeDefinition(name: "Bad", host: "bad.example.invalid")
        let transport = routedTransport([
            "good.example.invalid": { ok("tv-results.xml") },
            "bad.example.invalid": { ok("error-response.xml") },
        ])
        let coordinator = await makeCoordinator([good, bad], transport: transport)
        let outcomes = await coordinator.testAll()
        #expect(outcomes.map(\.indexerName) == ["Bad", "Good"])
        guard case .failure(.authenticationFailed) = outcomes[0].result else { Issue.record("expected auth failure"); return }
        guard case .success(let ok) = outcomes[1].result else { Issue.record("expected success"); return }
        #expect(ok.sampleReleaseCount == 4)
        #expect(await coordinator.health(for: bad.id)?.totalQueries == 0)
    }
}

struct ReleaseDeduplicatorTests {
    let idA = UUID()
    let idB = UUID()
    let hash = "c9e15763f722f23e98a29decdfae341b98d53056"

    @Test func mergesSameInfoHashKeepingMostSeeded() {
        let low = makeRelease(indexer: idA, title: "Show S01E01 1080p", hash: hash, seeders: 5)
        let high = makeRelease(indexer: idB, title: "Show.S01E01.1080p", hash: hash.uppercased(), seeders: 50)
        let (out, removed) = ReleaseDeduplicator.deduplicate([low, high])
        #expect(removed == 1)
        #expect(out.count == 1)
        #expect(out[0].indexerID == idB)
        #expect(out[0].alsoFoundOn == [idA])
    }

    @Test func mergesByNormalizedTitleAndSizeWhenHashMissing() {
        let a = makeRelease(indexer: idA, title: "Show.S01E01.1080p.WEB-DL", size: 5000)
        let b = makeRelease(indexer: idB, title: "show s01e01 1080p web-dl", size: 5000)
        let (out, removed) = ReleaseDeduplicator.deduplicate([a, b])
        #expect(removed == 1)
        #expect(out.count == 1)
    }

    @Test func sameTitleDifferentSizeIsKept() {
        let a = makeRelease(indexer: idA, title: "Show S01E01", size: 5000)
        let b = makeRelease(indexer: idB, title: "Show S01E01", size: 6000)
        #expect(ReleaseDeduplicator.deduplicate([a, b]).releases.count == 2)
    }

    @Test func differentHashesNeverMergeEvenWithSameTitleAndSize() {
        let a = makeRelease(indexer: idA, title: "Show S01E01", hash: hash, size: 5000)
        let b = makeRelease(indexer: idB, title: "Show S01E01", hash: String(repeating: "ab", count: 20), size: 5000)
        #expect(ReleaseDeduplicator.deduplicate([a, b]).releases.count == 2)
    }

    @Test func hashlessReleaseJoinsHashedGroupAndSurvivorGetsTheHash() {
        let hashed = makeRelease(indexer: idA, title: "Show S01E01", hash: hash, size: 5000, seeders: 1)
        let plain = makeRelease(indexer: idB, title: "Show S01E01", hash: nil, size: 5000, seeders: 99)
        let (out, _) = ReleaseDeduplicator.deduplicate([hashed, plain])
        #expect(out.count == 1)
        #expect(out[0].indexerID == idB)
        #expect(out[0].infoHash == hash)
    }

    @Test func tieOnSeedersFallsBackToIndexerPriority() {
        let a = makeRelease(indexer: idA, hash: hash, seeders: 10)
        let b = makeRelease(indexer: idB, hash: hash, seeders: 10)
        let out = ReleaseDeduplicator.deduplicate([a, b], priority: { $0 == idB ? 1 : 50 }).releases
        #expect(out[0].indexerID == idB)
    }

    @Test func normalizedTitleFoldsCaseDiacriticsAndPunctuation() {
        #expect(ReleaseDeduplicator.normalizedTitle("Pokémon.S01E01_[1080p]") == "pokemon s01e01 1080p")
        #expect(ReleaseDeduplicator.normalizedTitle("  A--B  ") == "a b")
    }

    @Test func sortBySeedersPutsUnknownLastAndBreaksTies() {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let a = makeRelease(indexer: idA, title: "a", seeders: nil)
        let b = makeRelease(indexer: idA, title: "b", seeders: 5, date: older)
        let c = makeRelease(indexer: idA, title: "c", seeders: 5, date: newer)
        let d = makeRelease(indexer: idB, title: "d", seeders: 5, date: older)
        let e = makeRelease(indexer: idA, title: "e", seeders: 100)
        let sorted = ReleaseDeduplicator.sortBySeeders([a, b, c, d, e], priority: { $0 == idB ? 1 : 25 })
        #expect(sorted.map(\.title) == ["e", "d", "c", "b", "a"])
    }

    @Test func emptyAndSingleInputs() {
        #expect(ReleaseDeduplicator.deduplicate([]).releases.isEmpty)
        let one = makeRelease()
        #expect(ReleaseDeduplicator.deduplicate([one]).releases == [one])
    }
}
