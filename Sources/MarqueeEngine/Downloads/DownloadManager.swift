import Foundation
import CryptoKit
import MarqueeCore
import TorrentEngine

public enum DownloadSource: Sendable, Hashable {
    case magnet(String)
    case torrent(Data)
}

public struct DownloadRequest: Sendable, Hashable {
    public var source: DownloadSource
    public var release: IndexerRelease
    public var titleId: UUID
    public var episodeIds: [UUID]
    public var grabId: UUID?
    public var savePath: URL
    public var seedRatioGoal: Double?
    public var seedTimeGoalMinutes: Int?
    public var downloadLimit: Int?
    public var uploadLimit: Int?

    public init(
        source: DownloadSource, release: IndexerRelease, titleId: UUID, episodeIds: [UUID] = [], grabId: UUID? = nil,
        savePath: URL, seedRatioGoal: Double? = nil, seedTimeGoalMinutes: Int? = nil,
        downloadLimit: Int? = nil, uploadLimit: Int? = nil
    ) {
        self.source = source
        self.release = release
        self.titleId = titleId
        self.episodeIds = episodeIds
        self.grabId = grabId
        self.savePath = savePath
        self.seedRatioGoal = seedRatioGoal
        self.seedTimeGoalMinutes = seedTimeGoalMinutes
        self.downloadLimit = downloadLimit
        self.uploadLimit = uploadLimit
    }
}

public struct DownloadManagerConfiguration: Sendable, Hashable {
    public var maximumActiveDownloads: Int
    public var maximumActiveSeeds: Int
    public var globalDownloadLimit: Int?
    public var globalUploadLimit: Int?
    public var reservedFreeSpaceBytes: Int64
    public var pauseOnBattery: Bool
    public var preventSleepWhileDownloading: Bool
    public var removeAfterSeedGoal: Bool
    public var defaultSeedRatioGoal: Double?
    public var defaultSeedTimeGoalMinutes: Int?

    public init(
        maximumActiveDownloads: Int = 3, maximumActiveSeeds: Int = 5,
        globalDownloadLimit: Int? = nil, globalUploadLimit: Int? = nil,
        reservedFreeSpaceBytes: Int64 = 2 * 1_073_741_824, pauseOnBattery: Bool = false,
        preventSleepWhileDownloading: Bool = true, removeAfterSeedGoal: Bool = false,
        defaultSeedRatioGoal: Double? = 2, defaultSeedTimeGoalMinutes: Int? = nil
    ) {
        self.maximumActiveDownloads = max(1, maximumActiveDownloads)
        self.maximumActiveSeeds = max(0, maximumActiveSeeds)
        self.globalDownloadLimit = globalDownloadLimit
        self.globalUploadLimit = globalUploadLimit
        self.reservedFreeSpaceBytes = max(0, reservedFreeSpaceBytes)
        self.pauseOnBattery = pauseOnBattery
        self.preventSleepWhileDownloading = preventSleepWhileDownloading
        self.removeAfterSeedGoal = removeAfterSeedGoal
        self.defaultSeedRatioGoal = defaultSeedRatioGoal
        self.defaultSeedTimeGoalMinutes = defaultSeedTimeGoalMinutes
    }
}

/// Async seam makes queue policy deterministic in tests and keeps libtorrent out of manager policy.
public protocol ManagedTorrentEngine: Sendable {
    func events() -> AsyncStream<TorrentEvent>
    func addMagnet(_ uri: String, savePath: String, paused: Bool) async throws -> TorrentID
    func addTorrent(_ data: Data, savePath: String, paused: Bool) async throws -> TorrentID
    func addResumeData(_ data: Data, savePath: String, paused: Bool) async throws -> TorrentID
    func pause(_ id: TorrentID) async throws
    func resume(_ id: TorrentID) async throws
    func remove(_ id: TorrentID, deleteFiles: Bool) async throws
    func status(_ id: TorrentID) async throws -> TorrentStatus
    func saveResumeData(_ id: TorrentID) async throws -> Data
    func setDownloadLimit(_ id: TorrentID, bytesPerSecond: Int) async throws
    func setUploadLimit(_ id: TorrentID, bytesPerSecond: Int) async throws
    func setGlobalDownloadLimit(_ bytesPerSecond: Int?) async throws
    func setGlobalUploadLimit(_ bytesPerSecond: Int?) async throws
}

