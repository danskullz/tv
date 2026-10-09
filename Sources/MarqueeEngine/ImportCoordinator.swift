import Foundation
import GRDB
import MarqueeCore

public struct ImportCoordinatorConfiguration: Sendable {
    public var naming: NamingConfig
    public var transferStrategy: FileTransferStrategy
    public var keepSeeding: Bool
    public var probeTimeout: Duration
    public var minimumDurationSeconds: Double

    public init(
        naming: NamingConfig = .default, transferStrategy: FileTransferStrategy = .automatic,
        keepSeeding: Bool = true, probeTimeout: Duration = .seconds(30), minimumDurationSeconds: Double = 30
    ) {
        self.naming = naming
        self.transferStrategy = transferStrategy
        self.keepSeeding = keepSeeding
        self.probeTimeout = probeTimeout
        self.minimumDurationSeconds = minimumDurationSeconds
    }
}

public enum ImportCoordinatorEvent: Sendable, Hashable {
    case imported(path: URL, mediaFileID: UUID, method: FileTransferMethod, replaced: [UUID])
    case skipped(path: String, reason: String)
    case failed(path: String, reason: String)
}

public enum ImportCoordinatorError: Error, Sendable, Equatable {
    case invalidSource
    case unsafePath
    case unknownTitle(UUID)
    case unmappedEpisode(EpisodeRef)
    case inconsistentEpisodeTargets
    case notAnUpgrade
    case occupiedDestination
    case missingUndoReceipt
    case invalidUndoReceipt
}

