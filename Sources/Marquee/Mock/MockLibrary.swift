import Foundation
import MarqueeUI

/// Deterministic in-memory `LibraryDataSource`: ~60 invented titles with generated artwork, no network.
/// Replace with the real GRDB-backed source behind the same protocol.
struct MockLibrary: LibraryDataSource {
    // MARK: Catalogue

    private struct Seed {
        let name: String
        let genres: [String]
        let symbol: String
    }

    private static let series: [Seed] = [
        Seed(name: "Harbor Lights", genres: ["Drama"], symbol: "sailboat.fill"),
        Seed(name: "Northern Static", genres: ["Sci-Fi", "Mystery"], symbol: "antenna.radiowaves.left.and.right"),
        Seed(name: "The Glass Orchard", genres: ["Mystery"], symbol: "leaf.fill"),
        Seed(name: "Low Tide Society", genres: ["Comedy"], symbol: "water.waves"),
        Seed(name: "Parallel Lines", genres: ["Sci-Fi"], symbol: "arrow.triangle.branch"),
        Seed(name: "Salt & Ember", genres: ["Drama"], symbol: "flame.fill"),
        Seed(name: "Midnight Cartographers", genres: ["Fantasy"], symbol: "map.fill"),
        Seed(name: "Paper Kingdoms", genres: ["Fantasy"], symbol: "crown.fill"),
        Seed(name: "Copper Valley", genres: ["Western"], symbol: "mountain.2.fill"),
        Seed(name: "The Last Signal", genres: ["Thriller"], symbol: "dot.radiowaves.left.and.right"),
        Seed(name: "Orbit House", genres: ["Sci-Fi"], symbol: "moon.stars.fill"),
        Seed(name: "Velvet Hours", genres: ["Drama"], symbol: "theatermasks.fill"),
        Seed(name: "Hollow Pines", genres: ["Horror"], symbol: "tree.fill"),
        Seed(name: "Signal Fires", genres: ["Adventure"], symbol: "flame"),
        Seed(name: "The Understudies", genres: ["Comedy"], symbol: "person.2.fill"),
        Seed(name: "Neon Almanac", genres: ["Crime"], symbol: "building.2.fill"),
        Seed(name: "Quiet Harbor", genres: ["Drama"], symbol: "water.waves"),
        Seed(name: "Brass & Bone", genres: ["Period"], symbol: "gearshape.fill"),
        Seed(name: "Winter Cartel", genres: ["Crime"], symbol: "snowflake"),
        Seed(name: "Echo Station", genres: ["Sci-Fi"], symbol: "wave.3.right"),
        Seed(name: "The Long Count", genres: ["Documentary"], symbol: "clock.fill"),
        Seed(name: "Kite Season", genres: ["Family"], symbol: "wind"),
        Seed(name: "Marrow Road", genres: ["Thriller"], symbol: "road.lanes"),
        Seed(name: "Sunday Orchestra", genres: ["Music"], symbol: "music.note"),
        Seed(name: "Daylight Rules", genres: ["Comedy"], symbol: "sun.max.fill"),
        Seed(name: "Tidewater", genres: ["Drama"], symbol: "drop.fill"),
        Seed(name: "Ghost Frequency", genres: ["Horror"], symbol: "headphones"),
        Seed(name: "Atlas Rising", genres: ["Adventure"], symbol: "globe.europe.africa.fill"),
    ]