public struct SessionDownloadEngine: ManagedTorrentEngine {
    public let session: TorrentSession
    public init(_ session: TorrentSession) { self.session = session }
    public nonisolated func events() -> AsyncStream<TorrentEvent> { session.events() }
    public func addMagnet(_ uri: String, savePath: String, paused: Bool) async throws -> TorrentID { try await session.addMagnet(uri, savePath: savePath, options: paused ? .paused : []) }
    public func addTorrent(_ data: Data, savePath: String, paused: Bool) async throws -> TorrentID { try await session.addTorrent(data: data, savePath: savePath, options: paused ? .paused : []) }
    public func addResumeData(_ data: Data, savePath: String, paused: Bool) async throws -> TorrentID { try await session.addResumeData(data, savePath: savePath, options: paused ? .paused : []) }
    public func pause(_ id: TorrentID) async throws { try await session.pause(id) }
    public func resume(_ id: TorrentID) async throws { try await session.resume(id) }
    public func remove(_ id: TorrentID, deleteFiles: Bool) async throws { try await session.remove(id, deleteFiles: deleteFiles) }
    public func status(_ id: TorrentID) async throws -> TorrentStatus { try await session.status(id) }
    public func saveResumeData(_ id: TorrentID) async throws -> Data { try await session.saveResumeData(id) }
    public func setDownloadLimit(_ id: TorrentID, bytesPerSecond: Int) async throws { try await session.setDownloadLimit(id, bytesPerSecond: bytesPerSecond) }
    public func setUploadLimit(_ id: TorrentID, bytesPerSecond: Int) async throws { try await session.setUploadLimit(id, bytesPerSecond: bytesPerSecond) }
    public func setGlobalDownloadLimit(_ bytesPerSecond: Int?) async throws { try await session.setInt("download_rate_limit", bytesPerSecond ?? 0) }
    public func setGlobalUploadLimit(_ bytesPerSecond: Int?) async throws { try await session.setInt("upload_rate_limit", bytesPerSecond ?? 0) }
}

public struct DownloadCompletion: Sendable, Hashable {
    public var infoHash: String
    public var savePath: String
    public var releaseName: String
    public var titleId: UUID?
    public var episodeIds: [UUID]
    public var grabId: UUID?
    public init(torrent: Torrent) {
        infoHash = torrent.infoHash
        savePath = torrent.savePath
        releaseName = torrent.name
        titleId = torrent.titleId
        episodeIds = torrent.episodeIds
        grabId = torrent.grabId
    }
}

public protocol DownloadCompletionSink: Sendable {
    /// Returns true only after downstream import has accepted the completed payload.
    func completed(_ download: DownloadCompletion) async throws -> Bool
}

public struct NoopDownloadCompletionSink: DownloadCompletionSink {
    public init() {}
    public func completed(_ download: DownloadCompletion) async throws -> Bool { false }
}

public protocol DownloadSleepAssertion: Sendable {
    func setPreventSleep(_ prevent: Bool)
}

public protocol PowerSourceMonitoring: Sendable {
    typealias Handler = @Sendable (Bool) async -> Void
    /// Installs change notifications and returns the sampled current source state.
    func start(onChange: @escaping Handler) async throws -> Bool
    func stop() async
}

public struct NoopDownloadSleepAssertion: DownloadSleepAssertion {
    public init() {}
    public func setPreventSleep(_ prevent: Bool) {}
}

#if os(macOS)
import IOKit.pwr_mgt
import IOKit.ps

public final class IOPMSleepAssertion: DownloadSleepAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0
    public init() {}

    public func setPreventSleep(_ prevent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if prevent, assertion == 0 {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Marquee is downloading" as CFString, &assertion)
            if result != kIOReturnSuccess { assertion = 0 }
        } else if !prevent, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    deinit { setPreventSleep(false) }
}

private let iokitPowerSourceCallback: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    Unmanaged<IOKitPowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
}

