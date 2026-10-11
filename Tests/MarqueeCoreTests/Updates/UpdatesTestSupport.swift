import CryptoKit
import Foundation
@testable import MarqueeCore

// Fakes and builders shared by the updater suites. Internal (not private) because all tests share
// one module; every name is `Updates`-prefixed so it can't collide with another area's helpers.

/// The update host every fetcher/checker test pretends to talk to.
enum UpdatesHost {
    static let origin = URL(string: "https://tv.guihot.net")!
    static let feed = URL(string: "https://tv.guihot.net/appcast.json")!
    static let signaturePath = "/appcast-0.1.30.sig"
    /// The deterministic fallback the fetcher derives from the manifest URL itself.
    static let fallbackSignaturePath = "/appcast.json.sig"
}

// MARK: - Manifests

enum UpdatesManifest {
    /// The key ID `scripts/make-appcast.sh` publishes under by default.
    static let keyID = "marquee-2026"

    static func build(
        _ arch: BuildArch,
        version: String = "0.1.30",
        size: Int = 181,
        sha256: String = String(repeating: "a", count: 64)
    ) -> AppcastBuild {
        AppcastBuild(
            arch: arch,
            url: URL(string: "https://tv.guihot.net/downloads/Marquee-\(version)-macos-\(arch.rawValue).zip")!,
            sha256: sha256,
            size: size,
            minOS: "15.0")
    }

    static func release(
        _ version: String,
        channel: UpdateChannel = .beta,
        minimumVersion: String? = nil,
        yanked: Bool = false,
        builds: [AppcastBuild]? = nil
    ) -> AppcastRelease {
        AppcastRelease(
            version: UpdateVersion(version),
            channel: channel,
            publishedAt: Date(timeIntervalSince1970: 1_791_709_200),
            minimumVersion: minimumVersion.map(UpdateVersion.init),
            yanked: yanked,
            notes: "Release \(version).",
            builds: builds ?? [UpdatesManifest.build(.arm64, version: version),
                               UpdatesManifest.build(.x86_64, version: version)])
    }

    static func appcast(
        releases: [AppcastRelease],
        schema: Int = Appcast.supportedSchema,
        app: String = Appcast.bundleIdentifier,
        generatedAt: Date? = Date(timeIntervalSince1970: 1_791_709_200),
        signatureURL: URL? = URL(string: "https://tv.guihot.net/appcast-0.1.30.sig")
    ) -> Appcast {
        Appcast(schema: schema, app: app, generatedAt: generatedAt, signatureURL: signatureURL, releases: releases)
    }

    /// Serialises a manifest the way the publisher does: sorted keys, indented, ISO 8601 dates.
    static func bytes(_ appcast: Appcast) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(appcast)
    }
}

// MARK: - Signing

/// Real Ed25519 keys, generated per test, so nothing about the manifest or the signature is mocked.
enum UpdatesSigning {
    static func keyring(
        _ key: Curve25519.Signing.PrivateKey,
        id: String = UpdatesManifest.keyID
    ) -> AppcastKeyring {
        AppcastKeyring([id: key.publicKey.rawRepresentation])
    }

    /// A keyring holding two keys, as shipped for the duration of a rotation.
    static func rotatingKeyring(
        outgoing: Curve25519.Signing.PrivateKey,
        incoming: Curve25519.Signing.PrivateKey
    ) -> AppcastKeyring {
        AppcastKeyring([
            "marquee-2025": outgoing.publicKey.rawRepresentation,
            "marquee-2026": incoming.publicKey.rawRepresentation,
        ])
    }

    static func signature(
        of manifest: Data,
        key: Curve25519.Signing.PrivateKey,
        id: String = UpdatesManifest.keyID,
        algorithm: String = "ed25519",
        schema: Int = AppcastSignatureFile.supportedSchema
    ) throws -> AppcastSignatureFile {
        AppcastSignatureFile(
            schema: schema,
            keyID: id,
            algorithm: algorithm,
            signedFile: "appcast-0.1.30.json",
            signedSHA256: sha256Hex(manifest),
            signature: try key.signature(for: manifest).base64EncodedString())
    }

    /// The bytes the publisher would serve as `<manifest>.sig`.
    static func signatureBytes(_ signature: AppcastSignatureFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(signature)
    }

