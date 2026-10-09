import Foundation

/// Stable episode coordinates used when preserving per-episode monitor overrides on refresh.
public struct MonitoredEpisodeKey: Sendable, Hashable {
    public var season: Int
    public var episode: Int
    public init(season: Int, episode: Int) { self.season = season; self.episode = episode }
}

public enum MonitoringRules {
    /// Expands a TV monitoring mode into per-episode flags. Existing episode values are preserved
    /// during metadata refresh; newly discovered episodes get the mode's default.
    public static func episodeFlags(
        mode: MonitorMode, titleMonitored: Bool, seasons: [SeasonDraft], now: Date = Date(),
        existing: [MonitoredEpisodeKey: Bool] = [:]
    ) -> [Int: [MonitoredEpisodeKey: Bool]] {
        let numbered = seasons.filter { $0.seasonNumber > 0 }
        let first = numbered.map(\.seasonNumber).min()
        let latest = numbered.map(\.seasonNumber).max()
        let calendar = Self.utcCalendar
        let today = calendar.startOfDay(for: now)
        var result: [Int: [MonitoredEpisodeKey: Bool]] = [:]
        for season in seasons {
            var flags: [MonitoredEpisodeKey: Bool] = [:]
            for episode in season.episodes {
                let key = MonitoredEpisodeKey(season: season.seasonNumber, episode: episode.episodeNumber)
                let selected: Bool
                if !titleMonitored || !season.monitored || mode == .none {
                    selected = false
                } else if let old = existing[key] {
                    selected = old
                } else {
                    switch mode {
                    case .all: selected = true
                    case .future: selected = episode.airDate.map { calendar.startOfDay(for: $0) >= today } ?? false
                    case .firstSeason: selected = season.seasonNumber == first
                    case .latestSeason: selected = season.seasonNumber == latest
                    case .pilot: selected = season.seasonNumber == 1 && episode.episodeNumber == 1
                    case .specific: selected = episode.monitored
                    case .none: selected = false
                    case .movieOnly: selected = false
                    }
                }
                flags[key] = selected
            }
            result[season.seasonNumber] = flags
        }
        return result
    }

    public static func movieIsAvailable(_ title: Title, now: Date = Date()) -> Bool {
        guard title.monitored else { return false }
        switch title.minimumAvailability ?? .released {
        case .announced: return true
        case .inCinemas: return title.inCinemasDate.map { $0 <= now } ?? false
        case .released: return title.releaseDate.map { $0 <= now } ?? false
        case .digital: return title.digitalReleaseDate.map { $0 <= now } ?? false
        }
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