/// Imports completed torrent files one at a time, so packs needn't wait for the last episode.
public actor ImportCoordinator: DownloadImporting {
    private struct Target {
        var title: Title
        var episodes: [Episode]
        var episodeIDs: [UUID] { episodes.map(\.id) }
    }

    private struct PreviousState: Codable {
        struct File: Codable {
            var record: MediaFile
            var episodeIDs: [UUID]
        }
        var files: [File]
        var trashed: [TrashedFile]
    }

    private let database: AppDatabase
    private let probe: any MediaProbing
    private let rootDirectory: @Sendable () -> URL
    private let configuration: @Sendable () -> ImportCoordinatorConfiguration
    private let transfer = FileTransfer()
    private let eventHub = Broadcaster<ImportCoordinatorEvent>(replayLatest: false, policy: .unbounded)
    private var pending: [CompletedDownload] = []
    private var draining = false
    private var inFlight = Set<String>()

    public init(
        database: AppDatabase, probe: any MediaProbing = AVFoundationMediaProbe(),
        rootDirectory: @escaping @Sendable () -> URL,
        configuration: @escaping @Sendable () -> ImportCoordinatorConfiguration = { ImportCoordinatorConfiguration() }
    ) {
        self.database = database
        self.probe = probe
        self.rootDirectory = rootDirectory
        self.configuration = configuration
    }

    public nonisolated func events() -> AsyncStream<ImportCoordinatorEvent> { eventHub.subscribe() }

    /// Producers may call this synchronously; accepted downloads are processed serially in arrival order.
    public nonisolated func handle(_ event: CompletedDownload) {
        Task { await self.enqueue(event) }
    }

    /// Processes one event synchronously for callers that need a result (and for deterministic tests).
    @discardableResult
    public func process(_ event: CompletedDownload) async throws -> [ImportCoordinatorEvent] {
        var results: [ImportCoordinatorEvent] = []
        for file in event.files {
            let result: ImportCoordinatorEvent
            do {
                result = try await importFile(file, from: event)
            } catch {
                result = .failed(path: file.path, reason: Self.userMessage(for: error))
            }
            results.append(result)
            eventHub.send(result)
        }
        return results
    }

    /// Reverses the import recorded by `historyEventID`, restoring previous files from Trash where applicable.
    public func revertImport(historyEventID: UUID) async throws {
        let receipt = try await database.writer.read { db -> (String, UUID, String?)? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT sourceKey, mediaFileId, previousState FROM importReceipt WHERE historyEventId = ?",
                arguments: [historyEventID])
            else { return nil }
            let key: String = row["sourceKey"]
            let mediaID: UUID = row["mediaFileId"]
            let previous: String? = row["previousState"]
            return (key, mediaID, previous)
        }
        guard let (sourceKey, mediaFileID, previousJSON) = receipt else {
            throw ImportCoordinatorError.missingUndoReceipt
        }
        let savedState: PreviousState?
        if let previousJSON {
            guard let decoded = try? JSONDecoder().decode(PreviousState.self, from: Data(previousJSON.utf8)) else {
                throw ImportCoordinatorError.invalidUndoReceipt
            }
            savedState = decoded
        } else {
            savedState = nil
        }

        let current = try await database.writer.read { try MediaFile.fetchOne($0, key: mediaFileID) }
        var newFileTrash: TrashedFile?
        if let current, FileManager.default.fileExists(atPath: current.path) {
            newFileTrash = try transfer.trash(URL(fileURLWithPath: current.path))
        }
        var restored: [TrashedFile] = []
        do {
            for trashed in savedState?.trashed ?? [] {
                try transfer.restore(trashed)
                restored.append(trashed)
            }
            try await database.writer.write { db in
                try MediaFile.deleteOne(db, key: mediaFileID)
                for item in savedState?.files ?? [] {
                    try item.record.insert(db)
                    for episodeID in item.episodeIDs {
                        try MediaFileEpisode(mediaFileId: item.record.id, episodeId: episodeID).insert(db)
                    }
                }
                try db.execute(sql: "DELETE FROM importReceipt WHERE sourceKey = ?", arguments: [sourceKey])
                try HistoryEvent(
                    type: HistoryEventType(rawValue: "importReverted"), entityType: .mediaFile,
                    entityUUID: mediaFileID, titleId: current?.titleId,
                    payload: ["reverts": .string(historyEventID.uuidString)]).insert(db)
            }
        } catch {
            for trashed in restored.reversed() { _ = try? transfer.trash(trashed.originalURL) }
            if let newFileTrash { try? transfer.restore(newFileTrash) }
            throw error
        }
    }

    private func enqueue(_ event: CompletedDownload) async {
        pending.append(event)
        guard !draining else { return }
        draining = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            _ = try? await process(next)
        }
        draining = false
    }

    private func importFile(_ file: CompletedFile, from download: CompletedDownload) async throws -> ImportCoordinatorEvent {
        let source = try sourceURL(file.path, savePath: download.savePath)
        let key = download.infoHash.lowercased() + ":" + source.path
        guard !inFlight.contains(key) else { return .skipped(path: file.path, reason: "This file is already being imported.") }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        if try await hasReceipt(sourceKey: key) {
            return .skipped(path: file.path, reason: "This completed file was already imported.")
        }

        switch FileSafety.inspect(source) {
        case .media: break
        case .suspicious(let reason):
            try await recordHealthIssue(reason, entityID: key)
            return .skipped(path: file.path, reason: "This file was refused as unsafe.")
        case .subtitle: return .skipped(path: file.path, reason: "Subtitle sidecars stay with the download for now.")
        case .archive: return .skipped(path: file.path, reason: "Archive extraction isn't enabled for this import yet.")
        case .ignored: return .skipped(path: file.path, reason: "This isn't a video file.")
        }
        let fileNameInfo = ReleaseParser.parseFileName(source.lastPathComponent)
        if fileNameInfo.flags.contains(.sample) || fileNameInfo.flags.contains(.extra) {
            return .skipped(path: file.path, reason: "This video is marked as a sample or extra.")
        }
        if let expectedSize = file.size, expectedSize != (try fileSize(source)) {
            throw FileTransferError.sizeMismatch
        }
        let target = try await resolve(file.target)
        guard let target else { return .skipped(path: file.path, reason: "This file isn't mapped to a library title or episode.") }

        let probeInfo = try await probe.probe(source, timeout: configuration().probeTimeout)
        let release = Self.parsedRelease(releaseName: download.releaseName, fileName: source.lastPathComponent)
        try MediaProbeValidation.validateCodecClaim(release.videoCodec, against: probeInfo.videoCodec)
        let runtimeMinutes = target.episodes.compactMap(\.runtime).reduce(0, +)
        let expectedRuntime = runtimeMinutes == 0 ? nil : Double(runtimeMinutes * 60)
        try MediaProbeValidation.validate(
            probeInfo, expectedRuntimeSeconds: expectedRuntime,
            minimumDurationSeconds: configuration().minimumDurationSeconds)

        let context = Self.namingContext(target: target, parsed: release, media: probeInfo, file: source)
        let rendered = configuration().naming.render(context)
        let root = try await root(for: target.title)
        let destination = root.appendingPathComponent(rendered.relativePath)
        let oldFiles = try await overlappingFiles(for: target)
        let replaceable = try await replacementCandidates(oldFiles, target: target, incoming: context.tier)
        if !oldFiles.isEmpty, replaceable.count != oldFiles.count {
            throw ImportCoordinatorError.notAnUpgrade
        }

        let stage = try transfer.stage(
            from: source, to: destination, strategy: configuration().transferStrategy,
            seeding: configuration().keepSeeding)
        var trashed: [TrashedFile] = []
        do {
            let stagedInfo = try await probe.probe(stage.stagedURL, timeout: configuration().probeTimeout)
            try MediaProbeValidation.validate(
                stagedInfo, expectedRuntimeSeconds: expectedRuntime,
                minimumDurationSeconds: configuration().minimumDurationSeconds)
            transfer.clearQuarantine(stage.stagedURL)
            let replaceIDs = Set(replaceable.map { $0.record.id })
            let oldByPath = Dictionary(uniqueKeysWithValues: oldFiles.map { ($0.record.path, $0.record.id) })
            if FileManager.default.fileExists(atPath: destination.path) {
                guard let existingID = oldByPath[destination.path], replaceIDs.contains(existingID) else {
                    throw ImportCoordinatorError.occupiedDestination
                }
            }
            for old in replaceable where FileManager.default.fileExists(atPath: old.record.path) {
                trashed.append(try transfer.trash(URL(fileURLWithPath: old.record.path)))
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard trashed.contains(where: { $0.originalURL == destination }) else {
                    throw ImportCoordinatorError.occupiedDestination
                }
            }
            try transfer.commit(stage)

            let newFile = Self.mediaFile(
                title: target.title, path: destination, size: stage.size, context: context, media: stagedInfo)
            let oldState = PreviousState(files: replaceable, trashed: trashed)
            let previousJSON = replaceable.isEmpty ? nil : try Self.encode(oldState)
            let trashedJSON = try Self.encode(trashed)
            let eventID = UUID()
            let history = HistoryEvent(
                id: eventID, type: replaceable.isEmpty ? .imported : .upgraded, entityType: .mediaFile,
                entityId: newFile.id.uuidString, titleId: target.title.id,
                payload: [
                    "sourceKey": .string(key), "path": .string(destination.path),
                    "infoHash": .string(download.infoHash.lowercased()),
                    "release": .string(download.releaseName), "grab": .string(download.grabID?.uuidString ?? ""),
                    "replaced": .array(replaceable.map { .string($0.record.id.uuidString) }),
                ])
            do {
                try await database.writer.write { db in
                    for old in replaceable { try MediaFile.deleteOne(db, key: old.record.id) }
                    try newFile.insert(db)
                    for episodeID in target.episodeIDs {
                        try MediaFileEpisode(mediaFileId: newFile.id, episodeId: episodeID).insert(db)
                    }
                    try history.insert(db)
                    try db.execute(
                        sql: "INSERT INTO importReceipt (sourceKey, historyEventId, mediaFileId, previousState, trashedPaths, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                        arguments: [key, eventID, newFile.id, previousJSON, trashedJSON, Date()])
                }
            } catch {
                let importedTrash = try? transfer.trash(destination)
                for old in trashed.reversed() { try? transfer.restore(old) }
                if let importedTrash { try? transfer.restore(importedTrash) }
                throw error
            }
            return .imported(path: destination, mediaFileID: newFile.id, method: stage.method, replaced: Array(replaceIDs))
        } catch {
            if FileManager.default.fileExists(atPath: stage.stagedURL.path) { try? transfer.discard(stage) }
            for old in trashed.reversed() { try? transfer.restore(old) }
            throw error
        }
    }

    private func resolve(_ target: ImportTarget) async throws -> Target? {
        switch target {
        case .unmapped: return nil
        case .movie(let id):
            guard let title = try await database.writer.read({ try Title.fetchOne($0, key: id) }) else {
                throw ImportCoordinatorError.unknownTitle(id)
            }
            return Target(title: title, episodes: [])
        case .episodes(let titleID, let refs):
            guard let title = try await database.writer.read({ try Title.fetchOne($0, key: titleID) }) else {
                throw ImportCoordinatorError.unknownTitle(titleID)
            }
            let episodes = try await database.writer.read { db in
                try Episode.filter(Column("titleId") == titleID).fetchAll(db)
            }
            let mapped = refs.compactMap { ref in episodes.first { $0.seasonNumber == ref.season && $0.episodeNumber == ref.episode } }
            guard mapped.count == refs.count, !mapped.isEmpty else {
                throw ImportCoordinatorError.unmappedEpisode(refs.first ?? EpisodeRef(season: 0, episode: 0))
            }
            return Target(title: title, episodes: mapped)
        case .episodeIDs(let ids):
            guard !ids.isEmpty else { return nil }
            let episodes = try await database.writer.read { db in
                try Episode.filter(ids.contains(Column("id"))).fetchAll(db)
            }
            guard episodes.count == ids.count, let titleID = episodes.first?.titleId,
                episodes.allSatisfy({ $0.titleId == titleID })
            else { throw ImportCoordinatorError.inconsistentEpisodeTargets }
            guard let title = try await database.writer.read({ try Title.fetchOne($0, key: titleID) }) else {
                throw ImportCoordinatorError.unknownTitle(titleID)
            }
            return Target(title: title, episodes: episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) })
        }
    }

    private func root(for title: Title) async throws -> URL {
        if let rootID = title.rootFolderId,
            let folder = try await database.writer.read({ try RootFolder.fetchOne($0, key: rootID) })
        {
            return URL(fileURLWithPath: folder.path, isDirectory: true)
        }
        return rootDirectory()
    }

    private func overlappingFiles(for target: Target) async throws -> [PreviousState.File] {
        try await database.writer.read { db in
            let files = try MediaFile.filter(Column("titleId") == target.title.id).fetchAll(db)
            var overlaps: [PreviousState.File] = []
            for file in files {
                let linked = try MediaFileEpisode.filter(Column("mediaFileId") == file.id).fetchAll(db).map(\.episodeId)
                if target.title.kind == .movie || !Set(linked).isDisjoint(with: target.episodeIDs) {
                    overlaps.append(PreviousState.File(record: file, episodeIDs: linked))
                }
            }
            return overlaps
        }
    }

    private func replacementCandidates(
        _ oldFiles: [PreviousState.File], target: Target, incoming: QualityTier
    ) async throws -> [PreviousState.File] {
        guard !oldFiles.isEmpty else { return [] }
        var profile: QualityProfileConfig?
        if let id = target.title.qualityProfileId,
            let record = try await database.writer.read({ try QualityProfile.fetchOne($0, key: id) })
        {
            profile = QualityProfileConfig(record: record)
        }
        return oldFiles.filter { old in
            guard Set(old.episodeIDs).isSubset(of: Set(target.episodeIDs)) || target.title.kind == .movie else { return false }
            let existing = Self.qualityTier(for: old.record)
            guard let profile else { return incoming > existing }
            guard profile.upgradeAllowed else { return false }
            let newIndex = profile.groupIndex(of: incoming)
            let oldIndex = profile.groupIndex(of: existing)
            if let newIndex, let oldIndex { return newIndex > oldIndex }
            return incoming > existing
        }
    }

    private func hasReceipt(sourceKey: String) async throws -> Bool {
        try await database.writer.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM importReceipt WHERE sourceKey = ?)", arguments: [sourceKey]) ?? false
        }
    }

    private func recordHealthIssue(_ message: String, entityID: String) async throws {
        let now = Date()
        try await database.writer.write { db in
            try HealthIssue(
                code: "suspiciousImport", severity: .error, message: message,
                fixAction: nil, entityId: entityID, createdAt: now, updatedAt: now).insert(db)
        }
    }

    private func sourceURL(_ path: String, savePath: String) throws -> URL {
        let base = URL(fileURLWithPath: savePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: savePath, isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(rootPath), candidate.path != base.path else { throw ImportCoordinatorError.unsafePath }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), !directory.boolValue else {
            throw ImportCoordinatorError.invalidSource
        }
        return candidate
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func namingContext(target: Target, parsed: ParsedRelease, media: MediaInfo, file: URL) -> NamingContext {
        let episodes = target.episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
        let first = episodes.first
        var airDate: AirDate?
        if let date = first?.airDate {
            let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
            if let year = parts.year, let month = parts.month, let day = parts.day { airDate = AirDate(year: year, month: month, day: day) }
        }
        let context = NamingContext(
            kind: target.title.kind == .movie ? .movie : .episode,
            title: target.title.title, year: target.title.year, seriesType: target.title.seriesType ?? .standard,
            season: first?.seasonNumber, episodes: episodes.map(\.episodeNumber),
            absoluteEpisodes: episodes.compactMap(\.absoluteNumber), airDate: airDate,
            episodeTitles: episodes.compactMap(\.title), parsed: parsed, media: media,
            originalFilename: file.lastPathComponent, ext: file.pathExtension)
        return context
    }

    private static func parsedRelease(releaseName: String, fileName: String) -> ParsedRelease {
        var parsed = ReleaseParser.parse(releaseName)
        let fromFile = ReleaseParser.parseFileName(fileName)
        if parsed.resolution == nil { parsed.resolution = fromFile.resolution }
        if parsed.source == nil { parsed.source = fromFile.source }
        if parsed.videoCodec == nil { parsed.videoCodec = fromFile.videoCodec }
        if parsed.hdr.isEmpty { parsed.hdr = fromFile.hdr }
        if parsed.audioCodecs.isEmpty { parsed.audioCodecs = fromFile.audioCodecs }
        if parsed.audioChannels == nil { parsed.audioChannels = fromFile.audioChannels }
        if parsed.releaseGroup == nil { parsed.releaseGroup = fromFile.releaseGroup }
        if parsed.editions.isEmpty { parsed.editions = fromFile.editions }
        if parsed.streamingService == nil { parsed.streamingService = fromFile.streamingService }
        if parsed.languages.isEmpty { parsed.languages = fromFile.languages }
        if parsed.version == 1 { parsed.version = fromFile.version }
        if parsed.flags.isEmpty { parsed.flags = fromFile.flags }
        return parsed
    }

    private static func qualityTier(for file: MediaFile) -> QualityTier {
        let parsed = ReleaseParser.parse(file.qualityName ?? "")
        var info = parsed
        if let resolution = file.resolution, let parsedResolution = Resolution(rawValue: resolution) { info.resolution = parsedResolution }
        if let source = file.source, let parsedSource = Source(rawValue: source) { info.source = parsedSource }
        if let codec = file.videoCodec, let parsedCodec = VideoCodec(rawValue: codec) { info.videoCodec = parsedCodec }
        return QualityTier.derive(from: info)
    }

    private static func mediaFile(title: Title, path: URL, size: Int64, context: NamingContext, media: MediaInfo) -> MediaFile {
        let parsed = context.effectiveParsed
        let tier = context.tier
        let resolution = parsed.resolution?.rawValue ?? tier.resolution
        return MediaFile(
            titleId: title.id, path: path.path, size: size, qualityName: tier.displayName,
            resolution: resolution == 0 ? nil : resolution, source: parsed.source?.rawValue,
            videoCodec: parsed.videoCodec?.rawValue ?? media.videoCodec,
            audioCodec: parsed.audioCodecs.first?.rawValue ?? media.audioTracks.first?.codec,
            releaseGroup: parsed.releaseGroup, mediaInfo: media)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func userMessage(for error: Error) -> String {
        switch error {
        case ImportCoordinatorError.notAnUpgrade: "A local file is already at least as good as this release."
        case ImportCoordinatorError.occupiedDestination: "A different file already uses the destination name. Nothing was replaced."
        case MediaProbeError.missingVideo: "This file has no video stream."
        case MediaProbeError.tooShort: "This file is much shorter than the expected runtime and may be a sample."
        case MediaProbeError.missingDuration: "Marquee couldn't verify the video's duration."
        case MediaProbeError.timedOut: "Marquee couldn't inspect this file in time."
        case MediaProbeError.codecMismatch: "The video's codec doesn't match what the release name claims."
        case FileTransferError.notEnoughSpace: "There isn't enough free space to copy this file."
        case FileTransferError.destinationExists: "A file already uses the destination name. Nothing was replaced."
        default: "Marquee couldn't safely import this file: \(error.localizedDescription)"
        }
    }
}
