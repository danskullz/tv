import Foundation

public struct WantedTarget: Sendable, Hashable {
    public enum Reason: Sendable, Hashable { case missing, cutoffUnmet }
    public var title: Title
    public var episode: Episode?
    public var item: WantedItem
    public var currentFile: CurrentFile?
    public var reason: Reason

    public init(title: Title, episode: Episode?, item: WantedItem, currentFile: CurrentFile?, reason: Reason) {
        self.title = title
        self.episode = episode
        self.item = item
        self.currentFile = currentFile
        self.reason = reason
    }
}

/// Builds wanted items from persisted monitoring and file state; it does not perform database I/O.
public enum WantedQuery {
    /// Monitored content that has aired / reached its configured movie availability and has no file.
    public static func missing(
        title: Title, episodes: [Episode], fileEpisodeIDs: Set<UUID> = [], hasMovieFile: Bool = false,
        now: Date = Date()
    ) -> [WantedTarget] {
        guard title.monitored, title.deletedAt == nil else { return [] }
        if title.kind == .movie {
            guard !hasMovieFile, MonitoringRules.movieIsAvailable(title, now: now) else { return [] }
            return [WantedTarget(title: title, episode: nil, item: .movie(title.title, year: title.year, runtimeMinutes: nil), currentFile: nil, reason: .missing)]
        }
        let today = MonitoringRules.utcCalendar.startOfDay(for: now)
        return episodes.compactMap { episode in
            guard episode.monitored, episode.seasonNumber > 0,
                let airDate = episode.airDate,
                MonitoringRules.utcCalendar.startOfDay(for: airDate) <= today,
                !fileEpisodeIDs.contains(episode.id)
            else { return nil }
            return WantedTarget(
                title: title, episode: episode,
                item: .episode(
                    title.title, season: episode.seasonNumber, episodes: [episode.episodeNumber],
                    absolute: episode.absoluteNumber.map { [$0] } ?? [], airDate: nil,
                    runtimeMinutes: episode.runtime.map(Double.init), aliases: []),
                currentFile: nil, reason: .missing)
        }
    }

    /// Existing files still below the profile cutoff, including score-based cutoff upgrades.
    public static func cutoffUnmet(
        title: Title, episodes: [Episode], currentFiles: [UUID: CurrentFile],
        profile: QualityProfileConfig
    ) -> [WantedTarget] {
        guard title.monitored, title.deletedAt == nil, profile.upgradeAllowed else { return [] }
        func isBelowCutoff(_ file: CurrentFile) -> Bool {
            guard let group = profile.groupIndex(of: file.tier) else { return true }
            if group < profile.cutoffGroupIndex { return true }
            return file.formatScore < profile.upgradeUntilFormatScore
        }
        if title.kind == .movie, let file = currentFiles[title.id], isBelowCutoff(file) {
            return [WantedTarget(
                title: title, episode: nil,
                item: .movie(title.title, year: title.year, runtimeMinutes: nil), currentFile: file, reason: .cutoffUnmet)]
        }
        return episodes.compactMap { episode in
            guard episode.monitored, let file = currentFiles[episode.id], isBelowCutoff(file) else { return nil }
            return WantedTarget(
                title: title, episode: episode,
                item: .episode(
                    title.title, season: episode.seasonNumber, episodes: [episode.episodeNumber],
                    absolute: episode.absoluteNumber.map { [$0] } ?? [], airDate: nil,
                    runtimeMinutes: episode.runtime.map(Double.init)),
                currentFile: file, reason: .cutoffUnmet)
        }
    }
}
