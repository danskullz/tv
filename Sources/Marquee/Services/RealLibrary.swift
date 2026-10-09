import Foundation
import GRDB
import MarqueeCore
import MarqueeUI
import TorrentEngine

/// `LibraryDataSource` backed by the database, TMDB metadata and the live download monitor.
/// Replaces `MockLibrary` unless the app is launched with `-mockData YES`.
struct RealLibrary: LibraryDataSource {
    let database: AppDatabase
    let repo: GRDBLibraryRepository
    let watchStates: GRDBWatchStateRepository
    let torrents: GRDBTorrentRepository
    let monitor: DownloadMonitor
    /// Hops to the main actor for the shared TMDB client (nil until a key is saved).
    let tmdb: @Sendable () async -> TMDBClient?

    // MARK: Aggregates

    /// Everything needed to turn title rows into cards, loaded with a handful of grouped queries.
    private struct Snapshot {
        var seasonCount: [UUID: Int] = [:]
        var episodeCount: [UUID: Int] = [:]
        var watchedCount: [UUID: Int] = [:]
        var progress: [UUID: Double] = [:]
        var fileResolution: [UUID: Int] = [:]
        var movieWatch: [UUID: MarqueeCore.WatchState] = [:]
        var downloading: Set<UUID> = []
    }

    private func snapshot() async throws -> Snapshot {
        let active = Set((await monitor.active).map(\.titleID))
        var snap = try await database.writer.read { db -> Snapshot in
            var s = Snapshot()
            for row in try Row.fetchAll(
                db, sql: "SELECT titleId, COUNT(DISTINCT seasonNumber) AS seasons, COUNT(*) AS episodes FROM episode WHERE seasonNumber > 0 GROUP BY titleId")
            {
                let id: UUID = row["titleId"]
                s.seasonCount[id] = row["seasons"]
                s.episodeCount[id] = row["episodes"]
            }
            for state in try MarqueeCore.WatchState.fetchAll(db) {
                if state.watched { s.watchedCount[state.titleId, default: 0] += 1 }
                if !state.watched, state.positionSeconds > 0, let d = state.durationSeconds, d > 0 {
                    s.progress[state.titleId] = max(s.progress[state.titleId] ?? 0, min(0.98, state.positionSeconds / d))
                }
                s.movieWatch[state.id] = state
            }
            for row in try Row.fetchAll(db, sql: "SELECT titleId, MAX(resolution) AS res FROM mediaFile GROUP BY titleId") {
                let id: UUID = row["titleId"]
                if let res: Int = row["res"] { s.fileResolution[id] = res }
            }
            return s
        }
        snap.downloading = active
        return snap
    }

    private func item(_ t: Title, _ s: Snapshot, now: Date = Date()) -> PosterItem {
        let isMovie = t.kind == .movie
        var watch: MarqueeUI.WatchState = .unwatched
        if isMovie {
            if let state = s.movieWatch[t.id] {
                if state.watched { watch = .watched }
                else if let d = state.durationSeconds, d > 0, state.positionSeconds > 0 { watch = .inProgress(min(0.98, state.positionSeconds / d)) }
            }
        } else {
            let total = s.episodeCount[t.id] ?? 0
            let watched = s.watchedCount[t.id] ?? 0
            if total > 0, watched >= total { watch = .watched }
            else if let p = s.progress[t.id] { watch = .inProgress(p) }
            else if watched > 0, total > 0 { watch = .inProgress(Double(watched) / Double(total)) }
        }

        var availability: Availability = .missing
        if s.downloading.contains(t.id) { availability = .downloading }
        else if s.fileResolution[t.id] != nil { availability = .local }
        else if Self.isUnreleased(t) { availability = .unaired }

        let year = t.year ?? 0
        let subtitle: String
        if isMovie {
            subtitle = year > 0 ? "\(year)" : ""
        } else {
            let seasons = s.seasonCount[t.id] ?? 0
            let seasonText = seasons == 0 ? "" : seasons == 1 ? String(localized: "1 Season") : String(localized: "\(seasons) Seasons")
            subtitle = [year > 0 ? "\(year)" : nil, seasonText.isEmpty ? nil : seasonText].compactMap { $0 }.joined(separator: " · ")
        }
        var quality: Quality?
        if let res = s.fileResolution[t.id] {
            quality = Quality(res >= 2160 ? .uhd : res >= 1080 ? .hd1080 : res >= 720 ? .hd720 : .sd)
        }
        return PosterItem(
            id: t.id.uuidString, kind: isMovie ? .movie : .series, title: t.title, subtitle: subtitle, year: year,
            addedAt: t.addedAt, poster: Self.art(t, backdrop: false), backdrop: Self.art(t, backdrop: true),
            watch: watch, availability: availability, quality: quality)
    }

