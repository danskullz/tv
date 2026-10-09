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

    @Test func failedCompletionImportRemainsVisibleAndIsNotBlocklisted() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let blocklist = GRDBBlocklistRepository(database)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: health, blocklist: blocklist,
            configuration: .init(reservedFreeSpaceBytes: 0), freeSpace: { _ in Int64.max })
        try await manager.start()
        let hash = String(repeating: "f", count: 40)
        let request = makeDownloadRequest(hash: hash, title: "Import failure")
        try await addTitle(for: request, to: database)
        _ = try await manager.add(request)
        engine.emit(.finished(TorrentID(hex: hash)))

        var completed: Torrent?
        for _ in 0..<100 {
            completed = try await repository.torrent(infoHash: hash)
            if completed?.state == .seeding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try #require(completed).importedAt == nil)
        #expect(try await health.active().contains { $0.code == "importFailed" && $0.entityId == hash })
        #expect(try await blocklist.entries(titleId: request.titleId).isEmpty)
        await manager.stop()
    }

    /// Piece-progress and metadata events carry no queue information: a burst of them must not
    /// pause, resume, remove or start anything. Completion still advances the queue.
    @Test func nonQueueEventsDoNotTouchTheEngineOrTheQueue() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: health,
            configuration: .init(maximumActiveDownloads: 1, maximumActiveSeeds: 1, reservedFreeSpaceBytes: 0),
            freeSpace: { _ in Int64.max })
        try await manager.start()
        let firstHash = String(repeating: "4", count: 40)
        let secondHash = String(repeating: "5", count: 40)
        let first = makeDownloadRequest(hash: firstHash, title: "First")
        let second = makeDownloadRequest(hash: secondHash, title: "Second")
        try await addTitle(for: first, to: database)
        try await addTitle(for: second, to: database)
        _ = try await manager.add(first)
        _ = try await manager.add(second)
        #expect(engine.addedHashes == [firstHash])

        let id = TorrentID(hex: firstHash)
        for piece in 0..<50 {
            engine.emit(.pieceFinished(id, piece: piece))
            engine.emit(.metadataReceived(id))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.addedHashes == [firstHash])
        #expect(try await repository.torrent(infoHash: firstHash)?.state == .downloading)
        #expect(try await repository.torrent(infoHash: secondHash)?.state == .queued)

        engine.emit(.finished(id))
        var secondRow: Torrent?
        for _ in 0..<200 {
            secondRow = try await repository.torrent(infoHash: secondHash)
            if secondRow?.state == .downloading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(secondRow?.state == .downloading)
        #expect(engine.addedHashes == [firstHash, secondHash])
        await manager.stop()
    }

    @Test func refusesSpaceArithmeticOverflow() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let manager = DownloadManager(
            engine: FakeManagedTorrentEngine(), torrents: repository,
            health: GRDBHealthIssueRepository(database),
            configuration: .init(reservedFreeSpaceBytes: 1), freeSpace: { _ in Int64.max })
        let request = makeDownloadRequest(hash: String(repeating: "9", count: 40), title: "Overflow", size: .max)
        do {
            _ = try await manager.add(request)
            Issue.record("Expected overflow to refuse the grab even with the maximum reported free space")
        } catch let error as DownloadManagerError {
            #expect(error == .insufficientSpace(required: .max, available: .max))
        }
        #expect(try await repository.torrent(infoHash: request.release.infoHash!) == nil)
    }

    @Test func initialBatterySamplePausesNewDownloadsUntilACReturns() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let power = FakePowerSourceMonitor(initialOnBattery: true)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: GRDBHealthIssueRepository(database),
            powerSource: power,
            configuration: .init(reservedFreeSpaceBytes: 0, pauseOnBattery: true),
            freeSpace: { _ in Int64.max })
        try await manager.start()
        let request = makeDownloadRequest(hash: String(repeating: "a", count: 40), title: "Battery")
        try await addTitle(for: request, to: database)
        _ = try await manager.add(request)
        let onBattery = try #require(await repository.torrent(infoHash: request.release.infoHash!))
        #expect(onBattery.pausedForBattery)
        #expect(onBattery.state == .paused)
        #expect(engine.addedHashes.isEmpty)

        await power.emit(false)
        let onAC = try #require(await repository.torrent(infoHash: request.release.infoHash!))
        #expect(!onAC.pausedForBattery)
        #expect(onAC.state == .downloading)
        #expect(engine.addedHashes == [request.release.infoHash!])
        await manager.stop()
        #expect(await power.stopCount == 1)
    }

    @Test func batteryEventsPauseAndResumeActiveDownloadsAndStopObserver() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let power = FakePowerSourceMonitor(initialOnBattery: false)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: GRDBHealthIssueRepository(database),
            powerSource: power,
            configuration: .init(reservedFreeSpaceBytes: 0, pauseOnBattery: true),
            freeSpace: { _ in Int64.max })
        try await manager.start()
        let request = makeDownloadRequest(hash: String(repeating: "b", count: 40), title: "Power changes")
        try await addTitle(for: request, to: database)
        _ = try await manager.add(request)

        await power.emit(true)
        let paused = try #require(await repository.torrent(infoHash: request.release.infoHash!))
        #expect(paused.state == .paused)
        #expect(paused.pausedForBattery)
        await power.emit(false)
        let resumed = try #require(await repository.torrent(infoHash: request.release.infoHash!))
        #expect(resumed.state == .downloading)
        #expect(!resumed.pausedForBattery)

        await manager.stop()
        #expect(await power.stopCount == 1)
        await power.emit(true)
        #expect(try await repository.torrent(infoHash: request.release.infoHash!)?.state == .downloading)
    }

    @Test func retriesAnErroredTorrentFromItsStoredPayload() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let hash = String(repeating: "6", count: 40)
        let request = makeDownloadRequest(hash: hash, title: "Retry me")
        try await addTitle(for: request, to: database)
        let storedMagnet = "magnet:?xt=urn:btih:\(hash)&tr=https%3A%2F%2Ftracker.example%2Fannounce"
        try await repository.upsert(Torrent(
            infoHash: hash, name: request.release.title, state: .error, savePath: request.savePath.path,
            size: request.release.size, titleId: request.titleId, lastError: "tracker failure"))
        try await repository.savePayload(infoHash: hash, .magnet(storedMagnet))
        _ = try await health.report(
            code: "diskSpaceLow", severity: .error, message: "free space was low",
            fixAction: "chooseDownloadFolder", entityId: request.titleId.uuidString)

        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: health,
            configuration: .init(reservedFreeSpaceBytes: 0), freeSpace: { _ in Int64.max })
        try await manager.start()
        let retried = try await manager.add(request)
        #expect(retried.state == .downloading)
        #expect(retried.lastError == nil)
        #expect(engine.addedHashes == [hash])
        #expect(engine.magnetURIs == [storedMagnet])
        #expect(try await health.active().filter { $0.code == "diskSpaceLow" }.isEmpty)
        await manager.stop()
    }

    @Test func insufficientSpaceDoesNotMutateErroredTorrentBeforeRetry() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let health = GRDBHealthIssueRepository(database)
        let hash = String(repeating: "8", count: 40)
        let request = makeDownloadRequest(hash: hash, title: "Retry with too little space", size: 20)
        try await addTitle(for: request, to: database)
        let actualSavePath = FileManager.default.temporaryDirectory.appending(path: "existing-download-location")
        let storedMagnet = "magnet:?xt=urn:btih:\(hash)&tr=https%3A%2F%2Ftracker.example%2Fannounce"
        try await repository.upsert(Torrent(
            infoHash: hash, name: request.release.title, state: .error, savePath: actualSavePath.path,
            size: request.release.size, titleId: request.titleId, lastError: "previous failure"))
        try await repository.savePayload(infoHash: hash, .magnet(storedMagnet))

        let checkedPaths = Mutex<[String]>([])
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: health,
            configuration: .init(reservedFreeSpaceBytes: 100),
            freeSpace: { url in
                checkedPaths.withLock { $0.append(url.path) }
                return 110
            })

        do {
            _ = try await manager.add(request)
            Issue.record("Expected insufficient space to refuse the retry")
        } catch let error as DownloadManagerError {
            #expect(error == .insufficientSpace(required: 120, available: 110))
        }

        let unchanged = try #require(await repository.torrent(infoHash: hash))
        #expect(unchanged.state == .error)
        #expect(unchanged.lastError == "previous failure")
        #expect(try await repository.payload(infoHash: hash) == .magnet(storedMagnet))
        #expect(checkedPaths.withLock { $0 } == [actualSavePath.path])
        #expect(engine.addedHashes.isEmpty)
        #expect(try await health.active().contains { $0.code == "diskSpaceLow" && $0.entityId == request.titleId.uuidString })
    }

    @Test func appliesUploadLimitWhenQueuedCompletedTorrentStartsSeeding() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let hash = String(repeating: "7", count: 40)
        try await repository.upsert(Torrent(
            infoHash: hash, name: "Completed", state: .queued,
            savePath: FileManager.default.temporaryDirectory.path, size: 100, progress: 1,
            uploadLimit: 512))
        try await repository.savePayload(infoHash: hash, TorrentPayload(kind: .resume, data: Data(hash.utf8)))

        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: GRDBHealthIssueRepository(database),
            configuration: .init(maximumActiveSeeds: 1), freeSpace: { _ in Int64.max })
        try await manager.start()
        #expect(try await repository.torrent(infoHash: hash)?.state == .seeding)
        #expect(engine.uploadLimits[hash] == 512)
        await manager.stop()
    }

    @Test func configureStartsQueuedDownloadsWhenAnActiveSlotOpens() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: GRDBHealthIssueRepository(database),
            configuration: .init(maximumActiveDownloads: 1, reservedFreeSpaceBytes: 0),
            freeSpace: { _ in Int64.max })
        try await manager.start()
        let first = makeDownloadRequest(hash: String(repeating: "c", count: 40), title: "Slot one")
        let second = makeDownloadRequest(hash: String(repeating: "d", count: 40), title: "Slot two")
        try await addTitle(for: first, to: database)
        try await addTitle(for: second, to: database)
        _ = try await manager.add(first)
        _ = try await manager.add(second)
        #expect(try await repository.torrent(infoHash: second.release.infoHash!)?.state == .queued)

        try await manager.configure(.init(maximumActiveDownloads: 2, reservedFreeSpaceBytes: 0))
        #expect(try await repository.torrent(infoHash: second.release.infoHash!)?.state == .downloading)
        #expect(engine.addedHashes == [first.release.infoHash!, second.release.infoHash!])
        await manager.stop()
    }

    @Test func configureUpdatesGlobalAndActivePerTorrentLimits() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTorrentRepository(database)
        let engine = FakeManagedTorrentEngine()
        let manager = DownloadManager(
            engine: engine, torrents: repository, health: GRDBHealthIssueRepository(database),
            configuration: .init(reservedFreeSpaceBytes: 0), freeSpace: { _ in Int64.max })
        try await manager.start()
        var request = makeDownloadRequest(hash: String(repeating: "e", count: 40), title: "Rate limits")
        request.downloadLimit = 100
        request.uploadLimit = 200
        try await addTitle(for: request, to: database)
        _ = try await manager.add(request)

        var torrent = try #require(await repository.torrent(infoHash: request.release.infoHash!))
        torrent.downloadLimit = 300
        torrent.uploadLimit = 400
        try await repository.update(torrent)
        try await manager.configure(.init(
            globalDownloadLimit: 900, globalUploadLimit: 600, reservedFreeSpaceBytes: 0))

        #expect(engine.globalDownloadLimit == 900)
        #expect(engine.globalUploadLimit == 600)
        #expect(engine.downloadLimits[request.release.infoHash!] == 300)
        #expect(engine.uploadLimits[request.release.infoHash!] == 400)
        await manager.stop()
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

