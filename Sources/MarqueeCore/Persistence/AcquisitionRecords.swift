import Foundation
import GRDB

/// A search result from an indexer, cached with its parsed fields.
public struct Release: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var indexerId: UUID?
    public var titleId: UUID?
    public var guid: String
    /// The raw release name.
    public var title: String
    public var infoHash: String?
    public var downloadURL: String?
    public var size: Int64
    public var seeders: Int?
    public var leechers: Int?
    public var publishedAt: Date?
    // Key columns duplicated from `parsed` for filtering and sorting.
    public var resolution: Int?
    public var source: String?
    public var releaseGroup: String?
    public var seasonNumber: Int?
    public var isSeasonPack: Bool
    public var score: Int?
    /// Full parser output.
    public var parsed: JSONValue
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), indexerId: UUID? = nil, titleId: UUID? = nil, guid: String,
        title: String, infoHash: String? = nil, downloadURL: String? = nil, size: Int64 = 0,
        seeders: Int? = nil, leechers: Int? = nil, publishedAt: Date? = nil,
        resolution: Int? = nil, source: String? = nil, releaseGroup: String? = nil,
        seasonNumber: Int? = nil, isSeasonPack: Bool = false, score: Int? = nil,
        parsed: JSONValue = [:], createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.indexerId = indexerId
        self.titleId = titleId
        self.guid = guid
        self.title = title
        self.infoHash = infoHash
        self.downloadURL = downloadURL
        self.size = size
        self.seeders = seeders
        self.leechers = leechers
        self.publishedAt = publishedAt
        self.resolution = resolution
        self.source = source
        self.releaseGroup = releaseGroup
        self.seasonNumber = seasonNumber
        self.isSeasonPack = isSeasonPack
        self.score = score
        self.parsed = parsed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One release-selection decision with its explanation ("Why this release?").
public struct Grab: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, DatabaseValueConvertible, Sendable {
        case interactive, rss, search, stream, upgrade
    }
    public enum Outcome: String, Codable, DatabaseValueConvertible, Sendable {
        case grabbed, rejected, failed
    }

    public var id: UUID
    public var titleId: UUID
    public var episodeId: UUID?
    public var releaseId: UUID?
    /// Snapshot, since the cached `Release` row can be purged.
    public var releaseTitle: String
    public var infoHash: String?
    public var origin: Origin
    public var outcome: Outcome
    public var score: Int?
    /// Scoring breakdown and rejection reasons.
    public var reason: JSONValue
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), titleId: UUID, episodeId: UUID? = nil, releaseId: UUID? = nil,
        releaseTitle: String, infoHash: String? = nil, origin: Origin, outcome: Outcome,
        score: Int? = nil, reason: JSONValue = [:], createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.episodeId = episodeId
        self.releaseId = releaseId
        self.releaseTitle = releaseTitle
        self.infoHash = infoHash
        self.origin = origin
        self.outcome = outcome
        self.score = score
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TorrentState: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case queued, checking, downloading, paused, seeding, finished, error
}

