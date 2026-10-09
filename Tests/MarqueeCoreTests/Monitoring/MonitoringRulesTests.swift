import Foundation
import Testing

@testable import MarqueeCore

@Suite struct MonitoringRulesTests {
    @Test func expandsAllMonitoringModes() {
        let today = date(2026, 10, 9)
        let drafts = [
            SeasonDraft(seasonNumber: 0, episodes: [EpisodeDraft(episodeNumber: 1, airDate: date(2026, 1, 1))]),
            SeasonDraft(seasonNumber: 1, episodes: [
                EpisodeDraft(episodeNumber: 1, airDate: date(2026, 1, 1)),
                EpisodeDraft(episodeNumber: 2, airDate: date(2026, 10, 10)),
            ]),
            SeasonDraft(seasonNumber: 2, episodes: [EpisodeDraft(episodeNumber: 1, airDate: date(2027, 1, 1))]),
        ]

        func selected(_ mode: MonitorMode) -> Set<MonitoredEpisodeKey> {
            Set(MonitoringRules.episodeFlags(mode: mode, titleMonitored: true, seasons: drafts, now: today)
                .values.flatMap(\.keys).filter {
                    let season = MonitoringRules.episodeFlags(mode: mode, titleMonitored: true, seasons: drafts, now: today)
                    return season[$0.season]?[$0] == true
                })
        }
        #expect(selected(.all).count == 4)
        #expect(selected(.future) == [MonitoredEpisodeKey(season: 1, episode: 2), MonitoredEpisodeKey(season: 2, episode: 1)])
        #expect(selected(.firstSeason) == [MonitoredEpisodeKey(season: 1, episode: 1), MonitoredEpisodeKey(season: 1, episode: 2)])
        #expect(selected(.latestSeason) == [MonitoredEpisodeKey(season: 2, episode: 1)])
        #expect(selected(.pilot) == [MonitoredEpisodeKey(season: 1, episode: 1)])
        let specificDrafts = drafts.map { season in
            SeasonDraft(seasonNumber: season.seasonNumber, episodes: season.episodes.map { episode in
                EpisodeDraft(
                    episodeNumber: episode.episodeNumber, airDate: episode.airDate,
                    monitored: season.seasonNumber == 1 && episode.episodeNumber == 2)
            })
        }
        #expect(MonitoringRules.episodeFlags(mode: .specific, titleMonitored: true, seasons: specificDrafts, now: today)
            .values.flatMap(\.values).filter { $0 }.count == 1)
        #expect(selected(.none).count == 0)
        #expect(MonitoringRules.episodeFlags(mode: .all, titleMonitored: false, seasons: drafts).values.flatMap(\.values).allSatisfy { !$0 })
    }

    @Test func preservesExplicitEpisodeTogglesOnRefresh() {
        let drafts = [SeasonDraft(seasonNumber: 1, episodes: [
            EpisodeDraft(episodeNumber: 1), EpisodeDraft(episodeNumber: 2), EpisodeDraft(episodeNumber: 3),
        ])]
        let existing: [MonitoredEpisodeKey: Bool] = [
            .init(season: 1, episode: 1): false,
            .init(season: 1, episode: 2): true,
        ]
        let result = MonitoringRules.episodeFlags(
            mode: .all, titleMonitored: true, seasons: drafts,
            existing: existing)[1]!
        #expect(result[.init(season: 1, episode: 1)] == false)
        #expect(result[.init(season: 1, episode: 2)] == true)
        #expect(result[.init(season: 1, episode: 3)] == true)
    }

    @Test func movieAvailabilityUsesConfiguredReleaseDate() {
        let title = Title(
            kind: .movie, title: "Future Movie", monitored: true, minimumAvailability: .digital,
            releaseDate: date(2026, 1, 1), digitalReleaseDate: date(2026, 12, 1))
        #expect(!MonitoringRules.movieIsAvailable(title, now: date(2026, 11, 1)))
        #expect(MonitoringRules.movieIsAvailable(title, now: date(2026, 12, 1)))
    }

    @Test func wantedTargetsRequireMonitoredAiredMissingEpisodesAndReportCutoff() {
        let title = Title(kind: .series, title: "Example", monitored: true)
        let season = UUID()
        let episode = Episode(
            titleId: title.id, seasonId: season, seasonNumber: 1, episodeNumber: 2,
            airDate: date(2026, 10, 1), monitored: true)
        let future = Episode(
            titleId: title.id, seasonId: season, seasonNumber: 1, episodeNumber: 3,
            airDate: date(2026, 10, 20), monitored: true)
        let missing = WantedQuery.missing(title: title, episodes: [episode, future], now: date(2026, 10, 9))
        #expect(missing.map { $0.episode?.id } == [episode.id])
        #expect(WantedQuery.missing(
            title: title, episodes: [episode], fileEpisodeIDs: [episode.id], now: date(2026, 10, 9)).isEmpty)

        let profile = QualityProfileConfig(
            name: "Upgrade", groups: [
                QualityGroup(tiers: [.webDL720p]), QualityGroup(tiers: [.webDL1080p]),
            ], cutoff: .webDL1080p, upgradeUntilFormatScore: 10)
        let file = CurrentFile(tier: .webDL1080p, formatScore: 5)
        let upgrades = WantedQuery.cutoffUnmet(
            title: title, episodes: [episode, future], currentFiles: [episode.id: file], profile: profile)
        #expect(upgrades.map { $0.episode?.id } == [episode.id])
    }

    @Test func repositoryAppliesModeToEpisodesAndDedupeResolvesHealthIssues() async throws {
        let database = try AppDatabase.inMemory()
        let library = GRDBLibraryRepository(database)
        let title = try await library.add(
            Title(kind: .series, title: "Mode test", monitorMode: .pilot),
            seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1), EpisodeDraft(episodeNumber: 2)])])
        let episodes = try await library.episodes(titleId: title.id)
        #expect(episodes.map(\.monitored) == [true, false])

        let health = GRDBHealthIssueRepository(database)
        let first = try await health.report(
            code: "indexerFailure", severity: .warning, message: "offline", fixAction: "test", entityId: "a")
        let second = try await health.report(
            code: "indexerFailure", severity: .error, message: "still offline", fixAction: "test", entityId: "a")
        #expect(first.id == second.id)
        #expect(try await health.active().count == 1)
        try await health.resolve(code: "indexerFailure", entityId: "a")
        #expect(try await health.active().isEmpty)
    }

    @Test func indexerAutoDisableIsPersistedAndExpires() async throws {
        let database = try AppDatabase.inMemory()
        let indexers = GRDBIndexerRepository(database)
        let id = UUID()
        let now = Date()
        try await indexers.upsert(Indexer(id: id, name: "Test", baseURL: "https://example.invalid/api"))
        try await indexers.recordSearchOutcome(
            id: id, succeeded: false, threshold: 1, disableFor: 600, now: now)
        let disabled = try #require(try await indexers.indexer(id: id))
        #expect(disabled.failureCount == 1)
        #expect(abs(try #require(disabled.disabledUntil).timeIntervalSince(now.addingTimeInterval(600))) < 1)
        #expect(disabled.definition?.enabled == false)

        try await indexers.recordSearchOutcome(
            id: id, succeeded: true, threshold: 1, disableFor: 600, now: now.addingTimeInterval(601))
        let recovered = try #require(try await indexers.indexer(id: id))
        #expect(recovered.failureCount == 0)
        #expect(recovered.disabledUntil == nil)
        #expect(recovered.definition?.enabled == true)
    }
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
}
