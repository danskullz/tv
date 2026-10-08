import Foundation

// View-facing models. These are what MarqueeUI views display; they are deliberately independent of
// MarqueeCore's database types so data sources can be swapped (mock, GRDB, Connect mode, previews).

/// Movie or series.
public enum MediaKind: String, Hashable, Sendable, CaseIterable {
    case movie
    case series
}

/// Resolution and flags of a file or release, shown as a `QualityBadge`.
public struct Quality: Hashable, Sendable {
    public enum Resolution: Int, Hashable, Sendable, Comparable {
        case sd = 480, hd720 = 720, hd1080 = 1080, uhd = 2160
        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }

    public var resolution: Resolution
    public var hdr: Bool
    public var remux: Bool

    public init(_ resolution: Resolution, hdr: Bool = false, remux: Bool = false) {
        self.resolution = resolution
        self.hdr = hdr
        self.remux = remux
    }

    public static let p720 = Quality(.hd720)
    public static let p1080 = Quality(.hd1080)
    public static let uhd = Quality(.uhd)
    public static let uhdHDR = Quality(.uhd, hdr: true)
}

/// Where the media is in the acquire pipeline.
public enum Availability: Hashable, Sendable {
    /// File is on disk and ready to play.
    case local
    /// Search done, waiting for a download slot.
    case queued
    /// Downloading (progress comes from `DownloadTracker`); streamable once buffered.
    case downloading
    /// Download finished, being verified / renamed / imported.
    case importing
    /// Monitored but nothing downloaded; pressing Play will find and stream a release.
    case missing
    /// Not released yet.
    case unaired

    public var isActive: Bool { self == .downloading || self == .queued || self == .importing }
}

public enum WatchState: Hashable, Sendable {
    case unwatched
    /// Fraction watched, 0...1.
    case inProgress(Double)
    case watched

    public var fraction: Double? {
        if case .inProgress(let f) = self { return f }
        return nil
    }
}

/// Procedurally generated stand-in artwork: a hue-driven gradient with an SF Symbol. No images, no network.
public struct PlaceholderArt: Hashable, Sendable {
    /// 0...1 hue of the primary gradient stop.
    public var hue: Double
    public var symbol: String
    /// Shifts the gradient angle / secondary hue so neighbouring posters don't look cloned.
    public var variant: Int

    public init(hue: Double, symbol: String, variant: Int = 0) {
        self.hue = hue
        self.symbol = symbol
        self.variant = variant
    }
}

/// Artwork reference. `.remote` shows its placeholder while the (downsampled, cached) image loads.
public enum Artwork: Hashable, Sendable {
    case generated(PlaceholderArt)
    case remote(URL, placeholder: PlaceholderArt)

    public var placeholder: PlaceholderArt {
        switch self {
        case .generated(let art), .remote(_, let art): art
        }
    }

    public var url: URL? {
        if case .remote(let url, _) = self { return url }
        return nil
    }
}

/// One title (movie or series) as shown on a card.
public struct PosterItem: Identifiable, Hashable, Sendable {
    public typealias ID = String

    public var id: ID
    public var kind: MediaKind
    public var title: String
    /// Secondary line, e.g. "2024 · 3 Seasons" or "S2 · E4 · 31 min left".
    public var subtitle: String
    public var year: Int
    public var addedAt: Date
    public var poster: Artwork
    public var backdrop: Artwork
    public var watch: WatchState
    public var availability: Availability
    /// Last known download fraction; live values come from `DownloadTracker`.
    public var downloadFraction: Double?
    public var quality: Quality?
    public var genres: [String]

    public init(
        id: ID, kind: MediaKind, title: String, subtitle: String = "", year: Int = 0,
        addedAt: Date = .distantPast, poster: Artwork, backdrop: Artwork? = nil,
        watch: WatchState = .unwatched, availability: Availability = .local,
        downloadFraction: Double? = nil, quality: Quality? = nil, genres: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.addedAt = addedAt
        self.poster = poster
        self.backdrop = backdrop ?? poster
        self.watch = watch
        self.availability = availability
        self.downloadFraction = downloadFraction
        self.quality = quality
        self.genres = genres
    }
}

public enum ShelfStyle: Hashable, Sendable {
    /// 2:3 posters.
    case poster
    /// 16:9 cards (Continue watching).
    case wide
}

/// A titled horizontal row on Home.
public struct ShelfModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var style: ShelfStyle
    public var items: [PosterItem]
    public var showsSeeAll: Bool

    public init(
        id: String, title: String, subtitle: String? = nil, style: ShelfStyle = .poster,
        items: [PosterItem], showsSeeAll: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.items = items
        self.showsSeeAll = showsSeeAll
    }
}

/// A context-menu / VoiceOver custom action attached to a card.
public struct PosterAction: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var isDestructive: Bool
    public var handler: @MainActor @Sendable () -> Void

    public init(
        id: String, title: String, systemImage: String, isDestructive: Bool = false,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.handler = handler
    }
}
