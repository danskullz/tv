import Foundation
import GRDB

// Small repositories for the acquisition pipeline: indexers, the blocklist and the grab (decision) log.

public protocol IndexerRepository: Sendable {
    func all() async throws -> [Indexer]
    func indexer(id: UUID) async throws -> Indexer?
    /// Inserts or replaces by id.
    func upsert(_ indexer: Indexer) async throws
    func setEnabled(id: UUID, _ enabled: Bool) async throws
    /// Persists rolling search health and sets a temporary auto-disable window at the threshold.
    func recordSearchOutcome(id: UUID, succeeded: Bool, threshold: Int, disableFor: TimeInterval, now: Date) async throws
    func delete(id: UUID) async throws
}

public struct GRDBIndexerRepository: IndexerRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func all() async throws -> [Indexer] {
        try await database.writer.read { try Indexer.order(Column("priority"), Column("name")).fetchAll($0) }
    }

    public func indexer(id: UUID) async throws -> Indexer? {
        try await database.writer.read { try Indexer.fetchOne($0, key: id) }
    }

    public func upsert(_ indexer: Indexer) async throws {
        var indexer = indexer
        indexer.updatedAt = Date()
        try await database.writer.write { [indexer] in try indexer.save($0) }
    }

    public func setEnabled(id: UUID, _ enabled: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE indexer SET enabled = ?, updatedAt = ? WHERE id = ?", arguments: [enabled, Date(), id])
        }
    }

    public func recordSearchOutcome(
        id: UUID, succeeded: Bool, threshold: Int = 5, disableFor: TimeInterval = 6 * 60 * 60,
        now: Date = Date()
    ) async throws {
        try await database.writer.write { db in
            guard var indexer = try Indexer.fetchOne(db, key: id) else { return }
            if succeeded {
                indexer.failureCount = 0
                indexer.disabledUntil = nil
                indexer.lastSuccessAt = now
            } else {
                indexer.failureCount += 1
                if indexer.failureCount >= max(1, threshold), indexer.enabled {
                    indexer.disabledUntil = now.addingTimeInterval(max(60, disableFor))
                }
            }
            indexer.updatedAt = now
            try indexer.update(db)
        }
    }

    public func delete(id: UUID) async throws {
        try await database.writer.write { _ = try Indexer.deleteOne($0, key: id) }
    }
}

public protocol BlocklistRepository: Sendable {
    func add(_ entry: BlocklistEntry) async throws
    /// Entries that apply to `titleId` (title-wide, or for the given episode).
    func entries(titleId: UUID) async throws -> [BlocklistEntry]
    func remove(id: UUID) async throws
}

public struct GRDBBlocklistRepository: BlocklistRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func add(_ entry: BlocklistEntry) async throws {
        try await database.writer.write { try entry.insert($0) }
    }

    public func entries(titleId: UUID) async throws -> [BlocklistEntry] {
        try await database.writer.read {
            try BlocklistEntry.filter(Column("titleId") == titleId).order(Column("createdAt").desc).fetchAll($0)
        }
    }

    public func remove(id: UUID) async throws {
        try await database.writer.write { _ = try BlocklistEntry.deleteOne($0, key: id) }
    }
}

public protocol GrabRepository: Sendable {
    func save(_ grab: Grab) async throws
    /// Newest first.
    func grabs(titleId: UUID, limit: Int) async throws -> [Grab]
    func grab(id: UUID) async throws -> Grab?
}

public struct GRDBGrabRepository: GrabRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func save(_ grab: Grab) async throws {
        var grab = grab
        grab.updatedAt = Date()
        try await database.writer.write { [grab] in try grab.save($0) }
    }

    public func grabs(titleId: UUID, limit: Int = 50) async throws -> [Grab] {
        try await database.writer.read {
            try Grab.filter(Column("titleId") == titleId).order(Column("createdAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func grab(id: UUID) async throws -> Grab? {
        try await database.writer.read { try Grab.fetchOne($0, key: id) }
    }
}

// MARK: - Indexer record <-> definition

extension Indexer {
    /// Stores a Torznab endpoint. `baseURL` keeps the full address (including the API path) the user
    /// pasted; the API key lives in the secret store under ``credentialRef``.
    public init(name: String, torznabURL: URL, priority: Int = 25, minimumSeeders: Int = 1, id: UUID = UUID()) {
        self.init(
            id: id, name: name, implementation: "torznab", baseURL: torznabURL.absoluteString,
            priority: priority, minimumSeeders: minimumSeeders,
            credentialRef: IndexerDefinition(id: id, name: name, baseURL: torznabURL).apiKeyAccount)
    }

    /// The search-side definition, or nil when `baseURL` is not a usable http(s) address.
    public var definition: IndexerDefinition? {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? ""
        components?.percentEncodedPath = ""
        components?.query = nil
        components?.fragment = nil
        let base = components?.url ?? url
        let apiPath = path.isEmpty || path == "/" ? "/api" : path
        return IndexerDefinition(
            id: id, name: name, baseURL: base, apiPath: apiPath,
            enabled: enabled && (disabledUntil.map { $0 <= Date() } ?? true), priority: priority,
            categories: categories, minimumSeeders: minimumSeeders)
    }
}

// MARK: - Preset profiles

extension AppDatabase {
    /// Makes sure every built-in quality preset has a `qualityProfile` row, so titles can reference it
    /// (the foreign key needs the row; the engine reads the full profile from the in-code preset).
    public func ensurePresetProfiles() async throws {
        try await writer.write { db in
            for preset in QualityProfileConfig.presets where try !QualityProfile.exists(db, key: preset.id) {
                try preset.record().insert(db)
            }
        }
    }
}
