import Foundation

public struct IndexerHTTPRequest: Sendable, Equatable, CustomStringConvertible {
    public var url: URL
    public var timeout: TimeInterval
    public var headers: [String: String]

    public init(url: URL, timeout: TimeInterval = 20, headers: [String: String] = [:]) {
        self.url = url
        self.timeout = timeout
        self.headers = headers
    }

    /// The URL contains the API key, so it is always redacted in descriptions.
    public var description: String { "GET \(SecretRedactor.redact(url))" }
}

public struct IndexerHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The only seam through which indexer code touches the network. Tests inject a fake.
public protocol IndexerTransport: Sendable {
    func send(_ request: IndexerHTTPRequest) async throws -> IndexerHTTPResponse
}

/// Default transport: an ephemeral URLSession (no cookies/cache persisted) that refuses to follow
/// an https -> http redirect, since the request URL carries the API key.
public final class URLSessionIndexerTransport: IndexerTransport, Sendable {
    private let session: URLSession

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            if task.originalRequest?.url?.scheme == "https", request.url?.scheme != "https" {
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }
    }

    public init(userAgent: String = "Marquee") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/xml, text/xml, */*"]
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    public func send(_ request: IndexerHTTPRequest) async throws -> IndexerHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw IndexerError.malformedResponse("The server did not answer with HTTP.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return IndexerHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// Time source for pacing and backoff. Monotonic seconds; injectable so tests never really wait.
public protocol IndexerClock: Sendable {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemIndexerClock: IndexerClock {
    public init() {}

    public func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
