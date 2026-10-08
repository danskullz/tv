import Foundation
import Synchronization
@testable import MarqueeCore

enum IndexerFixtures {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Indexers/\(name)")
        return try! Data(contentsOf: url)
    }
}

/// Never really sleeps: advances a virtual monotonic clock and records every requested sleep.
final class FakeIndexerClock: IndexerClock, Sendable {
    private let state = Mutex<(now: TimeInterval, sleeps: [TimeInterval])>((now: 1000, sleeps: []))

    func now() -> TimeInterval { state.withLock { $0.now } }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.sleeps.append(seconds)
            $0.now += max(0, seconds)
        }
    }

    func advance(by seconds: TimeInterval) { state.withLock { $0.now += seconds } }
    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }
}

/// Scriptable transport; records every request it receives.
final class FakeIndexerTransport: IndexerTransport, Sendable {
    typealias Handler = @Sendable (IndexerHTTPRequest, Int) async throws -> IndexerHTTPResponse

    private let handler: Handler
    private let log = Mutex<[IndexerHTTPRequest]>([])

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Answers `t=caps` with `caps` and everything else with `search`.
    convenience init(caps: Data = IndexerFixtures.data("caps.xml"), search: Data) {
        self.init { request, _ in
            let body = request.url.queryValue("t") == "caps" ? caps : search
            return IndexerHTTPResponse(statusCode: 200, body: body)
        }
    }

    func send(_ request: IndexerHTTPRequest) async throws -> IndexerHTTPResponse {
        let count = log.withLock { $0.append(request); return $0.count }
        return try await handler(request, count)
    }

    var requests: [IndexerHTTPRequest] { log.withLock { $0 } }
    var searchRequests: [IndexerHTTPRequest] { requests.filter { $0.url.queryValue("t") != "caps" } }
}

extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

func makeDefinition(
    name: String = "Example", host: String = "indexer.example.invalid", apiPath: String = "/api",
    priority: Int = 25, categories: [Int] = [], minimumSeeders: Int = 0,
    rateLimit: IndexerRateLimit = .unlimited, tags: [String] = [], enabled: Bool = true
) -> IndexerDefinition {
    IndexerDefinition(
        name: name, baseURL: URL(string: "https://\(host)")!, apiPath: apiPath, enabled: enabled,
        priority: priority, categories: categories, minimumSeeders: minimumSeeders, rateLimit: rateLimit, tags: tags)
}

func makeSecrets(for definitions: [IndexerDefinition], key: String = "SECRETKEY123") -> InMemorySecretStore {
    let store = InMemorySecretStore()
    for d in definitions { try! store.set(key, account: d.apiKeyAccount) }
    return store
}

func makeRelease(
    indexer: UUID = UUID(), title: String = "Example.Show.S01E01.1080p", guid: String? = nil, hash: String? = nil,
    size: Int64? = 1000, seeders: Int? = 10, date: Date? = nil
) -> IndexerRelease {
    IndexerRelease(
        indexerID: indexer, indexerName: "x", title: title, guid: guid ?? UUID().uuidString,
        downloadURL: URL(string: "https://indexer.example.invalid/dl/\(UUID().uuidString)"), infoHash: hash,
        size: size, seeders: seeders, publishDate: date)
}

func parseFeed(_ name: String, indexer: UUID = UUID()) throws -> TorznabParsedFeed {
    try TorznabResultParser.parse(IndexerFixtures.data(name), indexerID: indexer, indexerName: "Example")
}

func fixtureCaps(_ name: String = "caps.xml") -> TorznabCapabilities {
    try! TorznabCapabilities.parse(IndexerFixtures.data(name))
}
