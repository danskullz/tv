import Foundation
import GRDB

public protocol HealthIssueRepository: Sendable {
    /// Updates an unresolved issue with the same code/entity, or inserts it when none exists.
    func report(code: String, severity: HealthIssue.Severity, message: String, fixAction: String?, entityId: String?) async throws -> HealthIssue
    func resolve(code: String, entityId: String?) async throws
    func active() async throws -> [HealthIssue]
}

public struct GRDBHealthIssueRepository: HealthIssueRepository {
    private let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func report(
        code: String, severity: HealthIssue.Severity, message: String, fixAction: String? = nil,
        entityId: String? = nil
    ) async throws -> HealthIssue {
        try await database.writer.write { db in
            let predicate = Column("code") == code && Column("entityId") == entityId && Column("resolvedAt") == nil
            var issue = try HealthIssue.filter(predicate).fetchOne(db)
                ?? HealthIssue(code: code, severity: severity, message: message, fixAction: fixAction, entityId: entityId)
            issue.severity = severity
            issue.message = message
            issue.fixAction = fixAction
            issue.resolvedAt = nil
            issue.updatedAt = Date()
            try issue.save(db)
            return issue
        }
    }

    public func resolve(code: String, entityId: String? = nil) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE healthIssue SET resolvedAt = ?, updatedAt = ? WHERE code = ? AND entityId IS ? AND resolvedAt IS NULL",
                arguments: [Date(), Date(), code, entityId])
        }
    }

    public func active() async throws -> [HealthIssue] {
        try await database.writer.read {
            try HealthIssue.filter(Column("resolvedAt") == nil).order(Column("severity").desc, Column("createdAt").desc).fetchAll($0)
        }
    }
}
