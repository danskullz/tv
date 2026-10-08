import Foundation
import GRDB

public protocol TorrentRepository: Sendable {
    /// Inserts or replaces the torrent row.
    func upsert(_ torrent: Torrent) async throws
    func torrent(infoHash: String) async throws -> Torrent?
    func torrents(in states: [TorrentState]?) async throws -> [Torrent]
    /// Cheap engine-mirror update that touches only progress, state and error. Stamps
    /// `completedAt` the first time the state becomes `.finished` or `.seeding`.
    func updateProgress(
        infoHash: String, progress: Double, state: TorrentState, lastError: String?
    ) async throws
    /// Removes the torrent and its stream sessions. Pack mappings are kept on purpose.
    func remove(infoHash: String) async throws
    func observeTorrents() -> AsyncStream<[Torrent]>

    func save(_ session: StreamSession) async throws
    func sessions(infoHash: String) async throws -> [StreamSession]
}

public struct GRDBTorrentRepository: TorrentRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func upsert(_ torrent: Torrent) async throws {
        var torrent = torrent
        torrent.updatedAt = Date()
        try await database.writer.write { [torrent] in try torrent.save($0) }
    }

    public func torrent(infoHash: String) async throws -> Torrent? {
        try await database.writer.read { try Torrent.fetchOne($0, key: infoHash.lowercased()) }
    }

    public func torrents(in states: [TorrentState]? = nil) async throws -> [Torrent] {
        try await database.writer.read { db in
            var request = Torrent.all()
            if let states { request = request.filter(states.contains(Column("state"))) }
            return try request.order(Column("addedAt").desc).fetchAll(db)
        }
    }

    public func updateProgress(
        infoHash: String, progress: Double, state: TorrentState, lastError: String? = nil
    ) async throws {
        try await database.writer.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE torrent SET progress = ?, state = ?, lastError = ?, updatedAt = ?,
                        completedAt = CASE WHEN completedAt IS NULL AND ? IN ('finished', 'seeding')
                                           THEN ? ELSE completedAt END
                    WHERE infoHash = ?
                    """,
                arguments: [progress, state, lastError, now, state.rawValue, now, infoHash.lowercased()])
        }
    }

    public func remove(infoHash: String) async throws {
        try await database.writer.write { _ = try Torrent.deleteOne($0, key: infoHash.lowercased()) }
    }

    public func observeTorrents() -> AsyncStream<[Torrent]> {
        database.observe { try Torrent.order(Column("addedAt").desc).fetchAll($0) }
    }

    public func save(_ session: StreamSession) async throws {
        var session = session
        session.updatedAt = Date()
        try await database.writer.write { [session] in try session.save($0) }
    }

    public func sessions(infoHash: String) async throws -> [StreamSession] {
        try await database.writer.read {
            try StreamSession.filter(Column("infoHash") == infoHash.lowercased())
                .order(Column("startedAt").desc).fetchAll($0)
        }
    }
}
