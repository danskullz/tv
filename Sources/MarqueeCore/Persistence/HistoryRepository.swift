import Foundation
import GRDB

public protocol HistoryRepository: Sendable {
    /// Events are immutable once appended.
    func append(_ event: HistoryEvent) async throws
    /// Newest first.
    func events(forEntity type: HistoryEntityType, id: String, limit: Int) async throws -> [HistoryEvent]
    /// Newest first.
    func events(forTitle titleId: UUID, limit: Int) async throws -> [HistoryEvent]
    /// Newest first, optionally of one type.
    func recent(type: HistoryEventType?, limit: Int) async throws -> [HistoryEvent]
}

public struct GRDBHistoryRepository: HistoryRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func append(_ event: HistoryEvent) async throws {
        try await database.writer.write { try event.insert($0) }
    }

    public func events(forEntity type: HistoryEntityType, id: String, limit: Int = 100) async throws
        -> [HistoryEvent]
    {
        try await database.writer.read {
            try HistoryEvent
                .filter(Column("entityType") == type && Column("entityId") == id)
                .order(Column("occurredAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func events(forTitle titleId: UUID, limit: Int = 100) async throws -> [HistoryEvent] {
        try await database.writer.read {
            try HistoryEvent.filter(Column("titleId") == titleId)
                .order(Column("occurredAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func recent(type: HistoryEventType? = nil, limit: Int = 100) async throws -> [HistoryEvent] {
        try await database.writer.read { db in
            var request = HistoryEvent.all()
            if let type { request = request.filter(Column("type") == type) }
            return try request.order(Column("occurredAt").desc).limit(limit).fetchAll(db)
        }
    }
}

extension HistoryRepository {
    public func events(forEntity type: HistoryEntityType, id: UUID, limit: Int = 100) async throws
        -> [HistoryEvent]
    {
        try await events(forEntity: type, id: id.uuidString, limit: limit)
    }
}
