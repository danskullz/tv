import Foundation

/// Everything that can go wrong between "the user asked to update" and "the new app is running".
/// Equatable so tests and UI can compare cheaply.
public enum UpdateError: Error, Equatable, Sendable {
    // Reading the manifest.
    case unsupportedSchema(Int)
    case foreignManifest(String)
    case malformedManifest(String)
    /// The manifest did not verify against a known key. This is a security event, never a warning.
    case badSignature(keyID: String?)
    case unknownKey(String)
    case unsupportedAlgorithm(String)
    case missingSignature
    /// A URL that is not https, or not on the manifest's own host.
    case insecureURL(String)
    case notFound
    case httpStatus(Int)
    case network(String)

    // Getting the build.
    case checksumMismatch(expected: String, actual: String)
    case incompleteDownload(expected: Int, received: Int)
    case insufficientSpace(needed: Int64, available: Int64)
    case corruptArchive(String)
    case cancelled

    // Installing.
    case notAnInstalledBuild(String)
    case missingAppBundle(String)
    case bundleMismatch(String)
    /// The downloaded app is not signed by Marquee (or is signed but damaged).
    case signatureRejected(String)
    case destinationNotWritable(String)
    case installFailed(String)

    /// Plain-language message suitable for showing directly to the user (SCOPE §5.2).
    public var userMessage: String {
        switch self {
        case .unsupportedSchema:
            return "This update feed uses a format Marquee doesn't understand. Update Marquee by hand."
        case .foreignManifest:
            return "That address isn't Marquee's update feed. Nothing was changed."
        case .malformedManifest:
            return "Marquee's update feed couldn't be read. Nothing was changed."
        case .badSignature:
            return "The update wasn't signed by Marquee, so it was not installed. This can mean the site was tampered with."
        case .unknownKey:
            return "The update was signed with a key this copy of Marquee doesn't have. Install the newest version by hand."
        case .unsupportedAlgorithm:
            return "The update used a signature type Marquee can't check, so it was not installed."
        case .missingSignature:
            return "The update came without a signature, so it was not installed."
        case .insecureURL:
            return "The update wasn't served over a secure connection, so it was not installed."
        case .notFound:
            return "Marquee couldn't find an update on tv.guihot.net. Nothing was changed."
        case .httpStatus(let status):
            return "The update server had trouble answering (error \(status)). Try again in a few minutes."
        case .network:
            return "Marquee couldn't reach the update server. Check your connection and try again."
        case .checksumMismatch:
            return "The download didn't match what the update server promised, so it was thrown away. Try again."
        case .incompleteDownload:
            return "The update download was cut short, so it was thrown away. Try again."
        case .insufficientSpace:
            return "There isn't enough free space to install the update."
        case .corruptArchive:
            return "The downloaded update was damaged, so it was thrown away. Try again."
        case .cancelled:
            return "The update was cancelled."
        case .notAnInstalledBuild(let detail):
            return detail
        case .missingAppBundle:
            return "The download didn't contain a Marquee app, so it was thrown away."
        case .bundleMismatch(let detail):
            return "The downloaded app isn't the version it claimed to be (\(detail)), so it was thrown away."
        case .signatureRejected:
            return "The downloaded app isn't signed by Marquee, so it was not installed."
        case .destinationNotWritable(let path):
            return "Marquee can't write to \(path). Move Marquee to your Applications folder and try again."
        case .installFailed(let detail):
            return detail
        }
    }

    /// Technical detail for the copyable "details" disclosure.
    public var technicalDetail: String {
        switch self {
        case .unsupportedSchema(let n): return "unsupportedSchema: \(n)"
        case .foreignManifest(let id): return "foreignManifest: \(id)"
        case .malformedManifest(let d): return "malformedManifest: \(d)"
        case .badSignature(let id): return "badSignature (keyID: \(id ?? "none"))"
        case .unknownKey(let id): return "unknownKey: \(id)"
        case .unsupportedAlgorithm(let a): return "unsupportedAlgorithm: \(a)"
        case .missingSignature: return "missingSignature"
        case .insecureURL(let u): return "insecureURL: \(u)"
        case .notFound: return "notFound"
        case .httpStatus(let s): return "httpStatus: HTTP \(s)"
        case .network(let d): return "network: \(d)"
        case .checksumMismatch(let e, let a): return "checksumMismatch: expected \(e.prefix(16))…, got \(a.prefix(16))…"
        case .incompleteDownload(let e, let r): return "incompleteDownload: expected \(e), got \(r)"
        case .insufficientSpace(let n, let a): return "insufficientSpace: need \(n), have \(a)"
        case .corruptArchive(let d): return "corruptArchive: \(d)"
        case .cancelled: return "cancelled"
        case .notAnInstalledBuild(let d): return "notAnInstalledBuild: \(d)"
        case .missingAppBundle(let d): return "missingAppBundle: \(d)"
        case .bundleMismatch(let d): return "bundleMismatch: \(d)"
        case .signatureRejected(let d): return "signatureRejected: \(d)"
        case .destinationNotWritable(let d): return "destinationNotWritable: \(d)"
        case .installFailed(let d): return "installFailed: \(d)"
        }
    }

    /// Worth retrying on its own later (transport or server trouble, not a rejected update).
    public var isRetryable: Bool {
        switch self {
        case .network, .httpStatus, .notFound: return true
        default: return false
        }
    }

    /// Whether the failure is worth showing at all when the user only asked in passing. A scheduled
    /// background check stays silent about transient problems; an explicit request does not.
    public var isWorthReporting: Bool { !isRetryable }
}

extension UpdateError: LocalizedError {
    public var errorDescription: String? { userMessage }
}