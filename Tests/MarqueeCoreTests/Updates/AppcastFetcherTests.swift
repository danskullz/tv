import CryptoKit
import Foundation
import Testing
@testable import MarqueeCore

/// Where the manifest turns into something the app is willing to act on. The rules here are all
/// refusals, which is the point: the host is trusted for nothing.
@Suite("Appcast fetcher")
struct AppcastFetcherTests {
    private func fetcher(
        transport: UpdatesStubTransport,
        key: Curve25519.Signing.PrivateKey? = nil,
        origin: URL = UpdatesHost.origin
    ) -> AppcastFetcher {
        let signingKey = key ?? Curve25519.Signing.PrivateKey()
        // Each call needs the same key, so callers that verify pass one in explicitly.
        return AppcastFetcher(
            transport: transport,
            keyring: UpdatesSigning.keyring(signingKey),
            origin: origin)
    }

    private func routes(
        for appcast: Appcast,
        key: Curve25519.Signing.PrivateKey,
        manifestPath: String = UpdatesHost.signaturePath.replacingOccurrences(of: ".sig", with: ""),
        signaturePath: String = UpdatesHost.signaturePath,
        etag: String? = "\"abc\""
    ) throws -> [String: UpdateHTTPResponse] {
        let (manifest, signature) = try UpdatesSigning.signed(appcast, key: key)
        return [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, etag: etag, body: manifest),
            "/\(manifestPath.replacingOccurrences(of: "/", with: ""))":
                UpdateHTTPResponse(statusCode: 200, body: manifest),
            signaturePath: UpdateHTTPResponse(
                statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
        ]
    }

    @Test func aSignedManifestIsFetchedAndVerified() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let appcast = UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")])
        let (manifest, signature) = try UpdatesSigning.signed(appcast, key: key)
        let transport = UpdatesStubTransport(routes: [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, etag: "\"v1\"", body: manifest),
            UpdatesHost.signaturePath: UpdateHTTPResponse(
                statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
        ])

        let result = try await fetcher(transport: transport, key: key).fetch(manifestURL: UpdatesHost.feed)

