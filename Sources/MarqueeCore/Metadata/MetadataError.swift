import Foundation

/// Plain-language errors surfaced by metadata clients.
public enum MetadataError: Error, Equatable, Sendable, LocalizedError {
    case invalidAPIKey
    case notFound
    case offline
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case decoding(String)
    case invalidRequest(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "TMDB rejected your API key. Check the key in Settings and try again."
        case .notFound:
            return "TMDB doesn't have anything matching that."
        case .offline:
            return "You appear to be offline, so TMDB couldn't be reached."
        case .rateLimited(let after):
            if let after { return "TMDB is asking us to slow down. Try again in about \(Int(after.rounded(.up))) seconds." }
            return "TMDB is asking us to slow down. Try again in a moment."
        case .server(let status, let message):
            return "TMDB had a problem (error \(status))" + (message.map { ": \($0)" } ?? ".")
        case .decoding:
            return "TMDB sent back something unexpected that we couldn't read."
        case .invalidRequest(let m):
            return "That request couldn't be built: \(m)"
        case .unknown(let m):
            return "Something went wrong talking to TMDB: \(m)"
        }
    }
}
