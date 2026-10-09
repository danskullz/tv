import Foundation
import MarqueeCore
import MarqueeEngine
import Synchronization
import Testing
import TorrentEngine

@Suite struct DownloadManagerTests {
    @Test func respectsDownloadSlotsAndPausesForBattery() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: health,
            configuration: .init(maximumActiveDownloads: 1, maximumActiveSeeds: 1, reservedFreeSpaceBytes: 0, pauseOnBattery: true),
            freeSpace: { _ in Int64.max })
        try await manager.start()

        let firstHash = String(repeating: "1", count: 40)
        let secondHash = String(repeating: "2", count: 40)
        let first = makeDownloadRequest(hash: firstHash, title: "First")
        let second = makeDownloadRequest(hash: secondHash, title: "Second")
        try await addTitle(for: first, to: database)
        try await addTitle(for: second, to: database)
        _ = try await manager.add(first)
        _ = try await manager.add(second)
        #expect(engine.addedHashes == [firstHash])
        #expect(try await repository.torrent(infoHash: firstHash)?.state == .downloading)
        #expect(try await repository.torrent(infoHash: secondHash)?.state == .queued)

        try await manager.setOnBattery(true)
        let paused = try #require(await repository.torrent(infoHash: firstHash))
        #expect(paused.state == .paused)
        #expect(paused.pausedForBattery)
        #expect(!paused.pausedByUser)

        try await manager.setOnBattery(false)
        let resumed = try #require(await repository.torrent(infoHash: firstHash))
        #expect(resumed.state == .downloading)
        #expect(!resumed.pausedForBattery)
        await manager.stop()
    }

    @Test func refusesInsufficientSpaceAndPersistsHealthIssue() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let manager = DownloadManager(
            engine: FakeManagedTorrentEngine(), torrents: repository, health: health,
            configuration: .init(reservedFreeSpaceBytes: 50), freeSpace: { _ in 100 })
        let request = makeDownloadRequest(hash: String(repeating: "3", count: 40), title: "Too large", size: 60)
        do {
            _ = try await manager.add(request)
            Issue.record("Expected the free-space guard to refuse the grab")
        } catch let error as DownloadManagerError {
            #expect(error == .insufficientSpace(required: 110, available: 100))
        }
        #expect(try await repository.torrent(infoHash: request.release.infoHash!) == nil)
        #expect(try await health.active().map(\.code) == ["diskSpaceLow"])
    }

    @Test func resumeDataRestoresIntoTheNextSession() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let hash = String(repeating: "4", count: 40)
        let firstEngine = FakeManagedTorrentEngine()
        let firstManager = DownloadManager(
            engine: firstEngine, torrents: repository, health: health,
            configuration: .init(reservedFreeSpaceBytes: 0), freeSpace: { _ in Int64.max })
        try await firstManager.start()
        let request = makeDownloadRequest(hash: hash, title: "Resume me")
        try await addTitle(for: request, to: database)
        _ = try await firstManager.add(request)
        await firstManager.stop()

        let nextEngine = FakeManagedTorrentEngine()
        let nextManager = DownloadManager(
            engine: nextEngine, torrents: repository, health: health,
            configuration: .init(reservedFreeSpaceBytes: 0), freeSpace: { _ in Int64.max })
        try await nextManager.start()
        #expect(nextEngine.resumeAdds == [hash])
        #expect(try await repository.torrent(infoHash: hash)?.state == .downloading)
        await nextManager.stop()
    }

    @Test func ratioGoalStopsSeedingWithoutDeletingImportedFiles() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let titleID = UUID()
        try await GRDBLibraryRepository(database).add(Title(id: titleID, kind: .movie, title: "Seed goal"), seasons: [])
        let hash = String(repeating: "5", count: 40)
        let torrent = Torrent(
            infoHash: hash, name: "Seed goal", state: .seeding,
            savePath: FileManager.default.temporaryDirectory.path, size: 100, progress: 1,
            titleId: titleID, completedAt: Date().addingTimeInterval(-3600), uploadedBytes: 200,
            seedRatioGoal: 2, importedAt: Date())
        try await repository.upsert(torrent)
        try await repository.savePayload(infoHash: hash, TorrentPayload(kind: .resume, data: Data(hash.utf8)))

        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: health,
            configuration: .init(reservedFreeSpaceBytes: 0),
            freeSpace: { _ in Int64.max })
        try await manager.start()
        try await manager.refreshPolicies()
        let stopped = try #require(await repository.torrent(infoHash: hash))
        #expect(stopped.state == MarqueeCore.TorrentState.finished)
        #expect(stopped.importedAt != nil)
        #expect(try await repository.torrent(infoHash: hash) != nil)
        await manager.stop()
    }
}

