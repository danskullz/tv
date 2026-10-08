import Foundation

/// One file of a torrent as the engine reports it: position in the torrent's file list, path
/// relative to the torrent root, size, and byte offset inside the concatenated payload.
public struct PackFile: Sendable, Hashable, Codable {
    public var index: Int
    public var path: String
    public var size: Int64
    public var offset: Int64

    public init(index: Int, path: String, size: Int64, offset: Int64) {
        self.index = index
        self.path = path
        self.size = size
        self.offset = offset
    }

    /// Builds a file list in torrent order, assigning consecutive indexes and offsets.
    public static func layout(_ entries: [(path: String, size: Int64)]) -> [PackFile] {
        var offset: Int64 = 0
        return entries.enumerated().map { i, e in
            defer { offset += e.size }
            return PackFile(index: i, path: e.path, size: e.size, offset: offset)
        }
    }
}

/// A (season, episode) pair in the series' own numbering. Season 0 is specials.
public struct EpisodeRef: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var season: Int
    public var episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }

    /// Parses `S01E02` (case-insensitive).
    public init?(_ string: String) {
        let s = string.uppercased()
        guard s.hasPrefix("S"), let e = s.firstIndex(of: "E"),
              let season = Int(s[s.index(after: s.startIndex)..<e]),
              let episode = Int(s[s.index(after: e)...])
        else { return nil }
        self.init(season: season, episode: episode)
    }

    public static func < (l: EpisodeRef, r: EpisodeRef) -> Bool {
        (l.season, l.episode) < (r.season, r.episode)
    }

    public var description: String {
        func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "S\(pad(season))E\(pad(episode))"
    }
}

/// An episode the series is expected to have, with the extra numbering schemes needed to match files.
public struct PackEpisode: Sendable, Hashable {
    public var ref: EpisodeRef
    /// Absolute number (anime), counted across seasons excluding specials.
    public var absolute: Int?
    public var airDate: AirDate?
    public var title: String?
    /// Unaired episodes are never reported as gaps.
    public var isAired: Bool

    public init(ref: EpisodeRef, absolute: Int? = nil, airDate: AirDate? = nil, title: String? = nil, isAired: Bool = true) {
        self.ref = ref
        self.absolute = absolute
        self.airDate = airDate
        self.title = title
        self.isAired = isAired
    }
}

/// What the mapper knows about the series the torrent is supposed to contain.
public struct PackSeriesContext: Sendable {
    public var title: String
    public var aliases: [String]
    public var episodes: [PackEpisode]
    /// Seasons the caller asked for (used for bare "Episode 03" files and gap scoping).
    public var targetSeasons: Set<Int>

    let byRef: [EpisodeRef: PackEpisode]
    let byAbsolute: [Int: EpisodeRef]
    let byDate: [AirDate: EpisodeRef]
    let byTitle: [String: EpisodeRef]
    let regularSeasons: Set<Int>

    public init(title: String, aliases: [String] = [], episodes: [PackEpisode] = [], targetSeasons: Set<Int> = []) {
        self.title = title
        self.aliases = aliases
        self.episodes = episodes
        self.targetSeasons = targetSeasons
        var byRef: [EpisodeRef: PackEpisode] = [:]
        var byAbsolute: [Int: EpisodeRef] = [:]
        var byDate: [AirDate: EpisodeRef] = [:]
        var byTitle: [String: EpisodeRef] = [:]
        var dupTitles: Set<String> = []
        for e in episodes {
            byRef[e.ref] = e
            if let a = e.absolute, e.ref.season != 0 { byAbsolute[a] = e.ref }
            if let d = e.airDate { byDate[d] = e.ref }
            if let t = e.title {
                let n = ReleaseParser.normalizeTitle(t)
                if n.count >= 4 {
                    if byTitle[n] != nil { dupTitles.insert(n) } else { byTitle[n] = e.ref }
                }
            }
        }
        for t in dupTitles { byTitle[t] = nil }
        self.byRef = byRef
        self.byAbsolute = byAbsolute
        self.byDate = byDate
        self.byTitle = byTitle
        self.regularSeasons = Set(episodes.map(\.ref.season).filter { $0 != 0 })
    }

    public func contains(_ ref: EpisodeRef) -> Bool { byRef[ref] != nil }
}

/// What a torrent file is, as far as playback and import are concerned.
public enum PackRole: String, Sendable, Hashable, Codable, CaseIterable {
    case episode, multiEpisode, special, extra, sample, subtitle, archiveVolume, nonMedia
}