    private static let movies: [Seed] = [
        Seed(name: "Amber Skies", genres: ["Drama"], symbol: "sun.haze.fill"),
        Seed(name: "The Cartographer's Daughter", genres: ["Adventure"], symbol: "map"),
        Seed(name: "Static Bloom", genres: ["Sci-Fi"], symbol: "sparkles"),
        Seed(name: "Night Ferry", genres: ["Thriller"], symbol: "ferry.fill"),
        Seed(name: "Rust & Rain", genres: ["Drama"], symbol: "cloud.rain.fill"),
        Seed(name: "A Quiet Departure", genres: ["Drama"], symbol: "airplane.departure"),
        Seed(name: "Seven Lanterns", genres: ["Fantasy"], symbol: "light.beacon.max.fill"),
        Seed(name: "Gravity of Home", genres: ["Family"], symbol: "house.fill"),
        Seed(name: "The Salt Road", genres: ["Adventure"], symbol: "road.lanes"),
        Seed(name: "Cold Open", genres: ["Comedy"], symbol: "film"),
        Seed(name: "Lucky Hour", genres: ["Comedy"], symbol: "clock"),
        Seed(name: "Blue Meridian", genres: ["Adventure"], symbol: "globe"),
        Seed(name: "Small Hours", genres: ["Drama"], symbol: "moon.fill"),
        Seed(name: "The Paper Moon Affair", genres: ["Romance"], symbol: "moon.circle.fill"),
        Seed(name: "Fathom", genres: ["Sci-Fi"], symbol: "binoculars.fill"),
        Seed(name: "Glass Season", genres: ["Mystery"], symbol: "circle.hexagongrid.fill"),
        Seed(name: "Hush Protocol", genres: ["Thriller"], symbol: "lock.shield.fill"),
        Seed(name: "Wild Frequency", genres: ["Music"], symbol: "guitars.fill"),
        Seed(name: "Dust Bowl Hearts", genres: ["Romance"], symbol: "heart.fill"),
        Seed(name: "Orchid Heist", genres: ["Crime"], symbol: "camera.macro"),
        Seed(name: "Second Sunrise", genres: ["Drama"], symbol: "sunrise.fill"),
        Seed(name: "The Ninth Floor", genres: ["Horror"], symbol: "building.fill"),
        Seed(name: "Skyline Drifters", genres: ["Comedy"], symbol: "bicycle"),
        Seed(name: "Marble Falls", genres: ["Adventure"], symbol: "figure.hiking"),
        Seed(name: "Foxglove", genres: ["Mystery"], symbol: "pawprint.fill"),
        Seed(name: "Lantern Street", genres: ["Drama"], symbol: "lamp.floor.fill"),
        Seed(name: "Harvest Moon Motel", genres: ["Horror"], symbol: "bed.double.fill"),
        Seed(name: "Kingfisher", genres: ["Family"], symbol: "bird.fill"),
        Seed(name: "Tall Grass", genres: ["Drama"], symbol: "leaf"),
        Seed(name: "Zero Gravity Blues", genres: ["Sci-Fi"], symbol: "figure.wave"),
        Seed(name: "The Understudy's Gambit", genres: ["Comedy"], symbol: "theatermasks"),
        Seed(name: "Midwinter", genres: ["Drama"], symbol: "snowflake"),
    ]

    private static let episodeTitles = [
        "Pilot", "The Long Way Down", "Static", "Dead Reckoning", "What the Tide Brings", "Small Hours",
        "Paper Lanterns", "A Fire in March", "Strangers on the Pier", "The Understudy", "Cold Open", "Low Orbit",
        "Foxglove", "Safe Harbor", "Breaking Weather", "The Quiet Room", "Second Sunrise", "Letters Home",
        "Ghost Light", "Marrow", "Salt Road", "Open Water", "The Long Count", "Homecoming",
    ]

    private static let overviews = [
        "An unexpected arrival forces everyone to reconsider what they thought they knew.",
        "Old loyalties are tested when a secret from the past resurfaces.",
        "A routine job turns into something far bigger than anyone planned for.",
        "Two strangers cross paths on the worst night of the year.",
        "The town prepares for a storm, and for the truth that comes with it.",
        "A hard choice splits the group just as time runs out.",
    ]

    private static let cast = [
        "Mara Linden", "Tobias Reyes", "Ines Okafor", "Callum Voss", "Priya Nair", "Jonas Albrecht",
        "Lena Moretti", "Idris Hale", "Sofia Marchetti", "Noor Haddad", "Theo Lindqvist", "Wren Calloway",
    ]

    private static let seriesCount = series.count

    // MARK: State

    private struct Entry: Sendable {
        var item: PosterItem
        var seed: Seed
        var index: Int
        var seasons: Int
        var runtime: Int
        var comingSoon: Bool
        var nextUp: Bool
    }

    private let entries: [Entry]
    private let now: Date
    private let downloads: [Download]

    /// A simulated active download (title, or a single episode of a series).
    struct Download: Sendable {
        var progressID: String
        var titleID: String
        var label: String
        var startFraction: Double
        var totalSeconds: TimeInterval
        var baseSpeed: Double
        var peers: Int
        var quality: Quality
        var episode: EpisodeRef?
    }

    struct EpisodeRef: Sendable {
        var season: Int
        var number: Int
    }

