import Foundation

/// How several episodes in one file are written where the template has `{episode:00}`
/// (`S01E01` + `E02` + `E03` shown for each style).
public enum MultiEpisodeStyle: String, Codable, Sendable, CaseIterable, Hashable {
    /// `S01E01-E03` (first and last, each prefixed). Read by Plex, Jellyfin and Emby. Default.
    case prefixedRange
    /// `S01E01-03`
    case range
    /// `S01E01E02E03`
    case repeated
    /// `S01E01-02-03`
    case extend
    /// `S01E01.S01E02.S01E03`
    case duplicate

    public var example: String {
        switch self {
        case .prefixedRange: "S01E01-E03"
        case .range: "S01E01-03"
        case .repeated: "S01E01E02E03"
        case .extend: "S01E01-02-03"
        case .duplicate: "S01E01.S01E02.S01E03"
        }
    }
}

/// What a colon in a title becomes. macOS shows `:` as `/` in Finder and SMB/exFAT forbid it outright.
public enum ColonReplacement: String, Codable, Sendable, CaseIterable, Hashable {
    /// `Star Trek: Discovery` -> `Star Trek - Discovery`, `Re:Zero` -> `Re-Zero`.
    case smart
    /// Always spaced: `Star Trek: Discovery` -> `Star Trek - Discovery`, `Re:Zero` -> `Re - Zero`.
    case dash
    /// `Star Trek Discovery`
    case delete
    /// `Star Trek ꞉ Discovery` (U+A789 modifier letter colon, looks like a colon, legal everywhere).
    case lookalike
}

/// Which characters are refused in file and folder names.
public enum CharacterPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    /// Only what macOS cannot store: `/`, NUL and control characters, plus the colon (see ``ColonReplacement``).
    case macOS
    /// Safe on SMB shares, exFAT, FAT and NTFS as well: also `\ * ? " < > |`, trailing dots and spaces,
    /// and Windows' reserved device names (`CON`, `NUL`, `COM1`...).
    case portable
}

/// What spaces become in rendered names (`nil` keeps them).
public enum SpaceReplacement: String, Codable, Sendable, CaseIterable, Hashable {
    case dot = "."
    case underscore = "_"
    case dash = "-"
}

/// The user's naming settings: one template per kind of media plus character handling. Templates are
/// paths: `/` separates folders from the file name, `{Token}` inserts a value, `[...]`/`(...)` groups
/// whose tokens are all empty disappear (so `({Year})` costs nothing when the year is unknown).
public struct NamingConfig: Codable, Sendable, Hashable {
    public var movieTemplate: String
    public var episodeTemplate: String
    public var dailyTemplate: String
    public var animeTemplate: String
    public var multiEpisodeStyle: MultiEpisodeStyle
    public var colon: ColonReplacement
    public var characters: CharacterPolicy
    public var spaces: SpaceReplacement?
    /// Longest file or folder name in UTF-8 bytes (APFS allows 255).
    public var maxComponentBytes: Int

    public init(
        movieTemplate: String = NamingConfig.defaultMovieTemplate,
        episodeTemplate: String = NamingConfig.defaultEpisodeTemplate,
        dailyTemplate: String = NamingConfig.defaultDailyTemplate,
        animeTemplate: String = NamingConfig.defaultAnimeTemplate,
        multiEpisodeStyle: MultiEpisodeStyle = .prefixedRange,
        colon: ColonReplacement = .smart,
        characters: CharacterPolicy = .macOS,
        spaces: SpaceReplacement? = nil,
        maxComponentBytes: Int = 255
    ) {
        self.movieTemplate = movieTemplate
        self.episodeTemplate = episodeTemplate
        self.dailyTemplate = dailyTemplate
        self.animeTemplate = animeTemplate
        self.multiEpisodeStyle = multiEpisodeStyle
        self.colon = colon
        self.characters = characters
        self.spaces = spaces
        self.maxComponentBytes = maxComponentBytes
    }

    /// Plex, Jellyfin and Emby all read these without configuration.
    public static let defaultMovieTemplate = "{Movie Title} ({Year})/{Movie Title} ({Year}) [{Quality Full}].{ext}"
    public static let defaultEpisodeTemplate =
        "{Series Title} ({Year})/Season {season:00}/{Series Title} - S{season:00}E{episode:00} - {Episode Title} [{Quality Full}].{ext}"
    public static let defaultDailyTemplate =
        "{Series Title} ({Year})/Season {season:00}/{Series Title} - {Air-Date} - {Episode Title} [{Quality Full}].{ext}"
    public static let defaultAnimeTemplate =
        "{Series Title} ({Year})/Season {season:00}/{Series Title} - S{season:00}E{episode:00} - {absolute:000} - {Episode Title} [{Quality Full}].{ext}"

    public static let `default` = NamingConfig()

    /// The template that applies to `context`: daily shows need an air date, anime shows an absolute number.
    public func template(for context: NamingContext) -> String {
        switch context.kind {
        case .movie: return movieTemplate
        case .episode:
            switch context.seriesType {
            case .daily where context.airDate != nil: return dailyTemplate
            case .anime where !context.absoluteEpisodes.isEmpty: return animeTemplate
            default: return episodeTemplate
            }
        }
    }
}