/// Reports AC/battery transitions from IOKit. The main run loop owns the notification source;
/// there is no timer or periodic sampling.
public final class IOKitPowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var source: CFRunLoopSource?
    private var handler: PowerSourceMonitoring.Handler?

    public init() {}
    deinit { detach() }

    public func start(onChange: @escaping PowerSourceMonitoring.Handler) async throws -> Bool {
        try attach(onChange)
        return Self.isOnBattery()
    }

    public func stop() async { detach() }

    private func attach(_ onChange: @escaping PowerSourceMonitoring.Handler) throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else {
            handler = onChange
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(iokitPowerSourceCallback, context)?.takeRetainedValue() else {
            throw PowerSourceMonitorError.unavailable
        }
        handler = onChange
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func detach() {
        lock.lock()
        let source = self.source
        self.source = nil
        handler = nil
        lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    fileprivate func powerSourceChanged() {
        let onBattery = Self.isOnBattery()
        lock.lock()
        let handler = self.handler
        lock.unlock()
        if let handler { Task { await handler(onBattery) } }
    }

    private static func isOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return CFEqual(type, kIOPMBatteryPowerKey as CFString)
    }
}

public enum PowerSourceMonitorError: Error, Sendable {
    case unavailable
}
#endif

public enum DownloadManagerError: Error, Sendable, Equatable {
    case noDownloadLink
    case insufficientSpace(required: Int64, available: Int64)
    case alreadyManaged(String)
    case torrentStillInError(String)
    case unsupportedPayload
}

