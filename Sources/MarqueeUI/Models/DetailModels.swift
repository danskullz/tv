import Foundation

public struct EpisodeModel: Identifiable, Hashable, Sendable {
    public typealias ID = String

    public var id: ID
    public var season: Int
    public var number: Int
    public var title: String
    public var overview: String
    public var runtimeMinutes: Int
    public var airDate: Date?
    public var still: Artwork
    public var watch: WatchState
    public var availability: Availability
    public var downloadFraction: Double?
    public var quality: Quality?

    public init(
        id: ID, season: Int, number: Int, title: String, overview: String = "",
        runtimeMinutes: Int, airDate: Date? = nil, still: Artwork,
        watch: WatchState = .unwatched, availability: Availability = .local,
        downloadFraction: Double? = nil, quality: Quality? = nil
    ) {
        self.id = id
        self.season = season
        self.number = number
        self.title = title
        self.overview = overview
        self.runtimeMinutes = runtimeMinutes
        self.airDate = airDate
        self.still = still
        self.watch = watch
        self.availability = availability
        self.downloadFraction = downloadFraction
        self.quality = quality
    }
}

public struct SeasonModel: Identifiable, Hashable, Sendable {
    public var number: Int
    public var episodes: [EpisodeModel]
    public var id: Int { number }

    public init(number: Int, episodes: [EpisodeModel]) {
        self.number = number
        self.episodes = episodes
    }

    public var title: String {
        number == 0 ? String(localized: "Specials") : String(localized: "Season \(number)")
    }

    public var watchedCount: Int { episodes.filter { $0.watch == .watched }.count }
    public var firstUnwatched: EpisodeModel? { episodes.first { $0.watch != .watched && $0.availability != .unaired } }
}

/// "Resume S2 · E4" information for the primary button.
public struct ResumePoint: Hashable, Sendable {
    public var label: String
    public var fraction: Double
    public var remainingMinutes: Int

    public init(label: String, fraction: Double, remainingMinutes: Int) {
        self.label = label
        self.fraction = fraction
        self.remainingMinutes = remainingMinutes
    }
}

/// Everything the title detail page needs.
public struct TitleDetail: Identifiable, Hashable, Sendable {
    public var item: PosterItem
    public var tagline: String?
    public var overview: String
    public var certification: String
    public var score: Double?
    public var runtimeMinutes: Int?
    public var cast: [String]
    public var seasons: [SeasonModel]
    public var resume: ResumePoint?
    /// "2160p HDR · HEVC · Atmos · 14.2 GB" style lines for movies already on disk.
    public var fileInfo: [String]
    public var id: PosterItem.ID { item.id }

    public init(
        item: PosterItem, tagline: String? = nil, overview: String, certification: String,
        score: Double? = nil, runtimeMinutes: Int? = nil, cast: [String] = [],
        seasons: [SeasonModel] = [], resume: ResumePoint? = nil, fileInfo: [String] = []
    ) {
        self.item = item
        self.tagline = tagline
        self.overview = overview
        self.certification = certification
        self.score = score
        self.runtimeMinutes = runtimeMinutes
        self.cast = cast
        self.seasons = seasons
        self.resume = resume
        self.fileInfo = fileInfo
    }
}

/// Pipeline stage of an Activity entry.
public enum ActivityPhase: String, Hashable, Sendable, CaseIterable {
    case searching, downloading, importing, subtitles, ready, failed
}

public struct ActivityItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var titleID: PosterItem.ID
    public var title: String
    public var detail: String
    public var poster: Artwork
    public var phase: ActivityPhase
    public var fraction: Double
    public var totalSeconds: TimeInterval?
    public var bytesPerSecond: Double?
    public var peers: Int?
    public var quality: Quality?
    public var date: Date
    public var failureMessage: String?

    public init(
        id: String, titleID: PosterItem.ID, title: String, detail: String, poster: Artwork,
        phase: ActivityPhase, fraction: Double = 0, totalSeconds: TimeInterval? = nil,
        bytesPerSecond: Double? = nil, peers: Int? = nil, quality: Quality? = nil,
        date: Date, failureMessage: String? = nil
    ) {
        self.id = id
        self.titleID = titleID
        self.title = title
        self.detail = detail
        self.poster = poster
        self.phase = phase
        self.fraction = fraction
        self.totalSeconds = totalSeconds
        self.bytesPerSecond = bytesPerSecond
        self.peers = peers
        self.quality = quality
        self.date = date
        self.failureMessage = failureMessage
    }

    public var isActive: Bool { phase == .searching || phase == .downloading || phase == .importing || phase == .subtitles }
}

/// One tick of live download state for an id (title, episode or activity entry).
public struct ProgressUpdate: Hashable, Sendable {
    public var id: String
    public var fraction: Double
    /// Estimated seconds until the download completes.
    public var etaSeconds: TimeInterval?
    public var bytesPerSecond: Double?

    public init(id: String, fraction: Double, etaSeconds: TimeInterval? = nil, bytesPerSecond: Double? = nil) {
        self.id = id
        self.fraction = fraction
        self.etaSeconds = etaSeconds
        self.bytesPerSecond = bytesPerSecond
    }
}