    // Indices with special roles.
    private static let downloadingSeries: [Int: (season: Int, fraction: Double)] = [1: (1, 0.42), 6: (2, 0.36), 10: (1, 0.71)]
    private static let downloadingMovies: [Int: Double] = [2: 0.012, 5: 0.58, 11: 0.23]
    private static let queued: Set<Int> = [14, seriesCount + 8]
    private static let importing: Set<Int> = [seriesCount + 3]
    private static let comingSoonIndices: Set<Int> = [3, 20, seriesCount + 14, seriesCount + 22, seriesCount + 29, seriesCount + 30]
    private static let inProgress: [Int: Double] = [
        0: 0.35, 4: 0.62, 11: 0.12, 17: 0.80, seriesCount + 0: 0.62, seriesCount + 6: 0.27, seriesCount + 12: 0.9,
    ]
    private static let nextUpSeries: Set<Int> = [2, 5, 8, 12, 15, 19, 22, 24]
    private static let missing: Set<Int> = [9, 16, 25, seriesCount + 9, seriesCount + 19, seriesCount + 26]
    private static let watched: Set<Int> = [7, 13, 21, 23, seriesCount + 1, seriesCount + 4, seriesCount + 10, seriesCount + 16]

    init(now: Date = Date()) {
        self.now = now
        let all = Self.series + Self.movies
        var entries: [Entry] = []
        var downloads: [Download] = []
        let qualities: [Quality] = [.p1080, .uhdHDR, .p720, .p1080, .uhd, .p1080]

        for (i, seed) in all.enumerated() {
            let isSeries = i < Self.seriesCount
            let kind: MediaKind = isSeries ? .series : .movie
            let id = "t\(String(format: "%02d", i))"
            let year = 2014 + (i * 7) % 12
            let seasons = isSeries ? 1 + (i % 4) : 0
            let runtime = isSeries ? 38 + (i % 4) * 7 : 88 + (i * 11) % 54
            let hue = (Double(i) * 0.0861 + 0.03).truncatingRemainder(dividingBy: 1)
            let art = PlaceholderArt(hue: hue, symbol: seed.symbol, variant: i)
            let backdropArt = PlaceholderArt(hue: hue + 0.02, symbol: seed.symbol, variant: i + 1)
            let comingSoon = Self.comingSoonIndices.contains(i)

            var availability: Availability = .local
            var fraction: Double?
            if comingSoon { availability = .unaired }
            else if let d = isSeries ? Self.downloadingSeries[i]?.fraction : Self.downloadingMovies[i - Self.seriesCount] {
                availability = .downloading
                fraction = d
            } else if Self.queued.contains(i) { availability = .queued }
            else if Self.importing.contains(i) { availability = .importing }
            else if Self.missing.contains(i) { availability = .missing }

            var watch: WatchState = .unwatched
            if let f = Self.inProgress[i] { watch = .inProgress(f) }
            else if Self.watched.contains(i) { watch = .watched }

            let subtitle: String
            if comingSoon {
                let days = 6 + (i * 5) % 40
                subtitle = String(localized: "Arrives \(Formatters.shortDate(now.addingTimeInterval(Double(days) * 86_400)))")
            } else if isSeries {
                subtitle = "\(year) · " + (seasons == 1 ? String(localized: "1 Season") : String(localized: "\(seasons) Seasons"))
            } else {
                subtitle = "\(year) · \(Formatters.runtime(minutes: runtime))"
            }

            let quality: Quality? = (availability == .local || availability == .importing) ? qualities[i % qualities.count] : nil
            let item = PosterItem(
                id: id, kind: kind, title: seed.name, subtitle: subtitle, year: year,
                addedAt: now.addingTimeInterval(-Double((i * 37) % 90 + 1) * 86_400 / 3),
                poster: .generated(art), backdrop: .generated(backdropArt),
                watch: watch, availability: availability, downloadFraction: fraction,
                quality: quality, genres: seed.genres
            )
            entries.append(Entry(
                item: item, seed: seed, index: i, seasons: seasons, runtime: runtime,
                comingSoon: comingSoon, nextUp: isSeries && Self.nextUpSeries.contains(i)
            ))

            // Simulated downloads
            if availability == .downloading, let f = fraction {
                if isSeries, let spec = Self.downloadingSeries[i] {
                    downloads.append(Download(
                        progressID: id, titleID: id, label: "\(seed.name) · S\(spec.season) pack", startFraction: f,
                        totalSeconds: 5400 + Double(i) * 30, baseSpeed: 9_400_000, peers: 48 + i, quality: .p1080, episode: nil
                    ))
                } else {
                    downloads.append(Download(
                        progressID: id, titleID: id, label: seed.name, startFraction: f,
                        totalSeconds: f < 0.05 ? 4300 : 2400 + Double(i) * 20, baseSpeed: 14_200_000, peers: 31 + i % 17,
                        quality: i % 2 == 0 ? .uhdHDR : .p1080, episode: nil
                    ))
                }
            }
        }
        self.entries = entries
        self.downloads = downloads + Self.episodeDownloads(entries)
    }