private actor FakePowerSourceMonitor: PowerSourceMonitoring {
    private var onBattery: Bool
    private var handler: Handler?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(initialOnBattery: Bool) { onBattery = initialOnBattery }

    func start(onChange: @escaping Handler) async throws -> Bool {
        startCount += 1
        handler = onChange
        return onBattery
    }

    func stop() async {
        stopCount += 1
        handler = nil
    }

    func emit(_ value: Bool) async {
        onBattery = value
        if let handler { await handler(value) }
    }
}

private final class FakeManagedTorrentEngine: ManagedTorrentEngine, @unchecked Sendable {
    private struct State {
        var addedHashes: [String] = []
        var magnetURIs: [String] = []
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
    var magnetURIs: [String] { state.withLock { $0.magnetURIs } }
    var uploadLimits: [String: Int] { state.withLock { $0.uploadLimits } }
    var downloadLimits: [String: Int] { state.withLock { $0.downloadLimits } }
    var globalDownloadLimit: Int? { state.withLock { $0.globalDownloadLimit } }
    var globalUploadLimit: Int? { state.withLock { $0.globalUploadLimit } }
    var resumeAdds: [String] { state.withLock { $0.resumeAdds } }
    func events() -> AsyncStream<TorrentEvent> { stream }

    func addMagnet(_ uri: String, savePath: String, paused: Bool) async throws -> TorrentID {
        guard let components = URLComponents(string: uri),
            let hash = components.queryItems?.first(where: { $0.name == "xt" })?.value?.split(separator: ":").last.map(String.init)
        else { throw TorrentError.invalidArgument }
        let id = TorrentID(hex: hash.lowercased())
        state.withLock { s in
            s.addedHashes.append(id.hex)
            s.magnetURIs.append(uri)
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
