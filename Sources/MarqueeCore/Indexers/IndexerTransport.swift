import Foundation

public struct IndexerHTTPRequest: Sendable, Equatable, CustomStringConvertible {
    public var url: URL
    public var timeout: TimeInterval
    public var headers: [String: String]
    public var method: String
    public var body: Data?
    /// When set, the request is wrapped in a FlareSolverr `request.get` call.
    public var flareSolverrURL: URL?

    public init(
        url: URL, timeout: TimeInterval = 20, headers: [String: String] = [:],
        method: String = "GET", body: Data? = nil, flareSolverrURL: URL? = nil
    ) {
        self.url = url
        self.timeout = timeout
        self.headers = headers
        self.method = method
        self.body = body
        self.flareSolverrURL = flareSolverrURL
    }

    /// The URL contains the API key, so it is always redacted in descriptions.
    public var description: String { "\(method) \(SecretRedactor.redact(url))" }
}

/// Adapts indexer requests to a user-managed FlareSolverr instance when one is configured.
public struct FlareSolverrIndexerTransport: IndexerTransport, Sendable {
    private let base: IndexerTransport
    private let challengeTimeoutMilliseconds = 60_000

    public init(base: IndexerTransport = URLSessionIndexerTransport()) {
        self.base = base
    }

    public func send(_ request: IndexerHTTPRequest) async throws -> IndexerHTTPResponse {
        guard let server = request.flareSolverrURL else { return try await base.send(request) }
        let endpoint = try Self.endpoint(for: server)
        let payload: [String: Any] = [
            "cmd": "request.get",
            "url": request.url.absoluteString,
            "maxTimeout": challengeTimeoutMilliseconds,
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw IndexerError.invalidConfiguration("The FlareSolverr request couldn't be created.")
        }
        let solverRequest = IndexerHTTPRequest(
            url: endpoint, timeout: max(request.timeout, 90),
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            method: "POST", body: body)
        let response = try await base.send(solverRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw IndexerClient.error(forStatus: response.statusCode, retryAfter: nil)
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            object["status"] as? String == "ok",
            let solution = object["solution"] as? [String: Any],
            let page = solution["response"] as? String,
            let status = solution["status"] as? Int,
            let data = page.data(using: .utf8)
        else {
            throw IndexerError.challengeSolverFailed
        }
        return IndexerHTTPResponse(statusCode: status, body: data)
    }

    static func endpoint(for server: URL) throws -> URL {
        guard let scheme = server.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = server.host, !host.isEmpty
        else {
            throw IndexerError.invalidConfiguration("Enter a valid FlareSolverr HTTP or HTTPS address.")
        }
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        guard components?.query == nil, components?.fragment == nil else {
            throw IndexerError.invalidConfiguration("The FlareSolverr address must not include a query or fragment.")
        }
        let path = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if path.isEmpty {
            components?.percentEncodedPath = "/v1"
        } else if path == "v1" || path.hasSuffix("/v1") {
            components?.percentEncodedPath = "/\(path)"
        } else {
            components?.percentEncodedPath = "/\(path)/v1"
        }
        guard let endpoint = components?.url else {
            throw IndexerError.invalidConfiguration("Enter a valid FlareSolverr address.")
        }
        return endpoint
    }
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
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
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
