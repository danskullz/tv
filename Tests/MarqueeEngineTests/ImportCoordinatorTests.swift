import Foundation
import GRDB
import MarqueeCore
import MarqueeEngine
import Testing

@Suite struct ImportCoordinatorTests {
    @Test func probesCommittedVideoFixtureWithAVFoundation() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Tests/MarqueeCoreTests/Fixtures/Import/test-clip.mp4")
        let info = try await AVFoundationMediaProbe().probe(fixture, timeout: .seconds(20))
        try MediaProbeValidation.validate(info, expectedRuntimeSeconds: nil, minimumDurationSeconds: 0.1)
        #expect(info.durationSeconds ?? 0 > 0)
        #expect(info.container == "mp4")
    }

    @Test func importsPerEpisodeIsIdempotentAndCanBeUndone() async throws {
        let fixture = try importFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try AppDatabase.inMemory()
        let (title, episode) = try await importTestLibrary(database)
        let coordinator = ImportCoordinator(
            database: database, probe: FixedImportProbe(), rootDirectory: { fixture.library },
            configuration: { ImportCoordinatorConfiguration(transferStrategy: .copy) })
        let source = fixture.downloads.appendingPathComponent("Demo.Show.S01E01.1080p.WEB-DL.mkv")
        try Data("a valid video fixture".utf8).write(to: source)
        let event = CompletedDownload(
            infoHash: "abcdef", savePath: fixture.downloads.path, releaseName: "Demo.Show.S01E01.1080p.WEB-DL-GRP",
            files: [CompletedFile(
                path: source.lastPathComponent, size: Int64(try Data(contentsOf: source).count),
                target: .episodes(titleID: title.id, refs: [EpisodeRef(season: 1, episode: 1)]))])

        let imported = try await coordinator.process(event)
        guard case .imported(let path, let fileID, .copy, []) = try #require(imported.first) else {
            Issue.record("expected one completed import: \(imported)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let resolver = LocalMediaResolver(database: database)
        #expect(try await resolver.file(titleID: title.id, episodeID: episode.id) == path)
        let repeated = try await coordinator.process(event)
        if case .skipped(_, let reason) = repeated.first { #expect(reason.contains("already imported")) }
        else { Issue.record("the same torrent file should be idempotent") }
        let rows = try await database.writer.read { try MediaFile.fetchAll($0) }
        #expect(rows.map(\.id) == [fileID])

        let history = try await database.writer.read { try HistoryEvent.fetchOne($0, sql: "SELECT * FROM historyEvent WHERE entityId = ?", arguments: [fileID.uuidString]) }
        try await coordinator.revertImport(historyEventID: try #require(history?.id))
        #expect(try await resolver.file(titleID: title.id, episodeID: episode.id) == nil)
        #expect(try await database.writer.read { try MediaFile.fetchCount($0) } == 0)
    }

    @Test func concurrentDuplicateDownloadsOnlyImportOnce() async throws {
        let fixture = try importFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try AppDatabase.inMemory()
        let (title, _) = try await importTestLibrary(database)
        let coordinator = ImportCoordinator(
            database: database, probe: FixedImportProbe(), rootDirectory: { fixture.library },
            configuration: { ImportCoordinatorConfiguration(transferStrategy: .copy) })
        let source = fixture.downloads.appendingPathComponent("Demo.Show.S01E01.1080p.WEB-DL.mkv")
        try Data("a valid video fixture".utf8).write(to: source)
        let event = CompletedDownload(
            infoHash: "concurrent-duplicate", savePath: fixture.downloads.path,
            releaseName: "Demo.Show.S01E01.1080p.WEB-DL-GRP",
            files: [CompletedFile(
                path: source.lastPathComponent,
                target: .episodes(titleID: title.id, refs: [EpisodeRef(season: 1, episode: 1)]))])

        let outcomes = try await withThrowingTaskGroup(of: [ImportCoordinatorEvent].self) { group in
            group.addTask { try await coordinator.process(event) }
            group.addTask { try await coordinator.process(event) }
            var results: [[ImportCoordinatorEvent]] = []
            for try await result in group { results.append(result) }
            return results
        }
        let events = outcomes.compactMap(\.first)
        let imported = events.filter { if case .imported = $0 { true } else { false } }
        let skipped = events.filter { if case .skipped = $0 { true } else { false } }
        #expect(imported.count == 1)
        #expect(skipped.count == 1)
        #expect(try await database.writer.read { try MediaFile.fetchCount($0) } == 1)
    }

    @Test func verifiedUpgradeTrashesOldFileAndUndoRestoresIt() async throws {
        let fixture = try importFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try AppDatabase.inMemory()
        let (title, episode) = try await importTestLibrary(database)
        let coordinator = ImportCoordinator(
            database: database, probe: FixedImportProbe(), rootDirectory: { fixture.library },
            configuration: { ImportCoordinatorConfiguration(transferStrategy: .copy) })
        let resolver = LocalMediaResolver(database: database)

        func download(_ name: String, hash: String, quality: String) throws -> CompletedDownload {
            let url = fixture.downloads.appendingPathComponent(name)
            try Data(("fixture " + quality).utf8).write(to: url)
            let bytes = try Data(contentsOf: url).count
            return CompletedDownload(
                infoHash: hash, savePath: fixture.downloads.path,
                releaseName: "Demo.Show.S01E01.\(quality)-GRP",
                files: [CompletedFile(
                    path: name, size: Int64(bytes), target: .episodes(
                        titleID: title.id, refs: [EpisodeRef(season: 1, episode: 1)]))])
        }

        let first = try download("Demo.Show.S01E01.720p.WEB-DL.mkv", hash: "first", quality: "720p.WEB-DL")
        let firstResult = try await coordinator.process(first)
        guard case .imported(let oldPath, _, _, []) = try #require(firstResult.first) else {
            Issue.record("initial import failed: \(firstResult)")
            return
        }
        let second = try download("Demo.Show.S01E01.1080p.BluRay.mkv", hash: "second", quality: "1080p.BluRay")
        let secondResult = try await coordinator.process(second)
        guard case .imported(let newPath, let newID, _, let replaced) = try #require(secondResult.first) else {
            Issue.record("upgrade failed: \(secondResult)")
            return
        }
        #expect(replaced.count == 1)
        #expect(!FileManager.default.fileExists(atPath: oldPath.path))
        #expect(try await resolver.file(titleID: title.id, episodeID: episode.id) == newPath)

        let history = try await database.writer.read {
            try HistoryEvent.fetchOne($0, sql: "SELECT * FROM historyEvent WHERE entityId = ?", arguments: [newID.uuidString])
        }
        try await coordinator.revertImport(historyEventID: try #require(history?.id))
        #expect(FileManager.default.fileExists(atPath: oldPath.path))
        #expect(!FileManager.default.fileExists(atPath: newPath.path))
        #expect(try await resolver.file(titleID: title.id, episodeID: episode.id) == oldPath)
        #expect(try await database.writer.read { try MediaFile.fetchCount($0) } == 1)
    }

    @Test func probeFailureLeavesSourceUntouchedAndDoesNotPublishAnImport() async throws {
        let fixture = try importFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try AppDatabase.inMemory()
        let (title, _) = try await importTestLibrary(database)
        let coordinator = ImportCoordinator(
            database: database, probe: FailingImportProbe(), rootDirectory: { fixture.library },
            configuration: { ImportCoordinatorConfiguration(transferStrategy: .copy) })
        let source = fixture.downloads.appendingPathComponent("Demo.Show.S01E01.1080p.WEB-DL.mkv")
        try Data("not actually a video".utf8).write(to: source)
        let event = CompletedDownload(
            infoHash: "bad-probe", savePath: fixture.downloads.path, releaseName: "Demo.Show.S01E01.1080p.WEB-DL",
            files: [CompletedFile(
                path: source.lastPathComponent,
                target: .episodes(titleID: title.id, refs: [EpisodeRef(season: 1, episode: 1)]))])

        let result = try await coordinator.process(event)
        if case .failed = result.first {} else { Issue.record("a probe failure must reject the import: \(result)") }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await database.writer.read { try MediaFile.fetchCount($0) } == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.path))
    }

    @Test func rejectsPathsThatEscapeTheDownloadRoot() async throws {
        let fixture = try importFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let outside = fixture.directory.appendingPathComponent("outside.mkv")
        try Data("leave this alone".utf8).write(to: outside)
        let coordinator = ImportCoordinator(
            database: try AppDatabase.inMemory(), probe: FixedImportProbe(), rootDirectory: { fixture.library })
        let event = CompletedDownload(
            infoHash: "path-traversal", savePath: fixture.downloads.path, releaseName: "unsafe",
            files: [CompletedFile(path: "../outside.mkv", target: .unmapped)])

        let result = try await coordinator.process(event)
        if case .failed = result.first {} else { Issue.record("an outside path should be rejected: \(result)") }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "leave this alone")
    }
}

private struct FixedImportProbe: MediaProbing {
    func probe(_ url: URL, timeout: Duration) async throws -> MediaInfo {
        MediaInfo(durationSeconds: 1_800, container: url.pathExtension, videoCodec: "h264", width: 1920, height: 1080)
    }
}

private struct FailingImportProbe: MediaProbing {
    func probe(_ url: URL, timeout: Duration) async throws -> MediaInfo {
        throw MediaProbeError.invalidMedia
    }
}

private func importTestLibrary(_ database: AppDatabase) async throws -> (Title, Episode) {
    let title = Title(kind: .series, title: "Demo Show", year: 2024)
    try await GRDBLibraryRepository(database).add(
        title, seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1, title: "Pilot", runtime: 30)])])
    let episode = try #require(try await GRDBLibraryRepository(database).episodes(titleId: title.id).first)
    return (title, episode)
}

private func importFixture() throws -> (directory: URL, downloads: URL, library: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-import-engine-\(UUID())")
    let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
    let library = directory.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    return (directory, downloads, library)
}