        guard case .verified(let decoded, let etag) = result else {
            Issue.record("expected a verified manifest, got \(result)")
            return
        }
        #expect(decoded.releases.map(\.version.description) == ["0.1.30"])
        #expect(etag == "\"v1\"")
        #expect(transport.requestedPaths == ["/appcast.json", UpdatesHost.signaturePath])
    }

    @Test func anUnchangedManifestComesBackAsNotModified() async throws {
        let transport = UpdatesStubTransport(routes: ["/appcast.json": UpdateHTTPResponse(statusCode: 304)])
        let result = try await fetcher(transport: transport).fetch(manifestURL: UpdatesHost.feed, etag: "\"v1\"")
        #expect(result == .notModified)
        // A 304 must not cost a second request for a signature that did not change.
        #expect(transport.requestedPaths == ["/appcast.json"])
        #expect(transport.requests.first?.etag == "\"v1\"")
    }

    @Test func aMissingFeedIsNotFoundAndAServerProblemIsReported() async throws {
        let missing = UpdatesStubTransport(routes: ["/appcast.json": UpdateHTTPResponse(statusCode: 404)])
        #expect(isUpdateError(await updatesError { try await fetcher(transport: missing).fetch(manifestURL: UpdatesHost.feed) }) { $0 == .notFound })
        let broken = UpdatesStubTransport(routes: ["/appcast.json": UpdateHTTPResponse(statusCode: 503)])
        #expect(isUpdateError(await updatesError { try await fetcher(transport: broken).fetch(manifestURL: UpdatesHost.feed) }) { $0 == .httpStatus(503) })
    }

    @Test func anUnsignedManifestIsRefusedAndNeverParsed() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let (_, signature) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")]), key: key)
        // Correct shape, wrong signer.
        let other = Curve25519.Signing.PrivateKey()
        let (manifest, _) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.99")]), key: other)
        let transport = UpdatesStubTransport(routes: [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, body: manifest),
            UpdatesHost.signaturePath: UpdateHTTPResponse(
                statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
        ])

        #expect(isUpdateError(await updatesError { try await fetcher(transport: transport, key: key).fetch(manifestURL: UpdatesHost.feed) }) { $0 == .badSignature(keyID: UpdatesManifest.keyID) })
    }

    @Test func aMissingSignatureIsItsOwnFailure() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let (manifest, _) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")]), key: key)
        let transport = UpdatesStubTransport(routes: [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, body: manifest),
        ])
        #expect(isUpdateError(await updatesError { try await fetcher(transport: transport, key: key).fetch(manifestURL: UpdatesHost.feed) }) { $0 == .missingSignature })
    }

    @Test func aPlaintextOrForeignHostIsRefused() async throws {
        let plaintext = UpdatesStubTransport()
        #expect(isUpdateError(await updatesError { try await fetcher(transport: plaintext)
                .fetch(manifestURL: URL(string: "http://tv.guihot.net/appcast.json")!) }) { $0 == .insecureURL("http://tv.guihot.net/appcast.json") })
        let foreign = UpdatesStubTransport()
        #expect(isUpdateError(await updatesError { try await fetcher(transport: foreign)
                .fetch(manifestURL: URL(string: "https://evil.example/appcast.json")!) }) { _ in true })
        // Neither ever reached the network.
        #expect(plaintext.requests.isEmpty)
        #expect(foreign.requests.isEmpty)
    }

    @Test func aSignatureURLPointingElsewhereIsNotFetched() async throws {
        let key = Curve25519.Signing.PrivateKey()
        // The signed manifest names a signature on another host. The bytes are still untrusted at
        // this point, so the hint must not be able to aim the fetch off-origin.
        let appcast = UpdatesManifest.appcast(
            releases: [UpdatesManifest.release("0.1.30")],
            signatureURL: URL(string: "https://attacker.example/appcast.sig"))
        let (manifest, signature) = try UpdatesSigning.signed(appcast, key: key)
        let transport = UpdatesStubTransport(routes: [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, body: manifest),
            // Reachable, but only at the deterministic fallback path.
            UpdatesHost.fallbackSignaturePath: UpdateHTTPResponse(
                statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
        ])

        // Falls back to the deterministic <manifest>.sig, which verifies.
        let result = try await fetcher(transport: transport, key: key).fetch(manifestURL: UpdatesHost.feed)
        guard case .verified = result else {
            Issue.record("expected the on-origin fallback to be used, got \(result)")
            return
        }
        #expect(transport.hostsRequested == ["tv.guihot.net"])
        #expect(transport.requestedPaths == ["/appcast.json", UpdatesHost.fallbackSignaturePath])
    }

    @Test func anUnreadableManifestFallsBackToTheDerivedSignaturePath() async throws {
        let key = Curve25519.Signing.PrivateKey()
        // Not a manifest at all, but genuinely signed — so the signature checks out and the failure
        // is about the content rather than about where the signature came from.
        let bytes = Data("not a manifest".utf8)
        let signature = try UpdatesSigning.signature(of: bytes, key: key)
        let transport = UpdatesStubTransport(routes: [
            "/appcast.json": UpdateHTTPResponse(statusCode: 200, body: bytes),
            "/appcast.json.sig": UpdateHTTPResponse(
                statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
        ])

        #expect(await updatesError { try await fetcher(transport: transport, key: key).fetch(manifestURL: UpdatesHost.feed) } != nil)
        #expect(transport.requestedPaths == ["/appcast.json", "/appcast.json.sig"])
    }

    @Test func aManifestForAnotherSchemaOrAppIsRefusedAfterVerification() async throws {
        let key = Curve25519.Signing.PrivateKey()
        for bad in [
            UpdatesManifest.appcast(releases: [], schema: 2),
            UpdatesManifest.appcast(releases: [], app: "com.example.other"),
        ] {
            let (manifest, signature) = try UpdatesSigning.signed(bad, key: key)
            let transport = UpdatesStubTransport(routes: [
                "/appcast.json": UpdateHTTPResponse(statusCode: 200, body: manifest),
                UpdatesHost.signaturePath: UpdateHTTPResponse(
                    statusCode: 200, body: try UpdatesSigning.signatureBytes(signature)),
            ])
            #expect(isUpdateError(await updatesError { try await fetcher(transport: transport, key: key).fetch(manifestURL: UpdatesHost.feed) }) { _ in true })
        }
    }
}