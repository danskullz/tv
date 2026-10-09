import Foundation
import GRDB
import Testing

@testable import MarqueeCore

@Suite struct PersistenceRepositoryTests {
    let database: AppDatabase
    let library: GRDBLibraryRepository
    let title: Title

    init() async throws {
        database = try AppDatabase.inMemory()
        library = GRDBLibraryRepository(database)
        title = Title(kind: .series, tmdbId: 1, title: "Show")
        try await library.add(title, seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1), EpisodeDraft(episodeNumber: 2)])])
    }

    // MARK: History

    @Test func historyAppendsAndListsByEntityAndTitle() async throws {
        let history = GRDBHistoryRepository(database)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let grab = UUID()
        try await history.append(HistoryEvent(type: .grabbed, entityType: .grab, entityUUID: grab, titleId: title.id, payload: ["score": 120, "why": ["group": "ok"]], occurredAt: t0))
        try await history.append(HistoryEvent(type: .imported, entityType: .grab, entityUUID: grab, titleId: title.id, occurredAt: t0.addingTimeInterval(10)))
        try await history.append(HistoryEvent(type: .torrentAdded, entityType: .torrent, entityId: "abc123", occurredAt: t0.addingTimeInterval(5)))

        let byEntity = try await history.events(forEntity: .grab, id: grab, limit: 10)
        #expect(byEntity.map(\.type) == [.imported, .grabbed])
        #expect(byEntity[1].payload["score"] == 120)
        #expect(byEntity[1].payload["why"]?["group"] == "ok")
        #expect(try await history.events(forTitle: title.id, limit: 10).count == 2)
        #expect(try await history.events(forEntity: .torrent, id: "abc123", limit: 10).count == 1)
        #expect(try await history.recent(type: nil, limit: 10).map(\.type) == [.imported, .torrentAdded, .grabbed])
        #expect(try await history.recent(type: .grabbed, limit: 10).count == 1)
    }

    @Test func historySurvivesTitlePurge() async throws {
        let history = GRDBHistoryRepository(database)
        try await history.append(HistoryEvent(type: .titleAdded, entityType: .title, entityUUID: title.id, titleId: title.id))
        try await library.softDelete(titleId: title.id)
        try await library.purgeDeleted(before: .distantFuture)
        let events = try await history.recent(type: nil, limit: 10)
        #expect(events.count == 1 && events[0].titleId == nil)
    }

    // MARK: Watch state

    @Test func watchStateTracksProgressAndWatched() async throws {
        let watch = GRDBWatchStateRepository(database)
        let ep = UUID()
        try await watch.recordProgress(id: ep, titleId: title.id, position: 100, duration: 1000, watchedThreshold: 0.9)
        var state = try #require(try await watch.state(for: ep))
        #expect(state.positionSeconds == 100 && !state.watched)
        #expect(try await watch.continueWatching(limit: 10).map(\.id) == [ep])

        try await watch.recordProgress(id: ep, titleId: title.id, position: 950, duration: nil, watchedThreshold: 0.9)
        state = try #require(try await watch.state(for: ep))
        #expect(state.watched && state.durationSeconds == 1000)
        #expect(try await watch.continueWatching(limit: 10).isEmpty)

        try await watch.setWatched(id: ep, titleId: title.id, watched: false)
        state = try #require(try await watch.state(for: ep))
        #expect(!state.watched && state.positionSeconds == 0)
        #expect(try await watch.states(titleId: title.id).count == 1)
    }

    @Test func watchStateIsRemovedWithTitle() async throws {
        let watch = GRDBWatchStateRepository(database)
        let id = UUID()
        try await watch.setWatched(id: id, titleId: title.id, watched: true)
        try await library.softDelete(titleId: title.id)
        try await library.purgeDeleted(before: .distantFuture)
        #expect(try await watch.state(for: id) == nil)
    }

    // MARK: Torrents

    @Test func torrentLifecycle() async throws {
        let torrents = GRDBTorrentRepository(database)
        try await torrents.upsert(Torrent(infoHash: "ABCDEF", name: "Show.S01", savePath: "/tmp", titleId: title.id, isStreaming: true))
        var t = try #require(try await torrents.torrent(infoHash: "abcdef"))
        #expect(t.infoHash == "abcdef" && t.state == .queued && t.completedAt == nil)

        try await torrents.updateProgress(infoHash: "abcdef", progress: 0.5, state: .downloading, lastError: nil)
        t = try #require(try await torrents.torrent(infoHash: "abcdef"))
        #expect(t.progress == 0.5 && t.completedAt == nil && t.isStreaming)

        try await torrents.updateProgress(infoHash: "abcdef", progress: 1, state: .seeding, lastError: nil)
        t = try #require(try await torrents.torrent(infoHash: "abcdef"))
        let completed = try #require(t.completedAt)
        try await torrents.updateProgress(infoHash: "abcdef", progress: 1, state: .finished, lastError: nil)
        #expect(try await torrents.torrent(infoHash: "abcdef")?.completedAt == completed)

        #expect(try await torrents.torrents(in: [.downloading]).isEmpty)
        #expect(try await torrents.torrents(in: [.finished, .seeding]).count == 1)
        #expect(try await torrents.torrents(in: nil).count == 1)

        let session = StreamSession(infoHash: "ABCDEF", titleId: title.id, fileIndex: 3)
        try await torrents.save(session)
        var saved = session
        saved.state = .playing
        saved.firstFrameMs = 4200
        try await torrents.save(saved)
        let sessions = try await torrents.sessions(infoHash: "abcdef")
        #expect(sessions.count == 1 && sessions[0].firstFrameMs == 4200)

        try await torrents.remove(infoHash: "abcdef")
        #expect(try await torrents.torrent(infoHash: "abcdef") == nil)
        #expect(try await torrents.sessions(infoHash: "abcdef").isEmpty)
    }

    @Test func torrentObservationEmits() async throws {
        let torrents = GRDBTorrentRepository(database)
        var iterator = torrents.observeTorrents().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await torrents.upsert(Torrent(infoHash: "aa", name: "n", savePath: "/"))
        #expect(await iterator.next()?.count == 1)
    }

    // MARK: Pack mappings

    @Test func packMappingsPreserveUserCorrections() async throws {
        let packs = GRDBPackMappingRepository(database)
        let eps = try await library.episodes(titleId: title.id)
        let hash = "FEEDBEEF"
        let auto = [
            PackFileMapping(infoHash: hash, fileIndex: 0, path: "S01E01.mkv", episodeIds: [eps[0].id], confidence: 0.9),
            PackFileMapping(infoHash: hash, fileIndex: 1, path: "S01E02.mkv", episodeIds: [eps[1].id], confidence: 0.9),
            PackFileMapping(infoHash: hash, fileIndex: 2, path: "sample.mkv", role: .sample),
        ]
        try await packs.applyAutomatic(infoHash: hash, auto)
        #expect(try await packs.mappings(infoHash: "feedbeef").count == 3)

        // User says file 1 is actually both episodes.
        try await packs.correct(infoHash: hash, fileIndex: 1, episodeIds: [eps[0].id, eps[1].id], role: .episode)
        #expect(try await packs.mappings(forEpisode: eps[1].id).map(\.fileIndex) == [1])

        // A re-parse must not clobber the correction and drops stale automatic rows.
        try await packs.applyAutomatic(infoHash: hash, [
            PackFileMapping(infoHash: hash, fileIndex: 0, path: "S01E01.mkv", episodeIds: [eps[0].id]),
            PackFileMapping(infoHash: hash, fileIndex: 1, path: "S01E02.mkv", episodeIds: []),
        ])
        let after = try await packs.mappings(infoHash: hash)
        #expect(after.map(\.fileIndex) == [0, 1])
        #expect(after[1].userCorrected && after[1].episodeIds == [eps[0].id, eps[1].id])
        #expect(after[1].path == "S01E02.mkv")  // correction on an existing row keeps its path
        #expect(try await packs.mappings(forEpisode: eps[0].id).map(\.fileIndex) == [0, 1])

        // Corrections outlive the torrent row.
        try await packs.removeAll(infoHash: hash)
        #expect(try await packs.mappings(infoHash: hash).isEmpty)
    }

    // MARK: Records and constraints

    @Test func multiEpisodeMediaFileAndJSONColumnsRoundTrip() async throws {
        let eps = try await library.episodes(titleId: title.id)
        let file = MediaFile(
            titleId: title.id, path: "/lib/Show/S01E01-E02.mkv", size: 1 << 33, resolution: 1080,
            mediaInfo: MediaInfo(durationSeconds: 5400, videoCodec: "hevc", audioTracks: [.init(codec: "eac3", channels: 6, language: "en")]))
        try await database.writer.write { db in
            try file.insert(db)
            for e in eps { try MediaFileEpisode(mediaFileId: file.id, episodeId: e.id).insert(db) }
            try QualityProfile(name: "Balanced", items: [.init(quality: "WEB-1080p")], formatScores: ["x": 10]).insert(db)
            try CustomFormat(name: "HDR", specs: [.init(type: "hdr", value: "hdr10", required: true)]).insert(db)
            try Indexer(name: "Idx", baseURL: "http://localhost:9117", categories: [5000, 5030]).insert(db)
            try Release(guid: "g", title: "Show.S01.1080p", size: 100, isSeasonPack: true, parsed: ["season": 1, "group": "X"]).insert(db)
        }
        try await database.writer.read { db in
            let fetched = try #require(try MediaFile.fetchOne(db, key: file.id))
            #expect(fetched.size == 1 << 33)
            #expect(fetched.mediaInfo?.audioTracks.first?.codec == "eac3")
            let linked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mediaFileEpisode WHERE mediaFileId = ?", arguments: [file.id])
            #expect(linked == 2)
            #expect(try QualityProfile.fetchOne(db)?.formatScores == ["x": 10])
            #expect(try CustomFormat.fetchOne(db)?.specs.first?.required == true)
            #expect(try Indexer.fetchOne(db)?.categories == [5000, 5030])
            #expect(try Release.fetchOne(db)?.parsed["season"] == 1)
        }
    }

    @Test func remainingRecordsPersist() async throws {
        let eps = try await library.episodes(titleId: title.id)
        try await database.writer.write { db in
            let folder = RootFolder(path: "/media/tv", mediaKind: .series)
            try folder.insert(db)
            try DelayProfile(name: "Default", delayMinutes: 60).insert(db)
            let tag = Tag(label: "Kids")
            try tag.insert(db)
            try TitleTag(titleId: title.id, tagId: tag.id).insert(db)
            let indexer = Indexer(name: "I", baseURL: "http://x", flareSolverrURL: "http://localhost:8191")
            try indexer.insert(db)
            try IndexerTag(indexerId: indexer.id, tagId: tag.id).insert(db)
            #expect(try Indexer.fetchOne(db, key: indexer.id)?.flareSolverrURL == "http://localhost:8191")
            try Grab(titleId: title.id, episodeId: eps[0].id, releaseTitle: "r", origin: .stream, outcome: .grabbed, score: 5, reason: ["picked": "seeders"]).insert(db)
            try BlocklistEntry(titleId: title.id, releaseTitle: "bad", infoHash: "dead", reason: "hash failed").insert(db)
            try HealthIssue(code: "disk.low", severity: .warning, message: "Disk almost full").insert(db)
            try SubtitleTrack(titleId: title.id, episodeId: eps[0].id, language: "en", format: "srt", origin: .downloaded).insert(db)
            #expect(try Tag.fetchOne(db, key: ["label": "kids"]) != nil)  // NOCASE unique
            #expect(throws: DatabaseError.self) { try Tag(label: "KIDS").insert(db) }
        }
    }

    @Test func foreignKeysAreEnforced() async throws {
        await #expect(throws: DatabaseError.self) {
            try await database.writer.write { try Season(titleId: UUID(), seasonNumber: 1).insert($0) }
        }
    }
}
