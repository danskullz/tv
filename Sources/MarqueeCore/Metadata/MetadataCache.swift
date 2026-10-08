import CryptoKit
import Foundation

/// A cached HTTP body with validators.
public struct CachedResponse: Sendable, Codable, Equatable {
    public var key: String
    public var body: Data
    public var etag: String?
    public var storedAt: Date
    public var expiresAt: Date
}

/// In-memory LRU with an optional on-disk tier. Stale entries are kept (for ETag revalidation
/// and offline fallback) until evicted.
public actor MetadataCache {
    private let capacity: Int
    private let directory: URL?
    private var entries: [String: CachedResponse] = [:]
    private var recency: [String: UInt64] = [:]
    private var tick: UInt64 = 0

    public init(capacity: Int = 256, directory: URL? = nil) {
        self.capacity = max(1, capacity)
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func entry(for key: String) -> CachedResponse? {
        if let e = entries[key] { touch(key); return e }
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode(CachedResponse.self, from: data),
              e.key == key else { return nil }
        insert(e)
        return e
    }

    public func store(_ entry: CachedResponse) {
        insert(entry)
        if let url = fileURL(for: entry.key), let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func remove(_ key: String) {
        entries[key] = nil
        recency[key] = nil
        if let url = fileURL(for: key) { try? FileManager.default.removeItem(at: url) }
    }

    public func clear() {
        entries.removeAll()
        recency.removeAll()
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" { try? FileManager.default.removeItem(at: f) }
        }
    }

    public var memoryCount: Int { entries.count }

    private func insert(_ entry: CachedResponse) {
        entries[entry.key] = entry
        touch(entry.key)
        while entries.count > capacity, let oldest = recency.min(by: { $0.value < $1.value })?.key {
            entries[oldest] = nil
            recency[oldest] = nil
        }
    }

    private func touch(_ key: String) {
        tick &+= 1
        recency[key] = tick
    }

    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}

/// How long responses stay fresh when the server doesn't say (Cache-Control wins when present).
public struct TMDBCachePolicy: Sendable, Equatable {
    public var details: TimeInterval = 24 * 3600
    public var trending: TimeInterval = 3600
    public var discover: TimeInterval = 3600
    public var search: TimeInterval = 600
    public var configuration: TimeInterval = 7 * 24 * 3600
    public var genres: TimeInterval = 7 * 24 * 3600
    public var season: TimeInterval = 6 * 3600
    public var find: TimeInterval = 24 * 3600
    public init() {}
}

enum CacheControl {
    struct Directives {
        var maxAge: TimeInterval?
        var noStore = false
        var noCache = false
    }

    static func parse(_ header: String?) -> Directives {
        var d = Directives()
        guard let header else { return d }
        for part in header.lowercased().split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p == "no-store" { d.noStore = true }
            else if p == "no-cache" { d.noCache = true }
            else if p.hasPrefix("max-age="), let n = TimeInterval(p.dropFirst("max-age=".count)) { d.maxAge = n }
        }
        return d
    }
}
