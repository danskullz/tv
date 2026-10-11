import Foundation

/// What a verified fetch produced.
public enum AppcastFetchResult: Sendable, Equatable {
    /// The server confirmed our cached copy is still current.
    case notModified
    /// A manifest that has verified, plus the validator to send next time.
    case verified(Appcast, etag: String?)
}

/// Reads the manifest, then the detached signature, and refuses anything that doesn't check out.
///
/// The order is deliberate. The `signatureURL` field is read from **unverified** bytes to decide
/// where to fetch the signature, which is safe precisely because the fetched signature still has to
/// verify against a key compiled into the app — and because the URL is required to be https on the
/// manifest's own host, so untrusted content can't aim the fetch anywhere else. The manifest is
/// decoded for real only after it has verified.
public struct AppcastFetcher: Sendable {
    public let transport: any UpdateTransport
    public let verifier: AppcastSignatureVerifier
    /// The host every fetched URL must be on.
    public let origin: URL

    public init(
        transport: any UpdateTransport,
        verifier: AppcastSignatureVerifier,
        origin: URL
    ) {
        self.transport = transport
        self.verifier = verifier
        self.origin = origin
    }

    public init(
        transport: any UpdateTransport,
        keyring: AppcastKeyring,
        origin: URL
    ) {
        self.init(
            transport: transport,
            verifier: AppcastSignatureVerifier(keyring: keyring),
            origin: origin
        )
    }

    public func fetch(manifestURL: URL, etag: String? = nil) async throws -> AppcastFetchResult {
        try requireSameOrigin(manifestURL)
        let response = try await transport.send(UpdateHTTPRequest(url: manifestURL, etag: etag))
        if response.isNotModified { return .notModified }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { throw UpdateError.notFound }
            throw UpdateError.httpStatus(response.statusCode)
        }
        guard !response.body.isEmpty else { throw UpdateError.malformedManifest("Empty manifest.") }

        let signatureURL = try signatureURL(for: response.body, manifestURL: manifestURL)
        let signatureResponse = try await transport.send(UpdateHTTPRequest(url: signatureURL))
        guard (200..<300).contains(signatureResponse.statusCode) else {
            if signatureResponse.statusCode == 404 { throw UpdateError.missingSignature }
            throw UpdateError.httpStatus(signatureResponse.statusCode)
        }
        let signatureFile = try AppcastSignatureFile.decode(from: signatureResponse.body)
        // Fail closed. A manifest we can't verify is never parsed, never shown, never installed.
        try verifier.verify(manifest: response.body, signature: signatureFile)

        let appcast = try Appcast.decode(from: response.body)
        try appcast.validate()
        return .verified(appcast, etag: response.etag)
    }

    /// Uses the hint when there is one, falling back to the deterministic `<manifest>.sig` when the
    /// bytes are unreadable — a fallback that costs nothing, because the signature still has to pass.
    private func signatureURL(for manifest: Data, manifestURL: URL) throws -> URL {
        let hinted: URL? = (try? Appcast.decode(from: manifest))?.signatureURL
        if let hinted, (try? requireSameOrigin(hinted)) != nil { return hinted }
        return manifestURL.appendingPathExtension("sig")
    }

    /// https, and no other host. The updater only ever reads from where it was told to.
    private func requireSameOrigin(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureURL(url.absoluteString)
        }
        guard url.host?.caseInsensitiveCompare(origin.host ?? "") == .orderedSame,
              url.port == origin.port
        else {
            throw UpdateError.insecureURL(url.absoluteString)
        }
    }
}