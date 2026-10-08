import Foundation

/// Per-indexer request pacing. A token bucket that refills one token every `minInterval`
/// seconds and holds at most `burst` tokens.
public struct IndexerRateLimit: Sendable, Hashable, Codable {
    public var minInterval: TimeInterval
    public var burst: Int

    public init(minInterval: TimeInterval = 1.0, burst: Int = 2) {
        self.minInterval = max(0, minInterval)
        self.burst = max(1, burst)
    }

    /// No client-side pacing (the indexer may still answer 429).
    public static let unlimited = IndexerRateLimit(minInterval: 0, burst: 1)
    /// Polite default: one request per second sustained, small bursts allowed.
    public static let `default` = IndexerRateLimit(minInterval: 1.0, burst: 2)
}

/// A user-configured Torznab indexer. The API key is deliberately NOT part of this type;
/// it lives in a `SecretStore` under `apiKeyAccount`.
public struct IndexerDefinition: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Scheme + host (+ optional path prefix), e.g. `https://jackett.local:9117`.
    public var baseURL: URL
    /// Path of the Torznab endpoint relative to `baseURL`, e.g. `/api` or `/api/v2.0/indexers/x/results/torznab/api`.
    public var apiPath: String
    public var enabled: Bool
    /// 1 = highest priority, 50 = lowest (same convention as Prowlarr). Used to break ties.
    public var priority: Int
    /// Torznab category ids to restrict searches to. Empty means "sensible default for the search type".
    public var categories: [Int]
    /// Releases with fewer seeders are dropped. Releases that report no seeder count are kept.
    public var minimumSeeders: Int
    public var rateLimit: IndexerRateLimit
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        apiPath: String = "/api",
        enabled: Bool = true,
        priority: Int = 25,
        categories: [Int] = [],
        minimumSeeders: Int = 0,
        rateLimit: IndexerRateLimit = .default,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiPath = apiPath
        self.enabled = enabled
        self.priority = priority
        self.categories = categories
        self.minimumSeeders = max(0, minimumSeeders)
        self.rateLimit = rateLimit
        self.tags = tags
    }

    /// Account string under which this indexer's API key is stored in a `SecretStore`.
    public var apiKeyAccount: String { "indexer.\(id.uuidString.lowercased()).apikey" }
}
