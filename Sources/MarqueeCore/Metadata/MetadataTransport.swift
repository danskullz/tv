import Foundation

/// A completed HTTP exchange. Header names are lowercased.
public struct MetadataHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

/// Minimal HTTP seam so metadata clients can be tested without the network.
public protocol MetadataTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse
}

/// Default transport. Caching is done by the client, so URLSession's cache is disabled.
public struct URLSessionMetadataTransport: MetadataTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return MetadataHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