/// Owns non-streaming torrent adds, queue slots, rate/seed policies and relaunch persistence.
public actor DownloadManager {
    public typealias FreeSpace = @Sendable (URL) -> Int64?

    private let engine: any ManagedTorrentEngine
    private let torrents: any TorrentRepository
    private let health: any HealthIssueRepository
    private let blocklist: (any BlocklistRepository)?
    private let completionSink: any DownloadCompletionSink
    private let sleepAssertion: any DownloadSleepAssertion
    private let powerSource: (any PowerSourceMonitoring)?
    private let freeSpace: FreeSpace
    private var configuration: DownloadManagerConfiguration
    private var eventsTask: Task<Void, Never>?
    private var onBattery = false
    private var powerEventVersion: UInt64 = 0
    private var stopped = false
    private var loadedHashes = Set<String>()

    public init(
        engine: any ManagedTorrentEngine, torrents: any TorrentRepository, health: any HealthIssueRepository,
        blocklist: (any BlocklistRepository)? = nil,
        completionSink: any DownloadCompletionSink = NoopDownloadCompletionSink(),
        sleepAssertion: any DownloadSleepAssertion = NoopDownloadSleepAssertion(),
        powerSource: (any PowerSourceMonitoring)? = nil,
        configuration: DownloadManagerConfiguration = .init(), freeSpace: FreeSpace? = nil
    ) {
        self.engine = engine
        self.torrents = torrents
        self.health = health
        self.blocklist = blocklist
        self.completionSink = completionSink
        self.sleepAssertion = sleepAssertion
        self.powerSource = powerSource
        self.configuration = configuration
        self.freeSpace = freeSpace ?? { Self.systemFreeSpace($0) }
    }

    /// Starts event-driven supervision and restores persisted non-streaming downloads.
    public func start() async throws {
        guard eventsTask == nil else { return }
        stopped = false
        try await engine.setGlobalDownloadLimit(configuration.globalDownloadLimit)
        try await engine.setGlobalUploadLimit(configuration.globalUploadLimit)
        if let powerSource {
            let startVersion = powerEventVersion
            let initialOnBattery = try await powerSource.start { [weak self] value in
                try? await self?.setOnBattery(value)
            }
            if powerEventVersion == startVersion { onBattery = initialOnBattery }
        }
        let stream = engine.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
        do {
            try await restore()
        } catch {
            eventsTask?.cancel()
            eventsTask = nil
            await powerSource?.stop()
            throw error
        }
    }

    public func configure(_ configuration: DownloadManagerConfiguration) async throws {
        self.configuration = configuration
        try await engine.setGlobalDownloadLimit(configuration.globalDownloadLimit)
        try await engine.setGlobalUploadLimit(configuration.globalUploadLimit)
        try await applyBatteryPolicy()
        for torrent in try await torrents.managedDownloads()
            where (torrent.state == .downloading || torrent.state == .checking || torrent.state == .seeding)
                && !torrent.pausedByUser && !torrent.pausedForBattery && !torrent.pausedByQueue
        {
            try await applyLimits(to: torrent)
        }
    }

    /// Refuses insufficient-space grabs before creating a torrent or payload row.
    @discardableResult
    public func add(_ request: DownloadRequest) async throws -> Torrent {
        let payload: TorrentPayload
        let resolvedHash: String
        switch request.source {
        case .magnet(let uri):
            guard let hash = request.release.infoHash ?? Self.magnetHash(uri) else { throw DownloadManagerError.noDownloadLink }
            resolvedHash = hash.lowercased()
            payload = .magnet(uri)
        case .torrent(let bytes):
            guard let hash = request.release.infoHash ?? Self.torrentInfoHash(bytes) else { throw DownloadManagerError.noDownloadLink }
            resolvedHash = hash.lowercased()
            payload = TorrentPayload(kind: .file, data: bytes)
        }
        if let existing = try await torrents.torrent(infoHash: resolvedHash) {
            if existing.state == .error {
                try await enforceFreeSpace(
                    size: request.release.size ?? existing.size,
                    at: URL(fileURLWithPath: existing.savePath),
                    titleID: request.titleId, title: request.release.title)
                if loadedHashes.contains(existing.infoHash) {
                    try await engine.remove(TorrentID(hex: existing.infoHash), deleteFiles: false)
                    loadedHashes.remove(existing.infoHash)
                }
                var retry = existing
                retry.name = request.release.title
                retry.state = .queued
                retry.progress = 0
                retry.titleId = request.titleId
                retry.grabId = request.grabId
                retry.episodeIds = request.episodeIds
                retry.size = request.release.size ?? retry.size
                retry.lastError = nil
                retry.completedAt = nil
                retry.uploadedBytes = 0
                retry.importedAt = nil
                retry.isStreaming = false
                retry.pausedByUser = false
                retry.pausedByQueue = false
                retry.pausedForBattery = false
                retry.seedRatioGoal = request.seedRatioGoal ?? request.release.minimumRatio ?? configuration.defaultSeedRatioGoal
                retry.seedTimeGoalMinutes = request.seedTimeGoalMinutes
                    ?? request.release.minimumSeedTime.map { Int(($0 / 60).rounded(.up)) }
                    ?? configuration.defaultSeedTimeGoalMinutes
                retry.downloadLimit = request.downloadLimit
                retry.uploadLimit = request.uploadLimit
                let savedPayload = try await torrents.payload(infoHash: resolvedHash) ?? payload
                try await torrents.update(retry)
                try await torrents.savePayload(infoHash: resolvedHash, savedPayload)
                try await health.resolve(code: "diskSpaceLow", entityId: request.titleId.uuidString)
                try await health.resolve(code: "downloadFailed", entityId: resolvedHash)
                try await health.resolve(code: "downloadHashFailed", entityId: resolvedHash)
                try await reconcileQueue()
                return try await torrents.torrent(infoHash: resolvedHash) ?? retry
            }
            throw DownloadManagerError.alreadyManaged(existing.infoHash)
        }
        try FileManager.default.createDirectory(at: request.savePath, withIntermediateDirectories: true)
        try await enforceFreeSpace(
            size: request.release.size, at: request.savePath,
            titleID: request.titleId, title: request.release.title)
        let torrent = Torrent(
            infoHash: resolvedHash,
            name: request.release.title, state: .queued, savePath: request.savePath.path,
            size: request.release.size, titleId: request.titleId, isStreaming: false,
            grabId: request.grabId, episodeIds: request.episodeIds,
            seedRatioGoal: request.seedRatioGoal ?? request.release.minimumRatio ?? configuration.defaultSeedRatioGoal,
            seedTimeGoalMinutes: request.seedTimeGoalMinutes ?? request.release.minimumSeedTime.map { Int(($0 / 60).rounded(.up)) }
                ?? configuration.defaultSeedTimeGoalMinutes,
            downloadLimit: request.downloadLimit, uploadLimit: request.uploadLimit)
        try await torrents.upsert(torrent)
        try await torrents.savePayload(infoHash: torrent.infoHash, payload)
        try await health.resolve(code: "diskSpaceLow", entityId: request.titleId.uuidString)
        try await reconcileQueue()
        return try await torrents.torrent(infoHash: torrent.infoHash) ?? torrent
    }

    public func pauseByUser(infoHash: String) async throws {
        guard var torrent = try await torrents.torrent(infoHash: infoHash) else { return }
        if loadedHashes.contains(torrent.infoHash) { try await engine.pause(TorrentID(hex: torrent.infoHash)) }
        torrent.state = .paused
        torrent.pausedByUser = true
        torrent.pausedByQueue = false
        torrent.pausedForBattery = false
        try await torrents.update(torrent)
        await refreshSleepAssertion()
    }

    public func resumeByUser(infoHash: String) async throws {
        guard var torrent = try await torrents.torrent(infoHash: infoHash) else { return }
        torrent.pausedByUser = false
        torrent.state = .queued
        try await torrents.update(torrent)
        if configuration.pauseOnBattery && onBattery {
            torrent.pausedForBattery = true
            try await torrents.update(torrent)
            return
        }
        try await reconcileQueue()
    }

    /// Called by the platform's power-source notification; no polling is used.
    public func setOnBattery(_ value: Bool) async throws {
        powerEventVersion &+= 1
        onBattery = value
        guard !stopped else { return }
        try await applyBatteryPolicy()
    }

    private func applyBatteryPolicy() async throws {
        for var torrent in try await torrents.managedDownloads() where !torrent.pausedByUser {
            if configuration.pauseOnBattery && onBattery
                && (torrent.state == .queued || torrent.state == .downloading
                    || torrent.state == .seeding || torrent.state == .checking)
            {
                if loadedHashes.contains(torrent.infoHash) { try await engine.pause(TorrentID(hex: torrent.infoHash)) }
                torrent.state = .paused
                torrent.pausedForBattery = true
                try await torrents.update(torrent)
            } else if (!configuration.pauseOnBattery || !onBattery), torrent.pausedForBattery {
                torrent.pausedForBattery = false
                torrent.state = .queued
                try await torrents.update(torrent)
            }
        }
        try await reconcileQueue()
        await refreshSleepAssertion()
    }

    /// Checks ratio and elapsed seed-time goals on engine events or explicit policy refresh.
    public func refreshPolicies(now: Date = Date()) async throws {
        for var torrent in try await torrents.managedDownloads() where torrent.state == .seeding || torrent.progress >= 1 {
            guard !torrent.pausedByUser, !torrent.pausedForBattery else { continue }
            let ratioReached = torrent.seedRatioGoal.map {
                Double(max(0, torrent.uploadedBytes)) / Double(max(1, torrent.size ?? 1)) >= $0
            } ?? false
            let seedTimeReached = torrent.seedTimeGoalMinutes.map { minutes in
                guard let completed = torrent.completedAt else { return false }
                return now.timeIntervalSince(completed) >= TimeInterval(minutes * 60)
            } ?? false
            guard ratioReached || seedTimeReached else { continue }
            try await engine.pause(TorrentID(hex: torrent.infoHash))
            torrent.state = .finished
            torrent.pausedByQueue = false
            try await torrents.update(torrent)
            if configuration.removeAfterSeedGoal, torrent.importedAt != nil {
                try await engine.remove(TorrentID(hex: torrent.infoHash), deleteFiles: false)
                loadedHashes.remove(torrent.infoHash)
                try await torrents.remove(infoHash: torrent.infoHash)
            }
        }
        try await reconcileQueue()
    }

    /// Captures fast-resume state for every managed torrent before the engine is shut down.
    public func saveResumeData() async {
        guard let managed = try? await torrents.managedDownloads() else { return }
        for torrent in managed {
            guard loadedHashes.contains(torrent.infoHash) else { continue }
            do {
                let data = try await engine.saveResumeData(TorrentID(hex: torrent.infoHash))
                try await torrents.savePayload(infoHash: torrent.infoHash, TorrentPayload(kind: .resume, data: data))
            } catch {
                _ = try? await health.report(
                    code: "resumeDataFailed", severity: .warning,
                    message: "Couldn't save resume data for \(torrent.name): \(error)",
                    fixAction: nil, entityId: torrent.infoHash)
            }
        }
    }

    public func stop() async {
        stopped = true
        eventsTask?.cancel()
        eventsTask = nil
        await powerSource?.stop()
        await saveResumeData()
        sleepAssertion.setPreventSleep(false)
    }

    public func reportStalled(infoHash: String, message: String) async throws {
        _ = try await health.report(
            code: "downloadStalled", severity: .warning, message: message,
            fixAction: "retryDownload", entityId: infoHash.lowercased())
    }

    public func resolveStalled(infoHash: String) async throws {
        try await health.resolve(code: "downloadStalled", entityId: infoHash.lowercased())
    }

    public func validateRootFolder(_ url: URL, entityId: String? = nil) async throws -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if exists {
            try await health.resolve(code: "missingRootFolder", entityId: entityId)
        } else {
            _ = try await health.report(
                code: "missingRootFolder", severity: .error,
                message: "The download folder is missing: \(url.path)",
                fixAction: "chooseDownloadFolder", entityId: entityId)
        }
        return exists
    }

    // MARK: Queue and event handling

    private func restore() async throws {
        for var torrent in try await torrents.managedDownloads() {
            guard try await torrents.payload(infoHash: torrent.infoHash) != nil else { continue }
            do {
                if torrent.pausedByUser || (torrent.pausedForBattery && onBattery) {
                    try await addStoredTorrent(torrent, paused: true)
                } else {
                    torrent.state = .queued
                    torrent.pausedByQueue = false
                    torrent.pausedForBattery = false
                    try await torrents.update(torrent)
                }
            } catch {
                _ = try? await health.report(
                    code: "downloadRestoreFailed", severity: .error,
                    message: "Couldn't restore \(torrent.name): \(error)", fixAction: "retryDownload", entityId: torrent.infoHash)
            }
        }
        try await reconcileQueue()
    }

    private func reconcileQueue() async throws {
        guard !stopped else { return }
        var all = try await torrents.managedDownloads()
        let seedRows = all.filter { $0.state == .seeding && !$0.pausedByUser && !$0.pausedForBattery }
        if seedRows.count > configuration.maximumActiveSeeds {
            for var torrent in seedRows.dropFirst(configuration.maximumActiveSeeds) {
                try await engine.pause(TorrentID(hex: torrent.infoHash))
                torrent.state = .paused
                torrent.pausedByQueue = true
                try await torrents.update(torrent)
            }
            all = try await torrents.managedDownloads()
        }
        let activeDownloads = all.filter { !$0.pausedByUser && !$0.pausedForBattery && !$0.pausedByQueue && ($0.state == .downloading || $0.state == .checking) }.count
        let activeSeeds = all.filter { $0.state == .seeding && !$0.pausedByUser && !$0.pausedForBattery }.count
        var downloadsInUse = activeDownloads
        var seedsInUse = activeSeeds
        for var torrent in all {
            guard !torrent.pausedByUser, !torrent.pausedForBattery else { continue }
            if configuration.pauseOnBattery, onBattery, torrent.state == .queued {
                torrent.state = .paused
                torrent.pausedForBattery = true
                try await torrents.update(torrent)
                continue
            }
            if torrent.state == .queued {
                if torrent.progress >= 1 {
                    guard seedsInUse < configuration.maximumActiveSeeds else { continue }
                    try await addStoredTorrent(torrent)
                    try await applyLimits(to: torrent)
                    try await engine.resume(TorrentID(hex: torrent.infoHash))
                    torrent.state = .seeding
                    torrent.pausedByQueue = false
                    seedsInUse += 1
                    try await torrents.update(torrent)
                } else {
                    guard downloadsInUse < configuration.maximumActiveDownloads else { continue }
                    try await addStoredTorrent(torrent)
                    try await engine.resume(TorrentID(hex: torrent.infoHash))
                    torrent.state = .downloading
                    torrent.pausedByQueue = false
                    downloadsInUse += 1
                    try await applyLimits(to: torrent)
                    try await torrents.update(torrent)
                }
            } else if torrent.state == .paused, torrent.pausedByQueue {
                if torrent.progress >= 1, seedsInUse < configuration.maximumActiveSeeds {
                    try await applyLimits(to: torrent)
                    try await engine.resume(TorrentID(hex: torrent.infoHash))
                    torrent.state = .seeding
                    torrent.pausedByQueue = false
                    seedsInUse += 1
                    try await torrents.update(torrent)
                } else if torrent.progress < 1, downloadsInUse < configuration.maximumActiveDownloads {
                    try await engine.resume(TorrentID(hex: torrent.infoHash))
                    torrent.state = .downloading
                    torrent.pausedByQueue = false
                    downloadsInUse += 1
                    try await torrents.update(torrent)
                }
            }
        }
        await refreshSleepAssertion()
    }

    private func addStoredTorrent(_ torrent: Torrent, paused: Bool = false) async throws {
        guard !loadedHashes.contains(torrent.infoHash) else { return }
        guard let payload = try await torrents.payload(infoHash: torrent.infoHash) else {
            throw DownloadManagerError.unsupportedPayload
        }
        switch payload.kind {
        case .magnet:
            guard let uri = String(data: payload.data, encoding: .utf8) else { throw DownloadManagerError.unsupportedPayload }
            _ = try await engine.addMagnet(uri, savePath: torrent.savePath, paused: paused)
        case .file: _ = try await engine.addTorrent(payload.data, savePath: torrent.savePath, paused: paused)
        case .resume: _ = try await engine.addResumeData(payload.data, savePath: torrent.savePath, paused: paused)
        }
        loadedHashes.insert(torrent.infoHash)
    }

    private func applyLimits(to torrent: Torrent) async throws {
        try await engine.setDownloadLimit(
            TorrentID(hex: torrent.infoHash), bytesPerSecond: torrent.downloadLimit ?? 0)
        try await engine.setUploadLimit(
            TorrentID(hex: torrent.infoHash), bytesPerSecond: torrent.uploadLimit ?? 0)
    }

    private func enforceFreeSpace(size: Int64?, at path: URL, titleID: UUID, title: String) async throws {
        guard let available = freeSpace(path), let size, size >= 0 else { return }
        let (sum, overflow) = size.addingReportingOverflow(configuration.reservedFreeSpaceBytes)
        let required = overflow ? Int64.max : sum
        guard overflow || required > available else { return }
        _ = try? await health.report(
            code: "diskSpaceLow", severity: .error,
            message: "Not enough free space for \(title). Need \(required) bytes, have \(available).",
            fixAction: "chooseDownloadFolder", entityId: titleID.uuidString)
        throw DownloadManagerError.insufficientSpace(required: required, available: available)
    }

    private func handle(_ event: TorrentEvent) async {
        switch event {
        case .finished(let id): await complete(id)
        case .resumeData(let id, let data): try? await torrents.savePayload(infoHash: id.hex, TorrentPayload(kind: .resume, data: data))
        case .hashFailed(let id, _):
            _ = try? await health.report(
                code: "downloadHashFailed", severity: .error, message: "Torrent data failed its integrity check.",
                fixAction: "retryDownload", entityId: id.hex)
            await blocklistFailure(infoHash: id.hex, reason: "Torrent data failed its integrity check.")
        case .error(let id, let message):
            try? await engine.remove(id, deleteFiles: false)
            loadedHashes.remove(id.hex)
            try? await torrents.updateProgress(infoHash: id.hex, progress: 0, state: .error, lastError: message)
            _ = try? await health.report(
                code: "downloadFailed", severity: .error, message: message,
                fixAction: "retryDownload", entityId: id.hex)
            await blocklistFailure(infoHash: id.hex, reason: message)
        case .stateChanged(let id, _), .checked(let id), .resumed(let id), .paused(let id):
            await refresh(id)
        case .removed:
            break  // rare; a freed queue slot may start something waiting
        default:
            // Piece, file-progress, metadata and read events carry no queue information: the rows only
            // change on transitions (handled above) and completion. Returning here skips two database
            // round-trips per event, which at hundreds of piece events per second is the difference
            // between a quiet supervisor and a saturated core (SCOPE.md §5.6).
            return
        }
        try? await reconcileQueue()
    }

    private func refresh(_ id: TorrentID) async {
        guard var torrent = try? await torrents.torrent(infoHash: id.hex), let status = try? await engine.status(id) else { return }
        torrent.progress = status.progress
        torrent.uploadedBytes = max(torrent.uploadedBytes, status.payloadUploaded)
        torrent.state = status.isPaused ? .paused : Self.map(status.state)
        try? await torrents.update(torrent)
        if status.state == .seeding || status.state == .finished { try? await refreshPolicies() }
    }

    private func complete(_ id: TorrentID) async {
        guard var torrent = try? await torrents.torrent(infoHash: id.hex) else { return }
        torrent.progress = 1
        torrent.completedAt = torrent.completedAt ?? Date()
        torrent.state = .seeding
        try? await torrents.update(torrent)
        do {
            if try await completionSink.completed(DownloadCompletion(torrent: torrent)) {
                torrent.importedAt = Date()
                try await torrents.update(torrent)
                try await health.resolve(code: "downloadFailed", entityId: torrent.infoHash)
                try await health.resolve(code: "importFailed", entityId: torrent.infoHash)
            } else {
                _ = try? await health.report(
                    code: "importFailed", severity: .warning,
                    message: "Couldn't import the completed download \(torrent.name).",
                    fixAction: "retryImport", entityId: torrent.infoHash)
            }
        } catch {
            _ = try? await health.report(
                code: "importFailed", severity: .error, message: "Couldn't import \(torrent.name): \(error)",
                fixAction: "retryImport", entityId: torrent.infoHash)
        }
        try? await refreshPolicies()
    }

    private func blocklistFailure(infoHash: String, reason: String) async {
        guard let blocklist, let torrent = try? await torrents.torrent(infoHash: infoHash),
            let titleId = torrent.titleId
        else { return }
        let existing = (try? await blocklist.entries(titleId: titleId)) ?? []
        guard !existing.contains(where: { $0.infoHash?.lowercased() == infoHash.lowercased() }) else { return }
        try? await blocklist.add(BlocklistEntry(
            titleId: titleId, episodeId: torrent.episodeIds.first, releaseTitle: torrent.name,
            infoHash: infoHash, reason: reason))
    }

    private func refreshSleepAssertion() async {
        guard configuration.preventSleepWhileDownloading,
            let all = try? await torrents.managedDownloads()
        else { sleepAssertion.setPreventSleep(false); return }
        sleepAssertion.setPreventSleep(all.contains { $0.state == .downloading && !$0.pausedByUser && !$0.pausedForBattery })
    }

    private static func map(_ state: TorrentEngine.TorrentState) -> MarqueeCore.TorrentState {
        switch state {
        case .checkingFiles, .checkingResumeData: .checking
        case .downloadingMetadata, .downloading: .downloading
        case .finished: .finished
        case .seeding: .seeding
        }
    }

    private static func systemFreeSpace(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func magnetHash(_ magnet: String) -> String? {
        guard let components = URLComponents(string: magnet), components.scheme == "magnet",
            let encoded = components.queryItems?.first(where: { $0.name == "xt" })?.value,
            encoded.lowercased().hasPrefix("urn:btih:")
        else { return nil }
        let value = String(encoded.dropFirst("urn:btih:".count))
        if value.count == 40, value.allSatisfy(\.isHexDigit) { return value.lowercased() }
        return base32Hex(value)
    }

    private static func base32Hex(_ input: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        for character in input.uppercased() {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((buffer >> bitCount) & 0xff))
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes the exact bencoded `info` dictionary from a v1 torrent metainfo file.
    private static func torrentInfoHash(_ data: Data) -> String? {
        let bytes = Array(data)
        func stringEnd(at start: Int) -> (value: String, end: Int)? {
            guard start < bytes.count, bytes[start] >= 48, bytes[start] <= 57 else { return nil }
            var colon = start
            while colon < bytes.count, bytes[colon] != 58 { colon += 1 }
            guard colon < bytes.count, let length = Int(String(decoding: bytes[start..<colon], as: UTF8.self)) else { return nil }
            let end = colon + 1 + length
            guard end <= bytes.count else { return nil }
            return (String(decoding: bytes[(colon + 1)..<end], as: UTF8.self), end)
        }
        func valueEnd(at start: Int) -> Int? {
            guard start < bytes.count else { return nil }
            switch bytes[start] {
            case 48...57: return stringEnd(at: start)?.end
            case 105:
                guard let end = bytes[(start + 1)...].firstIndex(of: 101) else { return nil }
                return end + 1
            case 108, 100:
                var index = start + 1
                while index < bytes.count, bytes[index] != 101 {
                    if bytes[start] == 100 {
                        guard let key = stringEnd(at: index) else { return nil }
                        index = key.end
                    }
                    guard let end = valueEnd(at: index), end > index else { return nil }
                    index = end
                }
                return index < bytes.count ? index + 1 : nil
            default: return nil
            }
        }
        guard bytes.first == 100 else { return nil }
        var index = 1
        while index < bytes.count, bytes[index] != 101 {
            guard let key = stringEnd(at: index) else { return nil }
            let start = key.end
            guard let end = valueEnd(at: start) else { return nil }
            if key.value == "info" {
                return Insecure.SHA1.hash(data: Data(bytes[start..<end])).map { String(format: "%02x", $0) }.joined()
            }
            index = end
        }
        return nil
    }
}
