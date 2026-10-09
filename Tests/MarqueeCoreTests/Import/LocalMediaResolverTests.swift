import Foundation
import Testing

@testable import MarqueeCore

@Suite struct LocalMediaResolverTests {
    @Test func fallsBackToAnOlderExistingEpisodeFileWhenNewestRecordIsStale() async throws {
        let database = try AppDatabase.inMemory()
        let title = try await GRDBLibraryRepository(database).add(
            Title(kind: .series, title: "Resolver Show", year: 2024),
            seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1, title: "Pilot")])])
        let episode = try #require(try await GRDBLibraryRepository(database).episodes(titleId: title.id).first)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-local-media-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("older.mkv")
        let missing = directory.appendingPathComponent("newer.mkv")
        try Data("existing media".utf8).write(to: existing)
        let now = Date()
        let oldFile = MediaFile(
            titleId: title.id, path: existing.path, importedAt: now.addingTimeInterval(-60), createdAt: now)
        let staleFile = MediaFile(titleId: title.id, path: missing.path, importedAt: now, createdAt: now)
        try await database.writer.write { db in
            try oldFile.insert(db)
            try MediaFileEpisode(mediaFileId: oldFile.id, episodeId: episode.id).insert(db)
            try staleFile.insert(db)
            try MediaFileEpisode(mediaFileId: staleFile.id, episodeId: episode.id).insert(db)
        }

        #expect(try await LocalMediaResolver(database: database).file(titleID: title.id, episodeID: episode.id) == existing)
    }
}