/// The mapper's verdict on one torrent file (distinct from the persisted `PackFileMapping` record).
public struct PackFileAssignment: Sendable, Hashable {
    public var fileIndex: Int
    public var path: String
    public var size: Int64
    public var offset: Int64
    public var role: PackRole
    /// Episodes the file contains (several for multi-episode files); for subtitles and archive
    /// volumes, the episodes of the video they belong to.
    public var episodes: [EpisodeRef]
    /// 0...1.
    public var confidence: Double
    /// Plain-language explanation for the review table.
    public var reason: String
    /// False when the file lost a conflict (duplicate episode in another quality, etc.).
    public var isPreferred: Bool
    public var userCorrected: Bool
    /// Subtitle sidecars: index of the video file they belong to.
    public var attachedTo: Int?
    /// Archive volumes: ``ArchiveSet/id`` and the volume's position in the set.
    public var archiveSetID: String?
    public var archiveVolume: Int?
    /// Executables and other files that should never be touched.
    public var isSuspicious: Bool

    public init(
        fileIndex: Int, path: String, size: Int64, offset: Int64, role: PackRole, episodes: [EpisodeRef] = [],
        confidence: Double, reason: String, isPreferred: Bool = true, userCorrected: Bool = false,
        attachedTo: Int? = nil, archiveSetID: String? = nil, archiveVolume: Int? = nil, isSuspicious: Bool = false
    ) {
        self.fileIndex = fileIndex
        self.path = path
        self.size = size
        self.offset = offset
        self.role = role
        self.episodes = episodes
        self.confidence = confidence
        self.reason = reason
        self.isPreferred = isPreferred
        self.userCorrected = userCorrected
        self.attachedTo = attachedTo
        self.archiveSetID = archiveSetID
        self.archiveVolume = archiveVolume
        self.isSuspicious = isSuspicious
    }

    /// An episode-bearing file for which no episode could be determined.
    public var isUnmatched: Bool { carriesEpisodes && episodes.isEmpty }

    /// True for files that carry playable episode content (loose video or archive volumes).
    public var carriesEpisodes: Bool {
        switch role {
        case .episode, .multiEpisode, .special, .archiveVolume: true
        default: false
        }
    }

    /// Converts to the persisted record. `episodeID` resolves a reference to the library episode id.
    public func record(infoHash: String, episodeID: (EpisodeRef) -> UUID?) -> PackFileMapping {
        let persisted: PackFileRole
        switch role {
        case .episode, .multiEpisode, .special, .archiveVolume: persisted = isPreferred ? .episode : .ignored
        case .extra: persisted = .extra
        case .sample: persisted = .sample
        case .subtitle, .nonMedia: persisted = .ignored
        }
        return PackFileMapping(
            infoHash: infoHash, fileIndex: fileIndex, path: path, size: size, role: persisted,
            episodeIds: episodes.compactMap(episodeID), userCorrected: userCorrected, confidence: confidence)
    }
}

/// Two or more files that claim the same episode.
public struct PackConflict: Sendable, Hashable {
    public var episode: EpisodeRef
    public var winner: Int
    public var losers: [Int]
    public var reason: String
}

public enum PackWarning: Sendable, Hashable {
    case suspiciousExecutable(fileIndex: Int)
    case titleMismatch(fileIndex: Int)
    case unmatchedFile(fileIndex: Int)
    case incompleteArchive(setID: String, missingVolumes: [Int])
}

/// Everything the mapper learned about a torrent.
public struct PackMappingResult: Sendable {
    /// One entry per input file, ordered by file index.
    public var assignments: [PackFileAssignment]
    public var conflicts: [PackConflict]
    /// Expected, aired episodes in the pack's seasons that no preferred file covers. Callers trigger
    /// the single-episode fallback for these.
    public var gaps: [EpisodeRef]
    public var archiveSets: [ArchiveSet]
    public var warnings: [PackWarning]
    /// True when some archive set could not be tied to episodes, so `gaps` cannot be trusted.
    public var hasOpaqueArchives: Bool

    public var needsFallback: Bool { !gaps.isEmpty }
    public var suspiciousFiles: [Int] { assignments.filter(\.isSuspicious).map(\.fileIndex) }

    /// Preferred episode-bearing files covering `ref`.
    public func files(for ref: EpisodeRef) -> [PackFileAssignment] {
        assignments.filter { $0.isPreferred && $0.carriesEpisodes && $0.episodes.contains(ref) }
    }

    /// Every episode covered by a preferred file or archive set, in order.
    public var coveredEpisodes: [EpisodeRef] {
        var s = Set<EpisodeRef>()
        for a in assignments where a.isPreferred && a.carriesEpisodes { s.formUnion(a.episodes) }
        return s.sorted()
    }
}