    /// The in-flight episodes of series that are mid-download (these drive episode rings and Activity).
    private static func episodeDownloads(_ entries: [Entry]) -> [Download] {
        var result: [Download] = []
        for (index, spec) in downloadingSeries.sorted(by: { $0.key < $1.key }) {
            let e = entries[index]
            let id = e.item.id
            let eps = episodeCount(for: e.index, season: spec.season)
            for (offset, number) in [3, 4].enumerated() where number <= eps {
                result.append(Download(
                    progressID: "\(id)-s\(spec.season)e\(number)", titleID: id,
                    label: "\(e.seed.name) · S\(spec.season)E\(number)",
                    startFraction: spec.fraction - Double(offset) * 0.2 + 0.1,
                    totalSeconds: 600 + Double(offset) * 240, baseSpeed: 8_100_000 - Double(offset) * 1_900_000,
                    peers: 22 + index + offset * 7, quality: .p1080, episode: EpisodeRef(season: spec.season, number: number)
                ))
            }
        }
        return result
    }

    private static func episodeCount(for index: Int, season: Int) -> Int {
        8 + (index % 3) * 2
    }

    // MARK: LibraryDataSource

    func library() async throws -> [PosterItem] {
        entries.map(\.item)
    }

    func homeShelves() async throws -> [ShelfModel] {
        let byAdded = entries.sorted { $0.item.addedAt > $1.item.addedAt }

        let continueWatching = entries.compactMap { e -> PosterItem? in
            guard let f = e.item.watch.fraction else { return nil }
            var item = e.item
            let remaining = Int(Double(e.runtime) * (1 - f))
            if e.item.kind == .series {
                let s = max(1, e.seasons - (e.index % 2)), ep = 2 + e.index % 5
                item.subtitle = "S\(s) · E\(ep) · " + String(localized: "\(remaining) min left")
            } else {
                item.subtitle = String(localized: "\(remaining) min left")
            }
            return item
        }

        let nextUp = entries.filter(\.nextUp).map { e -> PosterItem in
            var item = e.item
            item.subtitle = String(localized: "Up next · S\(max(1, e.seasons)) · E\(1 + e.index % 4)")
            return item
        }

        let downloading = entries.filter { $0.item.availability == .downloading || $0.item.availability == .queued }
            .map(\.item)

        let recent = byAdded.filter { $0.item.availability == .local && !$0.comingSoon }.prefix(14).map(\.item)
        let soon = entries.filter(\.comingSoon).sorted { $0.item.id < $1.item.id }.map(\.item)

        return [
            ShelfModel(id: "continue", title: String(localized: "Continue Watching"), style: .wide, items: continueWatching),
            ShelfModel(id: "nextup", title: String(localized: "Next Up"), subtitle: String(localized: "New episodes of shows you follow"), items: nextUp),
            ShelfModel(id: "downloading", title: String(localized: "Downloading Now"), subtitle: String(localized: "Press Play on anything with a ring"), items: downloading),
            ShelfModel(id: "recent", title: String(localized: "Recently Added"), items: Array(recent), showsSeeAll: true),
            ShelfModel(id: "soon", title: String(localized: "Coming Soon"), items: soon),
        ]
    }

