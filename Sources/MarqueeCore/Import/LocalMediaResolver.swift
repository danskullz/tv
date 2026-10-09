import Foundation
import GRDB

/// Resolves an imported movie or episode to an existing on-disk file without searching the network.
public struct LocalMediaResolver: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func file(titleID: UUID, episodeID: UUID? = nil) async throws -> URL? {
        let paths = try await database.writer.read { db -> [String] in
            if let episodeID {
                return try String.fetchAll(
                    db,
                    sql: """
                        SELECT mediaFile.path FROM mediaFile
                        JOIN mediaFileEpisode ON mediaFileEpisode.mediaFileId = mediaFile.id
                        WHERE mediaFile.titleId = ? AND mediaFileEpisode.episodeId = ?
                        ORDER BY mediaFile.importedAt DESC, mediaFile.createdAt DESC, mediaFile.id DESC
                        """,
                    arguments: [titleID, episodeID])
            } else {
                return try String.fetchAll(
                    db,
                    sql: "SELECT path FROM mediaFile WHERE titleId = ? ORDER BY importedAt DESC, createdAt DESC, id DESC",
                    arguments: [titleID])
            }
        }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }
}
