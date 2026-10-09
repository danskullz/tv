import Foundation
import GRDB

public enum TitleKind: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case movie, series
}

public enum SeriesType: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case standard, daily, anime
}

public enum MonitorMode: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case all, future, firstSeason, latestSeason, pilot, specific, none
    /// Movies: monitor the single item.
    case movieOnly
}

/// When a monitored movie becomes eligible for search.
public enum MinimumAvailability: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case announced, inCinemas, released, digital
}

/// A movie or a series.
public struct Title: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: TitleKind
    public var tmdbId: Int?
    public var tvdbId: Int?
    public var imdbId: String?
    public var title: String
    public var sortTitle: String
    public var year: Int?
    public var overview: String?
    /// Free-form metadata status ("continuing", "ended", "released", ...).
    public var status: String?
    public var monitored: Bool
    public var monitorMode: MonitorMode
    public var minimumAvailability: MinimumAvailability?
    public var qualityProfileId: UUID?
    public var rootFolderId: UUID?
    public var path: String?
    public var seriesType: SeriesType?
    public var addedAt: Date
    public var posterPath: String?
    public var backdropPath: String?
    /// Non-nil while the title is in the "recently deleted" (undo) state.
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Movie release dates (TMDB), which decide when a monitored movie becomes eligible for search.
    public var releaseDate: Date?
    public var inCinemasDate: Date?
    public var digitalReleaseDate: Date?
    public var physicalReleaseDate: Date?

    public init(
        id: UUID = UUID(), kind: TitleKind, tmdbId: Int? = nil, tvdbId: Int? = nil,
        imdbId: String? = nil, title: String, sortTitle: String? = nil, year: Int? = nil,
        overview: String? = nil, status: String? = nil, monitored: Bool = true,
        monitorMode: MonitorMode? = nil, minimumAvailability: MinimumAvailability? = nil,
        qualityProfileId: UUID? = nil, rootFolderId: UUID? = nil, path: String? = nil,
        seriesType: SeriesType? = nil, addedAt: Date = Date(), posterPath: String? = nil,
        backdropPath: String? = nil, deletedAt: Date? = nil, createdAt: Date = Date(),
        updatedAt: Date = Date(), releaseDate: Date? = nil, inCinemasDate: Date? = nil, digitalReleaseDate: Date? = nil,
        physicalReleaseDate: Date? = nil
    ) {
        self.releaseDate = releaseDate
        self.inCinemasDate = inCinemasDate
        self.digitalReleaseDate = digitalReleaseDate
        self.physicalReleaseDate = physicalReleaseDate
        self.id = id
        self.kind = kind
        self.tmdbId = tmdbId
        self.tvdbId = tvdbId
        self.imdbId = imdbId
        self.title = title
        self.sortTitle = sortTitle ?? Title.defaultSortTitle(title)
        self.year = year
        self.overview = overview
        self.status = status
        self.monitored = monitored
        self.monitorMode = monitorMode ?? (kind == .movie ? .movieOnly : .all)
        self.minimumAvailability = minimumAvailability
        self.qualityProfileId = qualityProfileId
        self.rootFolderId = rootFolderId
        self.path = path
        self.seriesType = seriesType ?? (kind == .series ? .standard : nil)
        self.addedAt = addedAt
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Lowercased, with a leading article dropped ("The Office" -> "office").
    public static func defaultSortTitle(_ title: String) -> String {
        let lower = title.lowercased()
        for article in ["the ", "an ", "a "] where lower.hasPrefix(article) {
            return String(lower.dropFirst(article.count))
        }
        return lower
    }
}

public struct Season: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var titleId: UUID
    public var seasonNumber: Int
    public var monitored: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), titleId: UUID, seasonNumber: Int, monitored: Bool = true,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.seasonNumber = seasonNumber
        self.monitored = monitored
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Episode: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var titleId: UUID
    public var seasonId: UUID
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var absoluteNumber: Int?
    public var airDate: Date?
    public var monitored: Bool
    public var title: String?
    /// Minutes.
    public var runtime: Int?
    public var tvdbId: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), titleId: UUID, seasonId: UUID, seasonNumber: Int, episodeNumber: Int,
        absoluteNumber: Int? = nil, airDate: Date? = nil, monitored: Bool = true,
        title: String? = nil, runtime: Int? = nil, tvdbId: Int? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.seasonId = seasonId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.absoluteNumber = absoluteNumber
        self.airDate = airDate
        self.monitored = monitored
        self.title = title
        self.runtime = runtime
        self.tvdbId = tvdbId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Probe results stored as JSON on a `MediaFile`; add optional fields freely (no migration needed).