    static func isUnreleased(_ t: Title) -> Bool {
        guard let status = t.status?.lowercased() else { return false }
        return ["planned", "in production", "post production", "rumored", "announced", "upcoming"].contains(status)
    }

    // MARK: Artwork

    static func art(_ t: Title, backdrop: Bool) -> Artwork {
        let hue = Double(t.title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 997 }) / 997
        let placeholder = PlaceholderArt(
            hue: hue, symbol: t.kind == .movie ? "film" : "tv", variant: backdrop ? 1 : 0)
        let path = backdrop ? (t.backdropPath ?? t.posterPath) : t.posterPath
        if let path, let url = ImagePath(path).url(size: backdrop ? .w1280 : .w342) {
            return .remote(url, placeholder: placeholder)
        }
        return .generated(placeholder)
    }

    // MARK: LibraryDataSource

    func library() async throws -> [PosterItem] {
        let titles = try await repo.titles(matching: MarqueeCore.LibraryFilter())
        let snap = try await snapshot()
        return titles.map { item($0, snap) }
    }

    func homeShelves() async throws -> [ShelfModel] {
        let snap = try await snapshot()
        let all = try await repo.titles(matching: MarqueeCore.LibraryFilter(sort: .recentlyAdded))
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        var continueItems: [PosterItem] = []
        var seen = Set<UUID>()
        for state in try await watchStates.continueWatching(limit: 24) where !seen.contains(state.titleId) {
            guard let title = byID[state.titleId] else { continue }
            seen.insert(title.id)
            var card = item(title, snap)
            let remaining = Int(max(0, (state.durationSeconds ?? 0) - state.positionSeconds) / 60)
            let left = remaining > 0 ? String(localized: "\(remaining) min left") : ""
            if title.kind == .series, let episode = try? await database.writer.read({ try Episode.fetchOne($0, key: state.id) }) {
                card.subtitle = ["S\(episode.seasonNumber) · E\(episode.episodeNumber)", left].filter { !$0.isEmpty }.joined(separator: " · ")
            } else {
                card.subtitle = left
            }
            continueItems.append(card)
        }
        let downloading = all.filter { snap.downloading.contains($0.id) }.map { item($0, snap) }
        let recent = all.prefix(14).map { item($0, snap) }
        return [
            ShelfModel(id: "continue", title: String(localized: "Continue Watching"), style: .wide, items: continueItems),
            ShelfModel(
                id: "downloading", title: String(localized: "Downloading Now"),
                subtitle: String(localized: "Playing while it downloads"), items: downloading),
            ShelfModel(id: "recent", title: String(localized: "Recently Added"), items: recent, showsSeeAll: true),
        ]
    }

    func detail(for id: PosterItem.ID) async throws -> TitleDetail? {
        guard let uuid = UUID(uuidString: id), let title = try await repo.title(id: uuid) else { return nil }
        let snap = try await snapshot()
        let card = item(title, snap)
        let client = await tmdb()

        var overview = title.overview ?? ""
        var tagline: String?
        var score: Double?
        var runtime: Int?
        var cast: [String] = []
        var certification = ""
        var infoBySeason: [Int: [Int: EpisodeInfo]] = [:]

        if let client, let tmdbID = title.tmdbId {
            if title.kind == .movie, let d = try? await client.movieDetails(id: tmdbID) {
                overview = d.overview ?? overview
                tagline = d.tagline.flatMap { $0.isEmpty ? nil : $0 }
                score = d.voteAverage
                runtime = d.runtime
                cast = d.credits.cast.prefix(6).map(\.name)
                certification = d.releaseDates(region: "US").certification ?? ""
            } else if title.kind == .series, let d = try? await client.seriesDetails(id: tmdbID) {
                overview = d.overview ?? overview
                tagline = d.tagline.flatMap { $0.isEmpty ? nil : $0 }
                score = d.voteAverage
                runtime = d.episodeRunTime.first
                cast = d.credits.cast.prefix(6).map(\.name)
                // Season details give stills and synopses, and fill in episodes the database lacks.
                var drafts: [SeasonDraft] = []
                await withTaskGroup(of: SeasonDetails?.self) { group in
                    for season in d.seasons {
                        group.addTask { try? await client.seasonDetails(seriesID: tmdbID, season: season.seasonNumber) }
                    }
                    for await details in group {
                        guard let details else { continue }
                        infoBySeason[details.seasonNumber] = Dictionary(
                            details.episodes.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { a, _ in a })
                        drafts.append(Self.draft(details, monitored: details.seasonNumber > 0))
                    }
                }
                try? await repo.mergeSeasons(titleId: title.id, seasons: drafts)
            }
        }

        let seasons = title.kind == .series ? try await seasonModels(title, info: infoBySeason, snapshot: snap) : []
        var resume: ResumePoint?
        if title.kind == .movie {
            if let state = snap.movieWatch[title.id], !state.watched, let d = state.durationSeconds, d > 0, state.positionSeconds > 5 {
                resume = ResumePoint(label: "", fraction: state.positionSeconds / d, remainingMinutes: Int((d - state.positionSeconds) / 60))
            }
        } else if let next = seasons.flatMap(\.episodes).first(where: { $0.watch != .watched && $0.availability != .unaired }),
            card.watch != .unwatched
        {
            let f = next.watch.fraction ?? 0
            resume = ResumePoint(label: "S\(next.season) · E\(next.number)", fraction: f, remainingMinutes: Int(Double(next.runtimeMinutes) * (1 - f)))
        }
        return TitleDetail(
            item: card, tagline: tagline, overview: overview.isEmpty ? String(localized: "No synopsis yet.") : overview,
            certification: certification, score: score, runtimeMinutes: runtime, cast: cast, seasons: seasons, resume: resume)
    }

    private func seasonModels(_ title: Title, info: [Int: [Int: EpisodeInfo]], snapshot snap: Snapshot) async throws -> [SeasonModel] {
        let episodes = try await repo.episodes(titleId: title.id)
        let states = Dictionary(uniqueKeysWithValues: try await watchStates.states(titleId: title.id).map { ($0.id, $0) })
        let activeEntries = (await monitor.active).filter { $0.titleID == title.id }
        let activeKeys = Set(activeEntries.flatMap(\.progressIDs))
        let bySeason = Dictionary(grouping: episodes, by: \.seasonNumber)
        let now = Date()
        return bySeason.keys.sorted().map { number in
            let models = (bySeason[number] ?? []).map { e -> EpisodeModel in
                let key = AppServices.episodeKey(title.id, season: e.seasonNumber, episode: e.episodeNumber)
                var watch: MarqueeUI.WatchState = .unwatched
                if let state = states[e.id] {
                    if state.watched { watch = .watched }
                    else if let d = state.durationSeconds, d > 0, state.positionSeconds > 0 { watch = .inProgress(min(0.98, state.positionSeconds / d)) }
                }
                var availability: Availability = .missing
                if activeKeys.contains(key) { availability = .downloading }
                else if let air = e.airDate, air > now { availability = .unaired }
                let extra = info[number]?[e.episodeNumber]
                let still: Artwork = {
                    let placeholder = PlaceholderArt(hue: Self.hue(title.title) + Double(e.episodeNumber) * 0.012, symbol: "tv", variant: e.episodeNumber)
                    if let path = extra?.stillPath, let url = path.url(size: .w300) { return .remote(url, placeholder: placeholder) }
                    return .generated(placeholder)
                }()
                return EpisodeModel(
                    id: key, season: e.seasonNumber, number: e.episodeNumber,
                    title: e.title ?? "Episode \(e.episodeNumber)", overview: extra?.overview ?? "",
                    runtimeMinutes: e.runtime ?? extra?.runtime ?? 0, airDate: e.airDate, still: still,
                    watch: watch, availability: availability)
            }
            return SeasonModel(number: number, episodes: models)
        }
    }

    static func hue(_ s: String) -> Double {
        Double(s.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 997 }) / 997
    }

    static func draft(_ details: SeasonDetails, monitored: Bool) -> SeasonDraft {
        SeasonDraft(
            seasonNumber: details.seasonNumber, monitored: monitored,
            episodes: details.episodes.map {
                EpisodeDraft(
                    episodeNumber: $0.episodeNumber, airDate: $0.airDate, title: $0.name, runtime: $0.runtime,
                    monitored: details.seasonNumber > 0)
            })
    }

    func activity() async throws -> [ActivityItem] {
        let titles = Dictionary(uniqueKeysWithValues: try await repo.titles(matching: MarqueeCore.LibraryFilter()).map { ($0.id, $0) })
        var items: [ActivityItem] = []
        for sample in await monitor.sample() {
            guard let title = titles[sample.entry.titleID] else { continue }
            let s = sample.status
            let remaining = max(0, s.totalWanted - s.totalWantedDone)
            let eta = s.downloadRate > 1000 ? Double(remaining) / Double(s.downloadRate) : nil
            items.append(ActivityItem(
                id: sample.entry.id.hex, titleID: title.id.uuidString, title: sample.entry.label,
                detail: sample.entry.releaseName, poster: Self.art(title, backdrop: false), phase: .downloading,
                fraction: s.progress, totalSeconds: eta, bytesPerSecond: Double(s.downloadRate), peers: s.peerCount,
                date: sample.entry.startedAt))
        }
        let finished = try await torrents.torrents(in: [.finished, .seeding])
        for t in finished.prefix(20) {
            guard let id = t.titleId, let title = titles[id] else { continue }
            items.append(ActivityItem(
                id: "done-" + t.infoHash, titleID: id.uuidString, title: title.title, detail: t.name,
                poster: Self.art(title, backdrop: false), phase: .ready, fraction: 1, date: t.completedAt ?? t.updatedAt))
        }
        let failed = try await database.writer.read { db in
            try Grab.filter(Column("outcome") == Grab.Outcome.failed && Column("createdAt") > Date().addingTimeInterval(-86_400))
                .order(Column("createdAt").desc).limit(5).fetchAll(db)
        }
        for grab in failed {
            guard let title = titles[grab.titleId] else { continue }
            var message = "That release couldn't be played. Marquee tried the next best one."
            if case .string(let text)? = grab.reason["failure"] { message = text }
            items.append(ActivityItem(
                id: "fail-" + grab.id.uuidString, titleID: title.id.uuidString, title: title.title,
                detail: grab.releaseTitle, poster: Self.art(title, backdrop: false), phase: .failed, date: grab.createdAt,
                failureMessage: message))
        }
        return items
    }

    func liveProgress() -> AsyncStream<[ProgressUpdate]> {
        let monitor = self.monitor
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let updates = await monitor.progressUpdates()
                    continuation.yield(updates)
                    try? await Task.sleep(for: .seconds(updates.isEmpty ? 3 : 1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