    func detail(for id: PosterItem.ID) async throws -> TitleDetail? {
        guard let e = entries.first(where: { $0.item.id == id }) else { return nil }
        let item = e.item
        let overview = Self.overviews[e.index % Self.overviews.count] + " "
            + Self.overviews[(e.index + 3) % Self.overviews.count]
        let cast = (0..<5).map { Self.cast[(e.index * 3 + $0 * 5) % Self.cast.count] }
        let certification = ["TV-14", "TV-MA", "PG-13", "R", "TV-PG"][e.index % 5]
        let score = 6.4 + Double((e.index * 7) % 26) / 10

        if item.kind == .movie {
            var resume: ResumePoint?
            if let f = item.watch.fraction {
                resume = ResumePoint(label: "", fraction: f, remainingMinutes: Int(Double(e.runtime) * (1 - f)))
            }
            var info: [String] = []
            if item.availability == .local, let q = item.quality {
                info = [q.resolution == .uhd ? "2160p" : "\(q.resolution.rawValue)p" + (q.hdr ? " HDR10" : ""),
                        q.resolution == .uhd ? "HEVC" : "H.264",
                        q.hdr ? "Atmos" : "5.1",
                        String(format: "%.1f GB", Double(e.runtime) / 7.5)]
                if q.resolution == .uhd { info[0] = "2160p" + (q.hdr ? " HDR10" : "") }
            }
            return TitleDetail(
                item: item, tagline: String(localized: "Some stories find you."), overview: overview,
                certification: certification, score: score, runtimeMinutes: e.runtime, cast: cast,
                resume: resume, fileInfo: info
            )
        }

        let seasons = (1...max(1, e.seasons)).map { s in seasonModel(e, season: s) }
        // First episode that isn't watched, for the Resume label.
        var resume: ResumePoint?
        if item.watch != .watched, let next = seasons.flatMap(\.episodes).first(where: { $0.watch != .watched && $0.availability != .unaired }),
           item.watch.fraction != nil || e.nextUp {
            let f = next.watch.fraction ?? 0
            resume = ResumePoint(label: "S\(next.season) · E\(next.number)", fraction: f, remainingMinutes: Int(Double(next.runtimeMinutes) * (1 - f)))
        }
        return TitleDetail(
            item: item, tagline: nil, overview: overview, certification: certification, score: score,
            runtimeMinutes: e.runtime, cast: cast, seasons: seasons, resume: resume
        )
    }

    private func seasonModel(_ e: Entry, season s: Int) -> SeasonModel {
        let count = Self.episodeCount(for: e.index, season: s)
        let item = e.item
        let isLast = s == e.seasons
        let downloadingSeason = Self.downloadingSeries[e.index]?.season

        // How many episodes of the whole show are watched (in order) for progress states.
        let totalEpisodes = (1...max(1, e.seasons)).reduce(0) { $0 + Self.episodeCount(for: e.index, season: $1) }
        let watchedUpTo: Int
        let partial: Double?
        switch item.watch {
        case .watched: watchedUpTo = totalEpisodes; partial = nil
        case .inProgress(let f): watchedUpTo = Int(Double(totalEpisodes) * f * 0.8); partial = f
        case .unwatched: watchedUpTo = e.nextUp ? max(1, totalEpisodes / 2) : 0; partial = nil
        }
        let before = (1..<s).reduce(0) { $0 + Self.episodeCount(for: e.index, season: $1) }
        let episodes = (1...count).map { n -> EpisodeModel in
            let ordinal = before + n
            var watch: WatchState = .unwatched
            if ordinal <= watchedUpTo { watch = .watched }
            else if ordinal == watchedUpTo + 1, let p = partial { watch = .inProgress(min(0.9, max(0.1, p))) }

            var availability: Availability = .local
            var fraction: Double?
            var quality: Quality? = item.quality ?? .p1080
            if e.comingSoon {
                availability = .unaired
                quality = nil
            } else if s == downloadingSeason {
                switch n {
                case 1...2: availability = .local
                case 3...4:
                    availability = .downloading
                    fraction = downloads.first { $0.progressID == "\(item.id)-s\(s)e\(n)" }?.startFraction ?? 0.3
                    quality = nil
                case 5...6: availability = .queued; quality = nil
                default: availability = .missing; quality = nil
                }
            } else if item.availability == .queued, isLast {
                availability = .queued
                quality = nil
            } else if item.availability == .missing {
                availability = .missing
                quality = nil
            }
            let air = now.addingTimeInterval(Double((s - e.seasons) * 120 + (n - count) * 7) * 86_400)
            return EpisodeModel(
                id: "\(item.id)-s\(s)e\(n)", season: s, number: n,
                title: Self.episodeTitles[(e.index * 5 + before + n) % Self.episodeTitles.count],
                overview: Self.overviews[(e.index + before + n) % Self.overviews.count],
                runtimeMinutes: e.runtime + (n % 3) * 2 - 2, airDate: air,
                still: .generated(PlaceholderArt(hue: item.poster.placeholder.hue + Double(n) * 0.012, symbol: item.poster.placeholder.symbol, variant: n + s)),
                watch: watch, availability: availability, downloadFraction: fraction, quality: quality
            )
        }
        return SeasonModel(number: s, episodes: episodes)
    }