/// Mirror of the engine's torrent state, keyed by infoHash (v1 hex, lowercase).
public struct Torrent: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var infoHash: String
    public var name: String
    public var state: TorrentState
    public var savePath: String
    public var size: Int64?
    /// 0...1
    public var progress: Double
    public var titleId: UUID?
    public var isStreaming: Bool
    public var keepAfterStream: Bool
    public var lastError: String?
    public var addedAt: Date
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// The grab (decision-log entry) that produced this download, if any.
    public var grabId: UUID?
    /// Library episodes this download was grabbed for (empty for movies).
    public var episodeIds: [UUID]
    /// Cumulative payload uploaded across app launches.
    public var uploadedBytes: Int64
    /// The user paused it; automatic queueing and power rules never resume it.
    public var pausedByUser: Bool
    /// Paused because an active-download slot is unavailable.
    public var pausedByQueue: Bool
    /// Paused by the battery power policy, never conflated with a user pause.
    public var pausedForBattery: Bool
    /// Stop seeding at this share ratio / after this many minutes (nil = use the app's default policy).
    public var seedRatioGoal: Double?
    public var seedTimeGoalMinutes: Int?
    /// Bytes per second; nil = unlimited.
    public var downloadLimit: Int?
    public var uploadLimit: Int?
    /// When the completion sink (importer) finished with it.
    public var importedAt: Date?

    public var id: String { infoHash }

    public init(
        infoHash: String, name: String, state: TorrentState = .queued, savePath: String,
        size: Int64? = nil, progress: Double = 0, titleId: UUID? = nil, isStreaming: Bool = false,
        keepAfterStream: Bool = true, lastError: String? = nil, addedAt: Date = Date(),
        completedAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
        grabId: UUID? = nil, episodeIds: [UUID] = [], uploadedBytes: Int64 = 0, pausedByUser: Bool = false,
        pausedByQueue: Bool = false, pausedForBattery: Bool = false,
        seedRatioGoal: Double? = nil, seedTimeGoalMinutes: Int? = nil, downloadLimit: Int? = nil,
        uploadLimit: Int? = nil, importedAt: Date? = nil
    ) {
        self.grabId = grabId
        self.episodeIds = episodeIds
        self.uploadedBytes = uploadedBytes
        self.pausedByUser = pausedByUser
        self.pausedByQueue = pausedByQueue
        self.pausedForBattery = pausedForBattery
        self.seedRatioGoal = seedRatioGoal
        self.seedTimeGoalMinutes = seedTimeGoalMinutes
        self.downloadLimit = downloadLimit
        self.uploadLimit = uploadLimit
        self.importedAt = importedAt
        self.infoHash = infoHash.lowercased()
        self.name = name
        self.state = state
        self.savePath = savePath
        self.size = size
        self.progress = progress
        self.titleId = titleId
        self.isStreaming = isStreaming
        self.keepAfterStream = keepAfterStream
        self.lastError = lastError
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StreamSession: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, DatabaseValueConvertible, Sendable {
        case preparing, buffering, playing, ended, failed
    }

    public var id: UUID
    public var infoHash: String
    public var titleId: UUID
    public var episodeId: UUID?
    public var fileIndex: Int
    public var state: State
    public var startedAt: Date
    public var endedAt: Date?
    /// Press-Play to first frame (a release-gate metric).
    public var firstFrameMs: Int?
    public var stallCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), infoHash: String, titleId: UUID, episodeId: UUID? = nil,
        fileIndex: Int, state: State = .preparing, startedAt: Date = Date(), endedAt: Date? = nil,
        firstFrameMs: Int? = nil, stallCount: Int = 0, createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.infoHash = infoHash.lowercased()
        self.titleId = titleId
        self.episodeId = episodeId
        self.fileIndex = fileIndex
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.firstFrameMs = firstFrameMs
        self.stallCount = stallCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// An indexer definition. Secrets are never stored here; `credentialRef` names a Keychain item.
public struct Indexer: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var implementation: String
    public var baseURL: String
    public var enabled: Bool
    public var priority: Int
    public var minimumSeeders: Int
    public var categories: [Int]
    public var credentialRef: String?
    public var failureCount: Int
    public var disabledUntil: Date?
    public var lastSuccessAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, implementation: String = "torznab", baseURL: String,
        enabled: Bool = true, priority: Int = 25, minimumSeeders: Int = 1, categories: [Int] = [],
        credentialRef: String? = nil, failureCount: Int = 0, disabledUntil: Date? = nil,
        lastSuccessAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.implementation = implementation
        self.baseURL = baseURL
        self.enabled = enabled
        self.priority = priority
        self.minimumSeeders = minimumSeeders
        self.categories = categories
        self.credentialRef = credentialRef
        self.failureCount = failureCount
        self.disabledUntil = disabledUntil
        self.lastSuccessAt = lastSuccessAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct IndexerTag: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public var indexerId: UUID
    public var tagId: UUID
    public init(indexerId: UUID, tagId: UUID) {
        self.indexerId = indexerId
        self.tagId = tagId
    }
}

public struct BlocklistEntry: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var titleId: UUID
    public var episodeId: UUID?
    public var indexerId: UUID?
    public var releaseTitle: String
    public var infoHash: String?
    public var reason: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), titleId: UUID, episodeId: UUID? = nil, indexerId: UUID? = nil,
        releaseTitle: String, infoHash: String? = nil, reason: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.episodeId = episodeId
        self.indexerId = indexerId
        self.releaseTitle = releaseTitle
        self.infoHash = infoHash
        self.reason = reason
        self.createdAt = createdAt
    }
}

/// What a torrent file is within a season pack.
public enum PackFileRole: String, Codable, DatabaseValueConvertible, Sendable {
    case episode, extra, sample, ignored
}

/// Maps one file of a torrent to the episode(s) it contains. User corrections are sticky.
public struct PackFileMapping: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public var infoHash: String
    public var fileIndex: Int
    public var path: String
    public var size: Int64
    public var role: PackFileRole
    /// More than one entry for multi-episode files (E01-E02).
    public var episodeIds: [UUID]
    public var userCorrected: Bool
    public var confidence: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        infoHash: String, fileIndex: Int, path: String, size: Int64 = 0, role: PackFileRole = .episode,
        episodeIds: [UUID] = [], userCorrected: Bool = false, confidence: Double? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.infoHash = infoHash.lowercased()
        self.fileIndex = fileIndex
        self.path = path
        self.size = size
        self.role = role
        self.episodeIds = episodeIds
        self.userCorrected = userCorrected
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
