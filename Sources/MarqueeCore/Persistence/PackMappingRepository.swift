import Foundation
import GRDB

public protocol PackMappingRepository: Sendable {
    /// Mappings of a torrent ordered by file index.
    func mappings(infoHash: String) async throws -> [PackFileMapping]
    /// Applies freshly computed automatic mappings. Rows the user corrected are left untouched;
    /// other existing rows are replaced and automatic rows no longer present are removed.
    func applyAutomatic(infoHash: String, _ mappings: [PackFileMapping]) async throws
    /// Records a user correction, which later `applyAutomatic` calls never overwrite.
    func correct(
        infoHash: String, fileIndex: Int, episodeIds: [UUID], role: PackFileRole
    ) async throws
    /// Mappings (any torrent) that include the episode.
    func mappings(forEpisode episodeId: UUID) async throws -> [PackFileMapping]
    func removeAll(infoHash: String) async throws
}

public struct GRDBPackMappingRepository: PackMappingRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func mappings(infoHash: String) async throws -> [PackFileMapping] {
        try await database.writer.read {
            try PackFileMapping.filter(Column("infoHash") == infoHash.lowercased())
                .order(Column("fileIndex")).fetchAll($0)
        }
    }

    public func applyAutomatic(infoHash: String, _ mappings: [PackFileMapping]) async throws {
        let hash = infoHash.lowercased()
        try await database.writer.write { db in
            let corrected = try Set(
                Int.fetchAll(
                    db,
                    sql: "SELECT fileIndex FROM packFileMapping WHERE infoHash = ? AND userCorrected",
                    arguments: [hash]))
            let incoming = mappings.filter { !corrected.contains($0.fileIndex) }
            try db.execute(
                sql: "DELETE FROM packFileMapping WHERE infoHash = ? AND NOT userCorrected",
                arguments: [hash])
            let now = Date()
            for var mapping in incoming {
                mapping.infoHash = hash
                mapping.userCorrected = false
                mapping.updatedAt = now
                try mapping.insert(db)
            }
        }
    }

    public func correct(
        infoHash: String, fileIndex: Int, episodeIds: [UUID], role: PackFileRole
    ) async throws {
        let hash = infoHash.lowercased()
        try await database.writer.write { db in
            var mapping = try PackFileMapping.fetchOne(db, key: ["infoHash": hash, "fileIndex": fileIndex])
                ?? PackFileMapping(infoHash: hash, fileIndex: fileIndex, path: "")
            mapping.episodeIds = episodeIds
            mapping.role = role
            mapping.userCorrected = true
            mapping.confidence = 1
            mapping.updatedAt = Date()
            try mapping.save(db)
        }
    }

    public func mappings(forEpisode episodeId: UUID) async throws -> [PackFileMapping] {
        try await database.writer.read { db in
            try PackFileMapping.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM packFileMapping m, json_each(m.episodeIds) j
                    WHERE j.value = ? ORDER BY m.infoHash, m.fileIndex
                    """,
                arguments: [episodeId.uuidString])
        }
    }

    public func removeAll(infoHash: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM packFileMapping WHERE infoHash = ?", arguments: [infoHash.lowercased()])
        }
    }
}
