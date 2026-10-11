import Foundation

public struct UpdateHTTPRequest: Sendable, Equatable {
    public var url: URL
    /// Sent as `If-None-Match` so an unchanged manifest costs a bodiless 304.
    public var etag: String?
    public var timeout: TimeInterval

    public init(url: URL, etag: String? = nil, timeout: TimeInterval = 20) {
        self.url = url
        self.etag = etag
        self.timeout = timeout
    }
}

public struct UpdateHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var etag: String?
    public var body: Data

    public init(statusCode: Int, etag: String? = nil, body: Data = Data()) {
        self.statusCode = statusCode
        self.etag = etag
        self.body = body
    }

    /// True when the server confirmed our cached copy is still current.
    public var isNotModified: Bool { statusCode == 304 }
}

/// The only seam through which the updater touches the network. Tests inject a fake.
public protocol UpdateTransport: Sendable {
    func send(_ request: UpdateHTTPRequest) async throws -> UpdateHTTPResponse
}

/// Ephemeral session: no cookie jar, no URL cache on disk, no credentials of ours attached to the
/// request. A user agent that names the build makes the host's access log able to answer "which
/// versions are checking, and how often".
public final class URLSessionUpdateTransport: UpdateTransport, Sendable {
    private let session: URLSession

    public init(userAgent: String = "Marquee") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: UpdateHTTPRequest) async throws -> UpdateHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        if let etag = request.etag { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.network("The server didn't answer with HTTP.")
            }
            return UpdateHTTPResponse(
                statusCode: http.statusCode,
                etag: http.value(forHTTPHeaderField: "ETag"),
                body: data)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }
}

/// Time source, injectable so tests never really wait.
public protocol UpdateClock: Sendable {
    func now() -> Date
}

public struct SystemUpdateClock: UpdateClock {
    public init() {}
    public func now() -> Date { Date() }
}