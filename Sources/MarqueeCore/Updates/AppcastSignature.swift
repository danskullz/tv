import CryptoKit
import Foundation

/// The detached signature file that sits next to a versioned manifest.
///
/// It signs **the exact bytes** of the manifest, never a re-serialized form. The publisher writes
/// the bytes once; the client re-reads those bytes; there is no canonicalization step where the two
/// could drift — and drift there would silently lock every install out of updating.
public struct AppcastSignatureFile: Sendable, Codable, Equatable {
    public static let supportedSchema = 1

    public var schema: Int
    public var keyID: String
    public var algorithm: String
    /// Informational: the manifest this was issued for. The client does not rely on it.
    public var signedFile: String?
    /// Informational: a hash of the signed bytes, so a mismatch is diagnosable in a log.
    public var signedSHA256: String?
    /// Base64 of the raw 64-byte Ed25519 signature.
    public var signature: String

    public init(
        schema: Int = supportedSchema, keyID: String, algorithm: String = "ed25519",
        signedFile: String? = nil, signedSHA256: String? = nil, signature: String
    ) {
        self.schema = schema
        self.keyID = keyID
        self.algorithm = algorithm
        self.signedFile = signedFile
        self.signedSHA256 = signedSHA256
        self.signature = signature
    }

    public static func decode(from data: Data) throws -> AppcastSignatureFile {
        try JSONDecoder().decode(AppcastSignatureFile.self, from: data)
    }
}

/// The public keys this build of Marquee trusts, by key ID.
///
/// Both the current and the outgoing key are present during a rotation. Shipping only the new key
/// would break every copy that hasn't updated yet, which is the worst possible moment to find out.
public struct AppcastKeyring: Sendable, Equatable {
    public static let empty = AppcastKeyring([:])

    /// keyID → the 32-byte Ed25519 public key. `Data` rather than base64 text so that a mistyped
    /// entry is a compile error instead of an update check that mysteriously fails at runtime.
    public let keys: [String: Data]

    public init(_ keys: [String: Data]) { self.keys = keys }

    public func publicKey(for keyID: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = keys[keyID] else { throw UpdateError.unknownKey(keyID) }
        guard raw.count == 32 else { throw UpdateError.badSignature(keyID: keyID) }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw UpdateError.badSignature(keyID: keyID)
        }
    }
}

/// Checks a manifest against the keys shipped inside the app.
///
/// Every failure here is fatal to the check. There is deliberately no "warn and continue" path: the
/// manifest and the binaries now come from the same host, so this signature is the only thing between
/// that host and arbitrary code execution on every install.
public struct AppcastSignatureVerifier: Sendable {
    public let keyring: AppcastKeyring

    public init(keyring: AppcastKeyring) { self.keyring = keyring }

    /// - Parameters:
    ///   - manifest: the exact bytes fetched, before any decoding.
    ///   - signatureFile: the parsed detached signature.
    /// - Returns: the manifest, once it has verified.
    @discardableResult
    public func verify(manifest: Data, signature: AppcastSignatureFile) throws -> Data {
        guard signature.schema == AppcastSignatureFile.supportedSchema else {
            throw UpdateError.unsupportedSchema(signature.schema)
        }
        guard signature.algorithm.lowercased() == "ed25519" else {
            throw UpdateError.unsupportedAlgorithm(signature.algorithm)
        }
        guard let raw = Data(base64Encoded: signature.signature), raw.count == 64 else {
            throw UpdateError.badSignature(keyID: signature.keyID)
        }
        let key = try keyring.publicKey(for: signature.keyID)
        // `isValidSignature` takes the raw 64-byte signature directly; there is no need to name
        // CryptoKit's signature struct, which isn't part of its public surface under that name.
        guard key.isValidSignature(raw, for: manifest) else {
            throw UpdateError.badSignature(keyID: signature.keyID)
        }
        return manifest
    }

    /// `keyID` → raw public key, ready to paste into `AppcastKeyring(...)` in the app.
    ///
    /// Takes the *public* half of a PEM pair (`openssl pkey -in key.pem -pubout`). Tests use it to
    /// prove the keyring the publisher generates actually loads into `AppcastKeyring`.
    public static func keyringSnippet(fromPEMAt path: String, keyID: String) throws -> [String: Data] {
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        var base64 = ""
        for line in pem.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----") { continue }
            base64 += trimmed
        }
        guard let der = Data(base64Encoded: base64), der.count >= 32 else {
            throw UpdateError.unknownKey("unreadable PEM at \(path)")
        }
        // DER SubjectPublicKeyInfo for Ed25519 is a 12-byte prefix followed by the 32-byte raw key.
        return [keyID: Data(der.suffix(32))]
    }
}