    /// A manifest plus the signature over its exact bytes.
    static func signed(
        _ appcast: Appcast,
        key: Curve25519.Signing.PrivateKey,
        id: String = UpdatesManifest.keyID
    ) throws -> (manifest: Data, signature: AppcastSignatureFile) {
        let manifest = try UpdatesManifest.bytes(appcast)
        return (manifest, try signature(of: manifest, key: key, id: id))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Transport

/// A transport that answers from a routing table and records every request it is handed.
final class UpdatesStubTransport: UpdateTransport, @unchecked Sendable {
    typealias Responder = @Sendable (UpdateHTTPRequest) throws -> UpdateHTTPResponse

    private let lock = NSLock()
    private var recorded: [UpdateHTTPRequest] = []
    private let responder: Responder
    /// When set, every request parks here until the test calls `UpdatesGate.open()`.
    let gate: UpdatesGate?

    init(gate: UpdatesGate? = nil, responder: @escaping Responder = { _ in UpdateHTTPResponse(statusCode: 404) }) {
        self.gate = gate
        self.responder = responder
    }

    /// Answers each request by URL path; anything unrouted is a 404, exactly like a real host.
    convenience init(
        gate: UpdatesGate? = nil,
        routes: [String: UpdateHTTPResponse],
        failing error: UpdateError? = nil
    ) {
        self.init(gate: gate) { request in
            if let error { throw error }
            return routes[request.url.path] ?? UpdateHTTPResponse(statusCode: 404)
        }
    }

    var requests: [UpdateHTTPRequest] { lock.withLock { recorded } }
    var requestedPaths: [String] { requests.map(\.url.path) }
    var hostsRequested: Set<String> { Set(requests.compactMap(\.url.host)) }
    func count(ofPath path: String) -> Int { requests.filter { $0.url.path == path }.count }

    func send(_ request: UpdateHTTPRequest) async throws -> UpdateHTTPResponse {
        lock.withLock { recorded.append(request) }
        if let gate { await gate.pass() }
        return try responder(request)
    }
}

/// Holds requests open so a test can be certain two callers were in flight at the same time.
///
/// Every wait is a continuation the test resumes, never a sleep.
final class UpdatesGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals = 0
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// Suspends the caller until `open()`.
    func pass() async {
        let shouldBlock: Bool = lock.withLock {
            if isOpen { return false }
            arrivals += 1
            return true
        }
        // Announce the arrival *before* blocking. Signalling only after `open()` deadlocks against
        // `waitForArrivals`, which is waiting for a count that cannot move until the gate opens.
        signalArrivals()
        guard shouldBlock else { return }
        await withCheckedContinuation { continuation in
            let openedMeanwhile: Bool = lock.withLock {
                if isOpen { return true }
                blocked.append(continuation)
                return false
            }
            if openedMeanwhile { continuation.resume() }
        }
    }

    /// Resolves once `count` requests have reached the transport.
    func waitForArrivals(_ count: Int = 1) async {
        while true {
            let reached: Bool = lock.withLock { arrivals >= count }
            if reached { return }
            await withCheckedContinuation { continuation in
                let reachedNow: Bool = lock.withLock {
                    if arrivals >= count { return true }
                    arrivalWaiters.append(continuation)
                    return false
                }
                if reachedNow { continuation.resume() }
            }
        }
    }

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let pending = blocked
            blocked = []
            return pending
        }
        waiters.forEach { $0.resume() }
    }

    private func signalArrivals() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            let pending = arrivalWaiters
            arrivalWaiters = []
            return pending
        }
        waiters.forEach { $0.resume() }
    }
}

// MARK: - Clock

/// Time the test moves by hand.
final class UpdatesTestClock: UpdateClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_791_709_200)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

// MARK: - Preferences & scratch space

struct UpdatesTestError: Error, CustomStringConvertible {
    let description: String
}

/// A private `UserDefaults` suite, so one test's throttle state never reaches the next.
func makeUpdatesPreferences() throws -> (preferences: UpdatePreferences, defaults: UserDefaults, suite: String) {
    let suite = "MarqueeUpdateTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw UpdatesTestError(description: "could not open a private defaults suite named \(suite)")
    }
    return (UpdatePreferences(defaults: defaults), defaults, suite)
}

/// A throwaway directory that removes itself.
func makeUpdatesScratchDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("marquee-updates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func removeUpdatesScratchDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Matches an `UpdateError` case without pinning its human-readable detail.
func isUpdateError(_ error: Error?, _ predicate: (UpdateError) -> Bool) -> Bool {
    guard let error = error as? UpdateError else { return false }
    return predicate(error)
}

/// Awaits a throwing call and hands back what it threw.
///
/// `#expect(throws:)` has no overload taking an async closure, so the assertion has to happen
/// outside the call. Returns nil when nothing was thrown, which is exactly what makes
/// `isUpdateError(await updatesError { ... })` false for a success.
func updatesError<R>(_ body: () async throws -> R) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}