private func makeDownloadRequest(hash: String, title: String, size: Int64 = 20) -> DownloadRequest {
    let magnet = "magnet:?xt=urn:btih:\(hash)&dn=\(title.replacingOccurrences(of: " ", with: "+"))"
    let release = IndexerRelease(
        indexerID: UUID(), title: title, guid: hash, magnetURL: URL(string: magnet), infoHash: hash, size: size)
    return DownloadRequest(
        source: .magnet(magnet), release: release, titleId: UUID(),
        savePath: FileManager.default.temporaryDirectory.appending(path: "Marquee-DownloadManager-\(UUID())"))
}

private func addTitle(for request: DownloadRequest, to database: AppDatabase) async throws {
    try await GRDBLibraryRepository(database).add(
        Title(id: request.titleId, kind: .movie, title: request.release.title), seasons: [])
}

private final class FakeManagedTorrentEngine: ManagedTorrentEngine, @unchecked Sendable {
    private struct State {
        var addedHashes: [String] = []
        var resumeAdds: [String] = []
        var paused: Set<String> = []
        var statuses: [String: TorrentStatus] = [:]
        var downloadLimits: [String: Int] = [:]
        var uploadLimits: [String: Int] = [:]
        var globalDownloadLimit: Int?
        var globalUploadLimit: Int?
    }

    private let state = Mutex(State())
    private let stream: AsyncStream<TorrentEvent>
    private let continuation: AsyncStream<TorrentEvent>.Continuation

    init() {
        var continuation: AsyncStream<TorrentEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var addedHashes: [String] { state.withLock { $0.addedHashes } }
    var resumeAdds: [String] { state.withLock { $0.resumeAdds } }
    func events() -> AsyncStream<TorrentEvent> { stream }

    func addMagnet(_ uri: String, savePath: String, paused: Bool) async throws -> TorrentID {
        guard let components = URLComponents(string: uri),
            let hash = components.queryItems?.first(where: { $0.name == "xt" })?.value?.split(separator: ":").last.map(String.init)
        else { throw TorrentError.invalidArgument }
        let id = TorrentID(hex: hash.lowercased())
        state.withLock { s in
            s.addedHashes.append(id.hex)
            if paused { s.paused.insert(id.hex) }
            s.statuses[id.hex] = status(paused: paused)
        }
        return id
    }

    func addTorrent(_ data: Data, savePath: String, paused: Bool) async throws -> TorrentID {
        throw TorrentError.invalidArgument
    }

    func addResumeData(_ data: Data, savePath: String, paused: Bool) async throws -> TorrentID {
        guard let hash = String(data: data, encoding: .utf8) else { throw TorrentError.invalidArgument }
        let id = TorrentID(hex: hash)
        state.withLock { s in
            s.resumeAdds.append(hash)
            if paused { s.paused.insert(hash) }
            s.statuses[hash] = status(paused: paused)
        }
        return id
    }

    func pause(_ id: TorrentID) async throws {
        state.withLock { s in s.paused.insert(id.hex); s.statuses[id.hex] = status(paused: true) }
    }

    func resume(_ id: TorrentID) async throws {
        state.withLock { s in s.paused.remove(id.hex); s.statuses[id.hex] = status(paused: false) }
    }

    func remove(_ id: TorrentID, deleteFiles: Bool) async throws {
        state.withLock { s in s.statuses.removeValue(forKey: id.hex); s.paused.remove(id.hex) }
    }

    func status(_ id: TorrentID) async throws -> TorrentStatus {
        try state.withLock { s in
            guard let status = s.statuses[id.hex] else { throw TorrentError.notFound }
            return status
        }
    }

    func saveResumeData(_ id: TorrentID) async throws -> Data { Data(id.hex.utf8) }
    func setDownloadLimit(_ id: TorrentID, bytesPerSecond: Int) async throws { state.withLock { $0.downloadLimits[id.hex] = bytesPerSecond } }
    func setUploadLimit(_ id: TorrentID, bytesPerSecond: Int) async throws { state.withLock { $0.uploadLimits[id.hex] = bytesPerSecond } }
    func setGlobalDownloadLimit(_ bytesPerSecond: Int?) async throws { state.withLock { $0.globalDownloadLimit = bytesPerSecond } }
    func setGlobalUploadLimit(_ bytesPerSecond: Int?) async throws { state.withLock { $0.globalUploadLimit = bytesPerSecond } }
    func emit(_ event: TorrentEvent) { continuation.yield(event) }

    private func status(paused: Bool) -> TorrentStatus {
        TorrentStatus(
            state: .downloading, isPaused: paused, hasMetadata: true, hasError: false,
            progress: 0, totalWanted: 100, totalWantedDone: 0, payloadDownloaded: 0,
            payloadUploaded: 0, downloadRate: 0, uploadRate: 0, peerCount: 0,
            seedCount: 0, piecesHave: 0, pieceCount: 1)
    }
}
