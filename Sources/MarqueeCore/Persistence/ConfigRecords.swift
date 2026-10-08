import Foundation
import GRDB

public struct RootFolder: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    /// `nil` accepts any kind.
    public var mediaKind: TitleKind?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), path: String, mediaKind: TitleKind? = nil, createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.mediaKind = mediaKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One ordered quality tier of a profile.
public struct QualityItem: Codable, Hashable, Sendable {
    public var quality: String
    public var allowed: Bool
    public init(quality: String, allowed: Bool = true) {
        self.quality = quality
        self.allowed = allowed
    }
}

public struct QualityProfile: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Tiers, lowest to highest preference.
    public var items: [QualityItem]
    public var cutoff: String?
    public var upgradeAllowed: Bool
    public var minFormatScore: Int
    public var cutoffFormatScore: Int
    /// Custom format id (UUID string) -> score.
    public var formatScores: [String: Int]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, items: [QualityItem] = [], cutoff: String? = nil,
        upgradeAllowed: Bool = true, minFormatScore: Int = 0, cutoffFormatScore: Int = 0,
        formatScores: [String: Int] = [:], createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.cutoff = cutoff
        self.upgradeAllowed = upgradeAllowed
        self.minFormatScore = minFormatScore
        self.cutoffFormatScore = cutoffFormatScore
        self.formatScores = formatScores
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One rule of a custom format (codec, source, group, language, HDR, regex, ...).
public struct CustomFormatSpec: Codable, Hashable, Sendable {
    public var type: String
    public var value: String
    public var negate: Bool
    public var required: Bool
    public init(type: String, value: String, negate: Bool = false, required: Bool = false) {
        self.type = type
        self.value = value
        self.negate = negate
        self.required = required
    }
}

public struct CustomFormat: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var specs: [CustomFormatSpec]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, specs: [CustomFormatSpec] = [], createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.specs = specs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DelayProfile: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var delayMinutes: Int
    public var bypassIfHighestQuality: Bool
    public var bypassIfScoreAtLeast: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, sortOrder: Int = 0, delayMinutes: Int = 0,
        bypassIfHighestQuality: Bool = true, bypassIfScoreAtLeast: Int? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.delayMinutes = delayMinutes
        self.bypassIfHighestQuality = bypassIfHighestQuality
        self.bypassIfScoreAtLeast = bypassIfScoreAtLeast
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Event types are open-ended strings so new ones never need a migration or break decoding.
public struct HistoryEventType: RawRepresentable, Hashable, Codable, Sendable, DatabaseValueConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let titleAdded: Self = "titleAdded"
    public static let titleDeleted: Self = "titleDeleted"
    public static let titleRestored: Self = "titleRestored"
    public static let grabbed: Self = "grabbed"
    public static let grabRejected: Self = "grabRejected"
    public static let torrentAdded: Self = "torrentAdded"
    public static let torrentCompleted: Self = "torrentCompleted"
    public static let torrentFailed: Self = "torrentFailed"
    public static let imported: Self = "imported"
    public static let upgraded: Self = "upgraded"
    public static let renamed: Self = "renamed"
    public static let subtitleDownloaded: Self = "subtitleDownloaded"
    public static let blocklisted: Self = "blocklisted"
    public static let streamStarted: Self = "streamStarted"
    public static let watched: Self = "watched"
}

public enum HistoryEntityType: String, Codable, DatabaseValueConvertible, Sendable {
    case title, season, episode, mediaFile, release, grab, torrent, streamSession, indexer
}

/// Append-only event-log entry; the basis for "why" explanations and undo.
public struct HistoryEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var type: HistoryEventType
    public var entityType: HistoryEntityType
    /// UUID string, or the infoHash for torrents.
    public var entityId: String?
    /// Denormalized owning title for per-title feeds.
    public var titleId: UUID?
    public var payload: JSONValue
    public var occurredAt: Date

    public init(
        id: UUID = UUID(), type: HistoryEventType, entityType: HistoryEntityType,
        entityId: String? = nil, titleId: UUID? = nil, payload: JSONValue = [:],
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.entityType = entityType
        self.entityId = entityId
        self.titleId = titleId
        self.payload = payload
        self.occurredAt = occurredAt
    }

    public init(
        type: HistoryEventType, entityType: HistoryEntityType, entityUUID: UUID,
        titleId: UUID? = nil, payload: JSONValue = [:], occurredAt: Date = Date()
    ) {
        self.init(
            type: type, entityType: entityType, entityId: entityUUID.uuidString,
            titleId: titleId, payload: payload, occurredAt: occurredAt)
    }
}

public struct HealthIssue: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public enum Severity: String, Codable, DatabaseValueConvertible, Sendable {
        case info, warning, error
    }

    public var id: UUID
    public var code: String
    public var severity: Severity
    public var message: String
    /// Identifier of the one-click fix, if any.
    public var fixAction: String?
    public var entityId: String?
    public var resolvedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), code: String, severity: Severity, message: String,
        fixAction: String? = nil, entityId: String? = nil, resolvedAt: Date? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.code = code
        self.severity = severity
        self.message = message
        self.fixAction = fixAction
        self.entityId = entityId
        self.resolvedAt = resolvedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