    func activity() async throws -> [ActivityItem] {
        var items: [ActivityItem] = []
        func entry(_ id: String) -> Entry { entries.first { $0.item.id == id }! }

        for (n, d) in downloads.enumerated() {
            let e = entry(d.titleID)
            items.append(ActivityItem(
                id: d.progressID, titleID: d.titleID, title: d.label,
                detail: d.episode == nil ? e.item.subtitle : String(localized: "Season pack, episodes import as they finish"),
                poster: e.item.poster, phase: .downloading, fraction: d.startFraction, totalSeconds: d.totalSeconds,
                bytesPerSecond: d.baseSpeed, peers: d.peers, quality: d.quality,
                date: now.addingTimeInterval(-Double(n) * 420)
            ))
        }

        let searchTarget = entries[Self.seriesCount - 7]       // Kite Season
        items.append(ActivityItem(
            id: "act-search", titleID: searchTarget.item.id, title: searchTarget.seed.name + " · S1E1",
            detail: String(localized: "Searching 6 indexers for the best stream-friendly release"),
            poster: searchTarget.item.poster, phase: .searching, date: now.addingTimeInterval(-20)
        ))

        let importing = entries[Self.seriesCount + 3]
        items.append(ActivityItem(
            id: "act-import", titleID: importing.item.id, title: importing.seed.name,
            detail: String(localized: "Verifying and renaming into your Movies folder"),
            poster: importing.item.poster, phase: importing.item.availability == .importing ? .importing : .ready,
            fraction: 1, quality: .p1080, date: now.addingTimeInterval(-95)
        ))

        let sub = entries[Self.seriesCount + 7]
        items.append(ActivityItem(
            id: "act-sub", titleID: sub.item.id, title: sub.seed.name,
            detail: String(localized: "Finding English subtitles"), poster: sub.item.poster,
            phase: .subtitles, fraction: 1, quality: .uhdHDR, date: now.addingTimeInterval(-340)
        ))

        let doneIndices = [0, 4, 11, Self.seriesCount + 0, Self.seriesCount + 10, 17, Self.seriesCount + 20, 2]
        for (n, idx) in doneIndices.enumerated() {
            let e = entries[idx]
            items.append(ActivityItem(
                id: "done-\(idx)", titleID: e.item.id, title: e.seed.name,
                detail: n % 2 == 0 ? String(localized: "Imported to your library") : String(localized: "Imported, subtitles added"),
                poster: e.item.poster, phase: .ready, fraction: 1, quality: e.item.quality ?? .p1080,
                date: now.addingTimeInterval(-3600 * Double(2 + n * 5))
            ))
        }

        let failed = entries[Self.seriesCount + 21]
        items.append(ActivityItem(
            id: "fail-1", titleID: failed.item.id, title: failed.seed.name,
            detail: String(localized: "Couldn't find a healthy source"), poster: failed.item.poster, phase: .failed,
            date: now.addingTimeInterval(-3600 * 9),
            failureMessage: String(localized: "None of the 14 releases we found had enough people sharing them. We'll keep checking and start it as soon as one is healthy.")
        ))
        return items
    }

    func liveProgress() -> AsyncStream<[ProgressUpdate]> {
        let downloads = self.downloads
        return AsyncStream { continuation in
            let task = Task {
                var fractions = Dictionary(uniqueKeysWithValues: downloads.map { ($0.progressID, $0.startFraction) })
                var tick = 0.0
                while !Task.isCancelled {
                    var batch: [ProgressUpdate] = []
                    for (n, d) in downloads.enumerated() {
                        // Speed wobbles like a real swarm; fraction advances by speed over the simulated total.
                        let wobble = 1 + 0.35 * sin(tick / 3 + Double(n))
                        let speed = d.baseSpeed * wobble
                        var f = fractions[d.progressID, default: 0] + wobble / d.totalSeconds * 14
                        if f >= 1 { f = 0.02 }
                        fractions[d.progressID] = f
                        batch.append(ProgressUpdate(
                            id: d.progressID, fraction: f, etaSeconds: (1 - f) * d.totalSeconds / wobble, bytesPerSecond: speed
                        ))
                    }
                    continuation.yield(batch)
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
