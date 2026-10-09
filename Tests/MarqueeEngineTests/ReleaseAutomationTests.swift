import Foundation
import MarqueeCore
import MarqueeEngine
import Testing

@Suite struct ReleaseAutomationTests {
    @Test func rssHoldsDelayedReleaseAndGrabsItAfterTheWindow() async throws {
        let database = try AppDatabase.inMemory()
        let library = GRDBLibraryRepository(database)
        let title = try await library.add(
            Title(kind: .series, title: "Marquee Test Pattern"),
            seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1, airDate: date(2026, 1, 1))])])
        let episode = try #require(try await library.episodes(titleId: title.id).first)
        let target = AutomationTarget(
            wanted: WantedTarget(
                title: title, episode: episode,
                item: .episode(title.title, season: 1, episodes: [1], runtimeMinutes: 20),
                currentFile: nil, reason: .missing),
            profile: .balanced,
            delayProfile: DelayProfileConfig(
                name: "Hold", delayMinutes: 60, bypassIfHighestQuality: false),
            savePath: FileManager.default.temporaryDirectory.appending(path: "marquee-automation-tests"))
        let now = date(2026, 10, 9)
        let release = makeAutomationRelease(publishDate: now)
        let searcher = FakeReleaseSearcher(
            releases: [release], outcomes: [IndexerSearchOutcome(
                indexerID: release.indexerID, indexerName: release.indexerName,
                status: .failure(.timeout))])
        let grabber = FakeReleaseGrabber()
        let automation = ReleaseAutomation(
            search: searcher, targets: { [target] }, grabber: grabber,
            grabs: GRDBGrabRepository(database), blocklist: GRDBBlocklistRepository(database),
            history: GRDBHistoryRepository(database), health: GRDBHealthIssueRepository(database),
            sourceResolver: { _ in .magnet("magnet:?xt=urn:btih:\(release.infoHash!)") })

        let held = await automation.syncRSS(now: now)
        #expect(held.indexerFailures == 1)
        #expect(held.grabbed == 0)
        #expect(held.delayed == 1)
        #expect(await grabber.requests.isEmpty)
        let heldRows = try await GRDBGrabRepository(database).grabs(titleId: title.id)
        #expect(heldRows.count == 1)
        #expect(heldRows[0].outcome == .rejected)
        #expect(heldRows[0].reason["rejections"] != nil)

        let released = await automation.syncRSS(now: now.addingTimeInterval(61 * 60))
        #expect(released.indexerFailures == 1)
        #expect(released.grabbed == 1)
        #expect(released.delayed == 0)
        #expect(await grabber.requests.count == 1)
        #expect(await searcher.queries.count == 2)
        #expect(await searcher.queries.allSatisfy { $0 == .generic() })
        let rows = try await GRDBGrabRepository(database).grabs(titleId: title.id)
        #expect(rows.map(\.outcome) == [.grabbed, .rejected])
        await automation.stop()
    }

    @Test func searchNowBypassesDelayAndIdleRSSDoesNotQueryIndexers() async throws {
        let database = try AppDatabase.inMemory()
        let title = Title(kind: .movie, title: "Search Now Movie")
        try await GRDBLibraryRepository(database).add(title, seasons: [])
        let target = AutomationTarget(
            wanted: WantedTarget(title: title, episode: nil, item: .movie(title.title, year: nil, runtimeMinutes: nil), currentFile: nil, reason: .missing),
            profile: .balanced,
            delayProfile: DelayProfileConfig(name: "Hold", delayMinutes: 60, bypassIfHighestQuality: false),
            savePath: FileManager.default.temporaryDirectory.appending(path: "marquee-search-now-tests"))
        let release = IndexerRelease(
            indexerID: UUID(), title: "Search.Now.Movie.1080p.WEB-DL-GRP", guid: "search-now",
            magnetURL: URL(string: "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))"),
            infoHash: String(repeating: "b", count: 40), seeders: 10, publishDate: date(2026, 10, 9))
        let searcher = FakeReleaseSearcher(releases: [release])
        let grabber = FakeReleaseGrabber(state: .error)
        let refresher = FakeAutomationRefresher()
        let automation = ReleaseAutomation(
            search: searcher, targets: { [] }, grabber: grabber,
            grabs: GRDBGrabRepository(database), blocklist: GRDBBlocklistRepository(database),
            history: GRDBHistoryRepository(database), health: GRDBHealthIssueRepository(database),
            refreshIndexers: { await refresher.refresh() },
            sourceResolver: { _ in .magnet("magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))") })

        let idle = await automation.syncRSS(now: date(2026, 10, 9))
        #expect(idle.searched == 0)
        #expect(await searcher.queries.isEmpty)
        #expect(await refresher.count == 0)

        let searched = await automation.searchNow(target: target, now: date(2026, 10, 9))
        #expect(searched.grabbed == 0)
        #expect(await searcher.queries == [.movie(title: title.title, year: nil, imdbID: nil, tmdbID: nil)])
        let grabs = try await GRDBGrabRepository(database).grabs(titleId: title.id)
        #expect(grabs.count == 1)
        #expect(grabs[0].outcome == .failed)
        await automation.stop()
    }
}

private func makeAutomationRelease(publishDate: Date) -> IndexerRelease {
    let hash = String(repeating: "a", count: 40)
    return IndexerRelease(
        indexerID: UUID(), indexerName: "Fake", title: "Marquee.Test.Pattern.S01E01.1080p.WEB-DL.H264-GRP",
        guid: "episode-1", magnetURL: URL(string: "magnet:?xt=urn:btih:\(hash)"), infoHash: hash,
        seeders: 12, publishDate: publishDate)
}

private actor FakeReleaseSearcher: ReleaseSearching {
    private let releases: [IndexerRelease]
    private let outcomes: [IndexerSearchOutcome]
    private let count: Int
    private(set) var queries: [TorznabQuery] = []
    init(releases: [IndexerRelease], outcomes: [IndexerSearchOutcome] = [], count: Int = 1) {
        self.releases = releases
        self.outcomes = outcomes
        self.count = count
    }
    func search(_ query: TorznabQuery) async -> CoordinatedSearchResult {
        queries.append(query)
        return CoordinatedSearchResult(releases: releases, outcomes: outcomes)
    }
    func enabledIndexerCount() async -> Int { count }
}

private actor FakeReleaseGrabber: ReleaseGrabber {
    private let state: MarqueeCore.TorrentState
    private(set) var requests: [DownloadRequest] = []
    init(state: MarqueeCore.TorrentState = .queued) { self.state = state }
    func add(_ request: DownloadRequest) async throws -> Torrent {
        requests.append(request)
        return Torrent(
            infoHash: request.release.infoHash ?? "unknown", name: request.release.title,
            state: state, savePath: request.savePath.path, titleId: request.titleId)
    }
}

private actor FakeAutomationRefresher {
    private(set) var count = 0
    func refresh() { count += 1 }
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
}
