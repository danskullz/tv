import CryptoKit
import Foundation
import Testing
@testable import MarqueeCore

/// The signature is the whole trust story: the manifest and the binaries come from the same host,
/// so this check is the only thing between that host and arbitrary code execution.
@Suite("Appcast signature")
struct AppcastSignatureTests {
    @Test func aValidSignatureVerifiesAndReturnsTheSameBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let appcast = UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")])
        let (manifest, signature) = try UpdatesSigning.signed(appcast, key: key)

        let verified = try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(key))
            .verify(manifest: manifest, signature: signature)
        #expect(verified == manifest)
    }

    @Test func oneFlippedByteFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let appcast = UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")])
        let (manifest, signature) = try UpdatesSigning.signed(appcast, key: key)

        // Somewhere in the middle of the JSON, where it changes a version string rather than
        // breaking the parse — a tampered manifest still has to be valid JSON.
        let tampered = Data(manifest.dropLast(2) + Data("} }".utf8))
        #expect(throws: UpdateError.self) {
            try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(key))
                .verify(manifest: tampered, signature: signature)
        }
    }

    @Test func aSignatureFromAKeyWeDoNotHoldIsRefused() throws {
        let theirs = Curve25519.Signing.PrivateKey()
        let ours = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")]),
            key: theirs, id: "marquee-2027")

        // A keyID we have never heard of. A *known* keyID signed by the wrong key is a different
        // failure — a bad signature, not an unknown one — and is covered separately below.
        #expect(throws: UpdateError.unknownKey("marquee-2027")) {
            try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(ours))
                .verify(manifest: manifest, signature: signature)
        }
    }

    @Test func aKnownKeyIDSignedByTheWrongKeyIsABadSignatureNotAnUnknownOne() throws {
        let theirs = Curve25519.Signing.PrivateKey()
        let ours = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")]), key: theirs)

        // Same keyID, different key: the ring resolves it, so this is a forgery attempt rather than
        // a misconfiguration, and it has to fail as one.
        #expect(throws: UpdateError.badSignature(keyID: UpdatesManifest.keyID)) {
            try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(ours))
                .verify(manifest: manifest, signature: signature)
        }
    }

    @Test func anAlgorithmWeDoNotCheckIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (manifest, _) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")]), key: key)
        let signature = try UpdatesSigning.signature(
            of: manifest, key: key, algorithm: "rsa-sha512")

        #expect(throws: UpdateError.unsupportedAlgorithm("rsa-sha512")) {
            try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(key))
                .verify(manifest: manifest, signature: signature)
        }
    }

    @Test func aSignatureOfTheWrongLengthIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (manifest, signature) = try UpdatesSigning.signed(
            UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")]), key: key)

        var truncated = signature
        truncated.signature = Data(repeating: 7, count: 63).base64EncodedString()
        #expect(throws: UpdateError.badSignature(keyID: UpdatesManifest.keyID)) {
            try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(key))
                .verify(manifest: manifest, signature: truncated)
        }
        var notBase64 = signature
        notBase64.signature = "!!!not base64!!!"
        #expect(throws: UpdateError.badSignature(keyID: UpdatesManifest.keyID)) {
            try AppcastSignatureVerifier(keyring: UpdatesSigning.keyring(key))
                .verify(manifest: manifest, signature: notBase64)
        }
    }

    @Test func duringARotationBothTheOldAndTheNewKeyAreAccepted() throws {
        let outgoing = Curve25519.Signing.PrivateKey()
        let incoming = Curve25519.Signing.PrivateKey()
        let appcast = UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")])
        let keyring = UpdatesSigning.rotatingKeyring(outgoing: outgoing, incoming: incoming)

        for (key, id) in [(outgoing, "marquee-2025"), (incoming, "marquee-2026")] {
            let (manifest, signature) = try UpdatesSigning.signed(appcast, key: key, id: id)
            let verifier = AppcastSignatureVerifier(keyring: keyring)
            #expect(throws: Never.self) { try verifier.verify(manifest: manifest, signature: signature) }
        }
    }

    @Test func aKeyOfTheWrongLengthIsRefused() {
        let keyring = AppcastKeyring(["marquee-2026": Data(repeating: 1, count: 16)])
        #expect(throws: UpdateError.badSignature(keyID: "marquee-2026")) {
            try keyring.publicKey(for: "marquee-2026")
        }
    }

    /// Proves the format `scripts/make-appcast.sh` emits is the format the app accepts. Without
    /// this, a publisher-side change and a client-side change can each look right on their own and
    /// still disagree in production, where every install silently stops updating.
    ///
    /// Resolved from `PATH` rather than hardcoded: `/usr/bin/openssl` is LibreSSL and has no
    /// Ed25519 at all, so a fixed path would fail on every Mac while Homebrew's OpenSSL 3 works.
    @Test func aManifestSignedByOpensslVerifies() throws {
        let openssl = try #require(UpdatesOpenssl.available(), "no openssl with Ed25519 on PATH")
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let privatePEM = scratch.appendingPathComponent("key.pem")
        let publicPEM = scratch.appendingPathComponent("pub.pem")

        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = openssl
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #expect(process.terminationStatus == 0,
                        "openssl \(arguments.joined(separator: " ")) failed")
        }

        try run(["genpkey", "-algorithm", "ed25519", "-out", privatePEM.path])
        try run(["pkey", "-in", privatePEM.path, "-pubout", "-out", publicPEM.path])

        let appcast = UpdatesManifest.appcast(releases: [UpdatesManifest.release("0.1.30")])
        let manifest = try UpdatesManifest.bytes(appcast)
        let manifestPath = scratch.appendingPathComponent("appcast-0.1.30.json")
        try manifest.write(to: manifestPath)
        let signaturePath = scratch.appendingPathComponent("appcast-0.1.30.sig")
        try run(["pkeyutl", "-sign", "-rawin", "-inkey", privatePEM.path,
                 "-in", manifestPath.path, "-out", signaturePath.path])

        let keyring = AppcastKeyring(
            try AppcastSignatureVerifier.keyringSnippet(fromPEMAt: publicPEM.path, keyID: "marquee-2026"))
        #expect(keyring.keys.count == 1)
        #expect(keyring.keys["marquee-2026"]?.count == 32)

        let signature = AppcastSignatureFile(
            keyID: "marquee-2026",
            signature: try Data(contentsOf: signaturePath).base64EncodedString())

        // And the negative case, so the test cannot pass by verifying nothing at all.
        #expect(throws: Never.self) {
            try AppcastSignatureVerifier(keyring: keyring).verify(manifest: manifest, signature: signature)
        }
        let flipped = Data(manifest.dropLast(2) + Data("} }".utf8))
        #expect(throws: UpdateError.self) {
            try AppcastSignatureVerifier(keyring: keyring).verify(manifest: flipped, signature: signature)
        }
    }
}

/// Finds an openssl that can actually sign, so the test skips rather than fails on a machine with
/// only LibreSSL installed.
enum UpdatesOpenssl {
    static func available() -> URL? {
        let onPath = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map { "\($0)/openssl" } ?? []
        let candidates = ["/usr/local/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/bin/openssl"]
        for path in Array(Set(candidates + onPath)).sorted() {
            guard FileManager.default.isExecutableFile(atPath: path),
                  canGenerateEd25519(at: URL(fileURLWithPath: path))
            else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func canGenerateEd25519(at url: URL) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-openssl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = url
        process.arguments = ["genpkey", "-algorithm", "ed25519",
                             "-out", directory.appendingPathComponent("k.pem").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}