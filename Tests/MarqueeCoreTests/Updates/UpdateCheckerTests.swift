import CryptoKit
import Foundation
import Testing
@testable import MarqueeCore

/// The checker's job is mostly restraint: once a day, not on every launch, and never two requests
/// at once. An updater that wakes the app daily to find nothing has quietly become a battery cost.
@Suite("Update checker")
struct UpdateCheckerTests {
    private func makeChecker(
        transport: UpdatesStubTransport,
        clock: UpdatesTestClock,
        key: Curve25519.Signing.PrivateKey,
        current: String = "0.1.28",
        interval: TimeInterval = UpdateChecker.defaultInterval,
        retryInterval: TimeInterval = UpdateChecker.retryInterval
    ) throws -> (UpdateChecker, UpdatePreferences, String) {
        let (preferences, defaults, suite) = try makeUpdatesPreferences()
        let checker = UpdateChecker(
            currentVersion: UpdateVersion(current),
            keyring: UpdatesSigning.keyring(key),
            transport: transport,
            preferences: preferences,
            clock: clock,
            interval: interval,
            retryInterval: retryInterval)
        return (checker, preferences, suite)
    }

    private func signedRoutes(
        _ releases: [AppcastRelease], key: Curve25519.Signing.PrivateKey,
        etag: String? = "\"v1\""
    ) throws -> [String: UpdateHTTPResponse] {
        let (manifest, signature) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: releases), key: key)
        return [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, etag: etag, body: manifest),
            UpdatesHost.signaturePath: UpdateHTTPResponse(
                statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
        ]
    }

    @Test func theFirstCheckOffersTheNewestRelease() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let transport = UpdatesStubTransport(routes: try signedRoutes(
            [UpdatesManifest.release("0.1.30"), UpdatesManifest.release("0.1.29")], key: key))
        let (checker, _, suite) = try makeChecker(transport: transport, clock: UpdatesTestClock(), key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let result = try await checker.check()
        #expect(result.release?.version == UpdateVersion("0.1.30"))
        #expect(transport.requestedPaths == ["/appcast.json", UpdatesHost.signaturePath])
    }

    @Test func aSecondCheckInTheSameDayDoesNotTouchTheNetwork() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let transport = UpdatesStubTransport(routes: try signedRoutes(
            [UpdatesManifest.release("0.1.30")], key: key))
        let clock = UpdatesTestClock()
        let (checker, _, suite) = try makeChecker(transport: transport, clock: clock, key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        _ = try await checker.check()
        let afterFirst = transport.requests.count

        _ = try await checker.check()
        #expect(transport.requests.count == afterFirst, "the throttle must suppress a same-day check")

        clock.advance(by: UpdateChecker.defaultInterval + 1)
        _ = try await checker.check()
        #expect(transport.requests.count == afterFirst * 2)
    }

    @Test func aForcedCheckIgnoresTheThrottle() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let transport = UpdatesStubTransport(routes: try signedRoutes(
            [UpdatesManifest.release("0.1.30")], key: key))
        let (checker, _, suite) = try makeChecker(transport: transport, clock: UpdatesTestClock(), key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        _ = try await checker.check()
        let afterFirst = transport.requests.count
        _ = try await checker.check(force: true)
        #expect(transport.requests.count == afterFirst * 2)
    }

    @Test func theETagIsSentBackAndReplacedOnEveryAcceptedManifest() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let routes = try signedRoutes([UpdatesManifest.release("0.1.30")], key: key)
        let transport = UpdatesStubTransport(routes: routes)
        let clock = UpdatesTestClock()
        let (checker, preferences, suite) = try makeChecker(transport: transport, clock: clock, key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        _ = try await checker.check()
        #expect(preferences.etag == "\"v1\"")
        #expect(transport.requests.first?.etag == nil, "the first request has nothing cached to send")

        clock.advance(by: UpdateChecker.defaultInterval + 1)
        _ = try await checker.check(force: true)
        let sentETags = transport.requests.compactMap(\.etag)
        #expect(sentETags.contains("\"v1\""))
    }

    @Test func anUnchangedManifestReportsTheVersionItAlreadyKnows() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let clock = UpdatesTestClock()
        let (preferences, _, suite) = try makeUpdatesPreferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        func checker(with transport: UpdatesStubTransport) -> UpdateChecker {
            UpdateChecker(
                currentVersion: UpdateVersion("0.1.28"),
                keyring: UpdatesSigning.keyring(key),
                transport: transport,
                preferences: preferences,
                clock: clock)
        }

        let first = UpdatesStubTransport(routes: try signedRoutes(
            [UpdatesManifest.release("0.1.30")], key: key))
        _ = try await checker(with: first).check()

        clock.advance(by: UpdateChecker.defaultInterval + 1)
        // The server now answers 304 for everything, as a real host would.
        let notModified = UpdatesStubTransport(
            routes: ["/appcast.json": UpdateHTTPResponse(statusCode: 304)])

        let result = try await checker(with: notModified).check()
        #expect(result == .upToDate(latest: UpdateVersion("0.1.30")))
        #expect(notModified.requests.count == 1, "a 304 must not trigger a signature fetch")
    }

    @Test func aFailureCoolsDownFasterThanASuccess() async throws {
        let failing = UpdatesStubTransport { _ in throw UpdateError.network("offline") }
        let clock = UpdatesTestClock()
        let (checker, preferences, suite) = try makeChecker(transport: failing, clock: clock, key: Curve25519.Signing.PrivateKey())
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(isUpdateError(await updatesError { try await checker.check() }) { _ in true })
        // Still inside the day-long interval, but past the failure cooldown.
        clock.advance(by: UpdateChecker.retryInterval + 1)
        #expect(await checker.isDue())
        clock.advance(by: -(UpdateChecker.retryInterval + 1))
        clock.advance(by: UpdateChecker.retryInterval / 2)
        #expect(await checker.isDue() == false, "a retry must not be due half an hour after failing")
        #expect(preferences.lastCheckAt != nil)
    }

    @Test func aFailedCheckStillCountsAsAnAttemptSoAnOfflineMacStaysQuiet() async throws {
        let failing = UpdatesStubTransport { _ in throw UpdateError.network("offline") }
        let clock = UpdatesTestClock()
        let (checker, preferences, suite) = try makeChecker(transport: failing, clock: clock, key: Curve25519.Signing.PrivateKey())
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(isUpdateError(await updatesError { try await checker.check() }) { _ in true })
        #expect(preferences.lastSuccessAt == nil)
        // A minute later: not due again, even though nothing has ever succeeded.
        clock.advance(by: 60)
        #expect(await checker.isDue() == false)
    }

    @Test func twoCallersAtOnceShareOneRequest() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let gate = UpdatesGate()
        let routes = try signedRoutes([UpdatesManifest.release("0.1.30")], key: key)
        let transport = UpdatesStubTransport(gate: gate, routes: routes)
        let (checker, _, suite) = try makeChecker(transport: transport, clock: UpdatesTestClock(), key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        async let first = checker.check()
        await gate.waitForArrivals(1)
        async let second = checker.check()
        // The second caller must join the first rather than start its own request.
        try await Task.sleep(for: .milliseconds(50))
        gate.open()

        let results = try await [first, second]
        #expect(results.allSatisfy { $0.release?.version == UpdateVersion("0.1.30") })
        #expect(transport.count(ofPath: "/appcast.json") == 1)
    }

    @Test func aSkippedVersionStopsBeingOffered() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let transport = UpdatesStubTransport(routes: try signedRoutes(
            [UpdatesManifest.release("0.1.30")], key: key))
        let clock = UpdatesTestClock()
        let (checker, _, suite) = try makeChecker(transport: transport, clock: clock, key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(try await checker.check().release?.version == UpdateVersion("0.1.30"))
        await checker.skip(UpdateVersion("0.1.30"))
        clock.advance(by: UpdateChecker.defaultInterval + 1)
        #expect(try await checker.check().release == nil)
    }

    @Test func aStablePreferenceHidesBetas() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let transport = UpdatesStubTransport(routes: try signedRoutes(
            [UpdatesManifest.release("0.1.30", channel: .beta)], key: key))
        let clock = UpdatesTestClock()
        let (checker, preferences, suite) = try makeChecker(transport: transport, clock: clock, key: key)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(try await checker.check().release?.version == UpdateVersion("0.1.30"))
        preferences.includeBetaReleases = false
        clock.advance(by: UpdateChecker.defaultInterval + 1)
        #expect(try await checker.check().release == nil)
    }
}