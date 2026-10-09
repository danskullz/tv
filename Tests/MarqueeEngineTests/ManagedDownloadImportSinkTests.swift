import Foundation
import GRDB
import MarqueeCore
import Testing
import TorrentEngine
@testable import MarqueeEngine

@Suite struct ManagedDownloadImportSinkTests {
    @Test func finishedMovieIsImportedIntoTheLibrary() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appending(path: "Tests/MarqueeCoreTests/Fixtures/Import/test-clip.mp4")
        let work = FileManager.default.temporaryDirectory.appending(path: "Marquee-import-sink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: work) }
        let downloads = work.appending(path: "downloads", directoryHint: .isDirectory)
        let libraryRoot = work.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = downloads.appending(path: "Example.Movie.2024.1080p.WEB-DL.mkv")
        try FileManager.default.copyItem(at: fixture, to: source)

        let database = try AppDatabase.inMemory()
        let library = GRDBLibraryRepository(database)
        let title = try await library.add(Title(kind: .movie, title: "Example Movie", year: 2024), seasons: [])
        let importer = ImportCoordinator(
            database: database, probe: SinkImportProbe(), rootDirectory: { libraryRoot },
            configuration: { ImportCoordinatorConfiguration(transferStrategy: .copy, minimumDurationSeconds: 0.1) })
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let metadata = TorrentMetadata(
            name: "Example Movie", totalSize: size, pieceLength: 16_384, pieceCount: 1,
            files: [TorrentFile(index: 0, path: source.lastPathComponent, size: size, offset: 0, priority: 4)])
        let sink = ManagedDownloadImportSink(
            metadataProvider: { _ in metadata }, importer: importer, library: library)
        let torrent = Torrent(
            infoHash: String(repeating: "a", count: 40), name: "Example.Movie.2024.1080p.WEB-DL",
            state: .seeding, savePath: downloads.path, size: size, titleId: title.id)

        let completion = DownloadCompletion(torrent: torrent)
        #expect(try await sink.completed(completion))
        #expect(try await sink.completed(completion))
        #expect(try await database.writer.read { try MediaFile.fetchCount($0) } == 1)
    }

    @Test func mapsMovieAndMultiEpisodeFilesWithoutGuessing() {
        let titleID = UUID()
        let movie = Title(id: titleID, kind: .movie, title: "Example")
        #expect(ManagedDownloadImportSink.target(
            path: "Example.2020.mkv", title: movie, episodes: [], mediaFileCount: 1,
            requestedEpisodeIDs: []) == .movie(titleID: titleID))

        let seriesID = UUID()
        let seasonID = UUID()
        let first = Episode(id: UUID(), titleId: seriesID, seasonId: seasonID, seasonNumber: 1, episodeNumber: 3)
        let second = Episode(id: UUID(), titleId: seriesID, seasonId: seasonID, seasonNumber: 1, episodeNumber: 4)
        let third = Episode(id: UUID(), titleId: seriesID, seasonId: seasonID, seasonNumber: 1, episodeNumber: 5)
        let series = Title(id: seriesID, kind: .series, title: "Example")
        #expect(ManagedDownloadImportSink.target(
            path: "Example.S01E03-E04.mkv", title: series, episodes: [first, second, third],
            mediaFileCount: 3, requestedEpisodeIDs: []) == .episodeIDs([first.id, second.id]))
        #expect(ManagedDownloadImportSink.target(
            path: "unparseable.mkv", title: series, episodes: [first], mediaFileCount: 2,
            requestedEpisodeIDs: []) == .unmapped)
    }
}

private struct SinkImportProbe: MediaProbing {
    func probe(_ url: URL, timeout: Duration) async throws -> MediaInfo {
        MediaInfo(durationSeconds: 120, container: url.pathExtension, videoCodec: "h264", width: 640, height: 360)
    }
}