public struct MediaInfo: Codable, Hashable, Sendable {
    public var durationSeconds: Double?
    public var container: String?
    public var videoCodec: String?
    public var width: Int?
    public var height: Int?
    public var hdr: String?
    public var audioTracks: [AudioTrack]
    public var subtitleLanguages: [String]

    public struct AudioTrack: Codable, Hashable, Sendable {
        public var codec: String
        public var channels: Int?
        public var language: String?
        public init(codec: String, channels: Int? = nil, language: String? = nil) {
            self.codec = codec
            self.channels = channels
            self.language = language
        }
    }

    public init(
        durationSeconds: Double? = nil, container: String? = nil, videoCodec: String? = nil,
        width: Int? = nil, height: Int? = nil, hdr: String? = nil,
        audioTracks: [AudioTrack] = [], subtitleLanguages: [String] = []
    ) {
        self.durationSeconds = durationSeconds
        self.container = container
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.hdr = hdr
        self.audioTracks = audioTracks
        self.subtitleLanguages = subtitleLanguages
    }
}

/// An imported file. Episode links live in `MediaFileEpisode` (a file can cover several episodes).
public struct MediaFile: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var titleId: UUID
    public var path: String
    public var size: Int64
    public var qualityName: String?
    public var resolution: Int?
    public var source: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var releaseGroup: String?
    public var customFormatScore: Int?
    public var mediaInfo: MediaInfo?
    public var importedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), titleId: UUID, path: String, size: Int64 = 0,
        qualityName: String? = nil, resolution: Int? = nil, source: String? = nil,
        videoCodec: String? = nil, audioCodec: String? = nil, releaseGroup: String? = nil,
        customFormatScore: Int? = nil, mediaInfo: MediaInfo? = nil, importedAt: Date = Date(),
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.path = path
        self.size = size
        self.qualityName = qualityName
        self.resolution = resolution
        self.source = source
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.releaseGroup = releaseGroup
        self.customFormatScore = customFormatScore
        self.mediaInfo = mediaInfo
        self.importedAt = importedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MediaFileEpisode: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public var mediaFileId: UUID
    public var episodeId: UUID
    public init(mediaFileId: UUID, episodeId: UUID) {
        self.mediaFileId = mediaFileId
        self.episodeId = episodeId
    }
}

public struct Tag: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), label: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TitleTag: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public var titleId: UUID
    public var tagId: UUID
    public init(titleId: UUID, tagId: UUID) {
        self.titleId = titleId
        self.tagId = tagId
    }
}

public struct SubtitleTrack: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, DatabaseValueConvertible, Sendable {
        case embedded, external, downloaded
    }

    public var id: UUID
    public var titleId: UUID
    public var episodeId: UUID?
    public var mediaFileId: UUID?
    /// BCP 47 / ISO 639 code.
    public var language: String
    /// "srt", "ass", "pgs", ...
    public var format: String
    public var origin: Origin
    public var provider: String?
    public var path: String?
    public var embeddedIndex: Int?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var score: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), titleId: UUID, episodeId: UUID? = nil, mediaFileId: UUID? = nil,
        language: String, format: String, origin: Origin, provider: String? = nil,
        path: String? = nil, embeddedIndex: Int? = nil, isForced: Bool = false,
        isHearingImpaired: Bool = false, score: Int? = nil, createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.episodeId = episodeId
        self.mediaFileId = mediaFileId
        self.language = language
        self.format = format
        self.origin = origin
        self.provider = provider
        self.path = path
        self.embeddedIndex = embeddedIndex
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.score = score
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Resume position and watched flag. `id` is the playable entity: the movie's title id or an episode id.
public struct WatchState: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var titleId: UUID
    public var positionSeconds: Double
    public var durationSeconds: Double?
    public var watched: Bool
    public var updatedAt: Date

    public init(
        id: UUID, titleId: UUID, positionSeconds: Double = 0, durationSeconds: Double? = nil,
        watched: Bool = false, updatedAt: Date = Date()
    ) {
        self.id = id
        self.titleId = titleId
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.watched = watched
        self.updatedAt = updatedAt
    }
}
