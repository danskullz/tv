import Foundation

/// Removes secrets from strings before they reach errors, descriptions or logs.
public enum SecretRedactor {
    public static let placeholder = "REDACTED"

    /// Redacts `apikey=`-style query parameters, plus any literal secret values (raw or percent-encoded).
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text.replacingOccurrences(
            of: #"(?i)(apikey|api_key|passkey|token|password)=[^&\s"'<>]*"#,
            with: "$1=\(placeholder)",
            options: .regularExpression)
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: placeholder)
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != secret {
                result = result.replacingOccurrences(of: encoded, with: placeholder)
            }
        }
        return result
    }

    public static func redact(_ url: URL, secrets: [String] = []) -> String {
        redact(url.absoluteString, secrets: secrets)
    }
}

/// Everything that can go wrong talking to an indexer. Equatable so tests and UI can compare cheaply.
public enum IndexerError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case authenticationFailed(detail: String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case httpStatus(Int)
    case timeout
    case network(String)
    case malformedResponse(String)
    /// A Torznab `<error code="" description=""/>` response (other than credential errors).
    case apiError(code: Int, description: String)
    case unsupportedSearch(String)
    case responseTooLarge
    case cancelled

    /// Maps a Torznab/Newznab error code to a typed error.
    public static func fromAPIError(code: Int, description: String) -> IndexerError {
        let text = SecretRedactor.redact(description)
        switch code {
        case 100...102: return .authenticationFailed(detail: text)
        default: return .apiError(code: code, description: text)
        }
    }

    /// Plain-language message suitable for showing directly to the user (SCOPE §5.2).
    public var userMessage: String {
        switch self {
        case .invalidConfiguration(let detail):
            return "This indexer isn't set up correctly. \(detail)"
        case .authenticationFailed:
            return "The indexer didn't accept your API key. Check the key in this indexer's settings."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter >= 1 {
                return "The indexer asked Marquee to slow down. Try again in about \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "The indexer asked Marquee to slow down. Try again in a moment."
        case .serverError(let status):
            return "The indexer is having problems right now (error \(status)). Try again in a few minutes."
        case .httpStatus(let status):
            switch status {
            case 404:
                return "Marquee couldn't find an indexer at that address. Check the URL and API path."
            case 403:
                return "The indexer refused the connection. It may be blocking automated requests or need a login."
            default:
                return "The indexer gave an unexpected answer (error \(status))."
            }
        case .timeout:
            return "The indexer took too long to answer."
        case .network:
            return "Marquee couldn't reach the indexer. Check your connection and the indexer's address."
        case .malformedResponse:
            return "The indexer sent a reply Marquee couldn't read. The address may point to a web page instead of the Torznab API."
        case .apiError(let code, let description):
            switch code {
            case 200...299:
                return "The indexer didn't understand the search request. \(description)"
            case 910:
                return "The indexer's API is switched off. Enable it on the indexer and try again."
            default:
                return description.isEmpty
                    ? "The indexer reported an error (code \(code))."
                    : "The indexer reported a problem: \(description)"
            }
        case .unsupportedSearch(let detail):
            return "This indexer can't run that kind of search. \(detail)"
        case .responseTooLarge:
            return "The indexer's answer was unusually large, so Marquee ignored it."
        case .cancelled:
            return "The search was cancelled."
        }
    }

    /// Technical detail for the copyable "details" disclosure. Already redacted.
    public var technicalDetail: String {
        switch self {
        case .invalidConfiguration(let d): return "invalidConfiguration: \(d)"
        case .authenticationFailed(let d): return "authenticationFailed: \(d)"
        case .rateLimited(let r): return "rateLimited (retryAfter: \(r.map { String($0) } ?? "none"))"
        case .serverError(let s): return "serverError: HTTP \(s)"
        case .httpStatus(let s): return "httpStatus: HTTP \(s)"
        case .timeout: return "timeout"
        case .network(let d): return "network: \(d)"
        case .malformedResponse(let d): return "malformedResponse: \(d)"
        case .apiError(let c, let d): return "apiError \(c): \(d)"
        case .unsupportedSearch(let d): return "unsupportedSearch: \(d)"
        case .responseTooLarge: return "responseTooLarge"
        case .cancelled: return "cancelled"
        }
    }

    /// Worth retrying after a delay (transient server-side or transport problems).
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .timeout: return true
        default: return false
        }
    }

    /// Whether this failure says something about the indexer's health. Request-specific problems
    /// (an unsupported search type) and user cancellation do not.
    public var countsAgainstHealth: Bool {
        switch self {
        case .unsupportedSearch, .cancelled: return false
        default: return true
        }
    }

    /// Copy with secrets scrubbed from every embedded string.
    public func redacted(secrets: [String]) -> IndexerError {
        func r(_ s: String) -> String { SecretRedactor.redact(s, secrets: secrets) }
        switch self {
        case .invalidConfiguration(let d): return .invalidConfiguration(r(d))
        case .authenticationFailed(let d): return .authenticationFailed(detail: r(d))
        case .network(let d): return .network(r(d))
        case .malformedResponse(let d): return .malformedResponse(r(d))
        case .apiError(let c, let d): return .apiError(code: c, description: r(d))
        case .unsupportedSearch(let d): return .unsupportedSearch(r(d))
        default: return self
        }
    }
}

extension IndexerError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
