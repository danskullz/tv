import SwiftUI
import MarqueeCore
import MarqueeUI

enum SidebarItem: String, CaseIterable, Hashable, Identifiable {
    case home, discover, movies, tv, calendar, activity, search

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .movies: "Movies"
        case .tv: "TV Shows"
        case .calendar: "Calendar"
        case .activity: "Activity"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .discover: "sparkles"
        case .movies: "film"
        case .tv: "tv"
        case .calendar: "calendar"
        case .activity: "arrow.down.circle"
        case .search: "magnifyingglass"
        }
    }

    /// ⌘1…⌘7 jump shortcuts.
    var shortcutKey: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// Transient confirmation / status HUD.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String?
    var systemImage: String
    var actionTitle: String?
    var action: (@MainActor () -> Void)?

    static func == (l: Toast, r: Toast) -> Bool { l.id == r.id && l.title == r.title && l.detail == r.detail }
}

/// App-wide UI state. Data comes only through `LibraryDataSource`, so swapping the mock for the real
/// services means changing the one initializer argument.
@MainActor
@Observable
final class AppModel {
    let source: any LibraryDataSource
    /// The real services; nil when running on mock data (`-mockData YES`).
    let services: AppServices?
    let lifecycle = AppLifecycle()
    let tracker: DownloadTracker

    var selection: SidebarItem? = .home
    var path: [PosterItem.ID] = []
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isPaletteShown = false
    var isAddSheetShown = false
    /// False until the first library fetch finishes, so empty states don't flash while loading.
    private(set) var hasLoaded = false
    var toast: Toast?
    private(set) var titles: [PosterItem] = [] { didSet { titlesRevision += 1 } }
    private(set) var titlesRevision = 0
    private(set) var activeDownloads = 0

    /// Screen aggregates live here, not in each screen's `@State`. A sidebar click swaps the view
    /// out of the tree, which discards `@State`; anything a screen fetches into `@State` has to be
    /// fetched again on the way back. Holding them on the model means coming back to a tab is a
    /// synchronous read instead of a round trip behind a skeleton.
    private(set) var homeShelves: [ShelfModel] = []
    private(set) var didLoadHomeShelves = false
    private(set) var activityItems: [ActivityItem] = []
    private(set) var didLoadActivity = false

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var removed: [(index: Int, item: PosterItem)] = []
    /// In-flight refreshes, so several screens asking at once share one query.
    @ObservationIgnored private var homeShelfTask: Task<[ShelfModel], Never>?
    @ObservationIgnored private var activityTask: Task<[ActivityItem], Never>?

    init(source: any LibraryDataSource = MockLibrary(), services: AppServices? = nil) {
        self.source = source
        self.services = services
        self.tracker = DownloadTracker(source: source, lifecycle: lifecycle)
        if let raw = UserDefaults.standard.string(forKey: "initialScreen"), let item = SidebarItem(rawValue: raw) {
            selection = item
        }
        services?.announce = { [weak self] title, detail, symbol in
            self?.show(Toast(title: title, detail: detail, systemImage: symbol), duration: 6)
        }
        services?.libraryDidChange = { [weak self] in
            Task { await self?.reloadLibrary() }
        }
    }

    /// Builds the model for this launch: real services by default, mock data with `-mockData YES`,
    /// the self-contained demo content with `-demoSwarm YES`.
    static func forLaunch() -> AppModel {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "mockData") { return AppModel() }
        do {
            let fixtures = defaults.bool(forKey: "tmdbFixtures")
            let fixtureDatabase = fixtures ? try AppDatabase.inMemory() : nil
            let fixtureSecrets: (any SecretStore)? = fixtures ? InMemorySecretStore() : nil
            let services = try AppServices(
                demo: defaults.bool(forKey: "demoSwarm"), tmdbFixtures: fixtures,
                database: fixtureDatabase, secrets: fixtureSecrets)
            return AppModel(source: services.libraryReader, services: services)
        } catch {
            let model = AppModel()
            model.show(Toast(
                title: String(localized: "Couldn't open your library"),
                detail: String(localized: "Showing sample data instead."), systemImage: "exclamationmark.triangle"), duration: 8)
            return model
        }
    }

    func reloadLibrary() async {
        titles = (try? await source.library()) ?? titles
        if let activity = try? await source.activity() {
            activeDownloads = activity.filter(\.isActive).count
        }
        async let shelves: Void = refreshHomeShelves()
        async let items: Void = refreshActivity()
        _ = await (shelves, items)
    }

    /// Loads the Home shelves, sharing one in-flight query between callers.
    func refreshHomeShelves() async {
        if let task = homeShelfTask {
            homeShelves = await task.value
            return
        }
        let task = Task { [source] in (try? await source.homeShelves()) ?? [] }
        homeShelfTask = task
        let value = await task.value
        homeShelfTask = nil
        guard !Task.isCancelled else { return }
        homeShelves = value
        didLoadHomeShelves = true
    }

    /// Loads Activity, sharing one in-flight query between callers.
    func refreshActivity() async {
        if let task = activityTask {
            let value = await task.value
            applyActivity(value)
            return
        }
        let task = Task { [source] in (try? await source.activity()) ?? [] }
        activityTask = task
        let value = await task.value
        activityTask = nil
        guard !Task.isCancelled else { return }
        applyActivity(value)
    }

    private func applyActivity(_ fresh: [ActivityItem]) {
        // Only churn the list when something actually changed: a download ticking its progress bar
        // must not re-render every Activity row.
        if fresh != activityItems { activityItems = fresh }
        activeDownloads = fresh.filter(\.isActive).count
        tracker.seed(fresh.map {
            ProgressUpdate(
                id: $0.id, fraction: $0.fraction, etaSeconds: $0.totalSeconds,
                bytesPerSecond: $0.bytesPerSecond)
        })
        didLoadActivity = true
    }

    func load() async {
        lifecycle.start()
        await services?.prepare()
        titles = (try? await source.library()) ?? []
        hasLoaded = true
        async let shelves: Void = refreshHomeShelves()
        async let items: Void = refreshActivity()
        _ = await (shelves, items)
        if let id = UserDefaults.standard.string(forKey: "initialDetail"), titles.contains(where: { $0.id == id }) {
            path = [id]
        }
        startTabWalkIfRequested()
    }

    /// Dev harness: `MARQUEE_TABS=2` walks the sidebar that many times after launch, so tab-switch
    /// cost can be measured from the log without a human clicking (or an automation permission).
    /// Off unless the variable is set, so it costs nothing in normal use.
    private func startTabWalkIfRequested() {
        guard let passes = PerfLog.envInt("MARQUEE_TABS"), passes > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            // Measure the interaction, not launch: zero the counters so the totals cover only the
            // walk. Launch cost is a separate problem with a separate fix.
            PerfLog.resetStalls()
            for pass in 1...passes {
                for item in SidebarItem.allCases {
                    PerfLog.mark("WALK \(pass)->\(item.rawValue)")
                    self.go(to: item)
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            MainThreadWatchdog.shared.stop()
            PerfLog.dumpStalls()
        }
    }

    func title(_ id: PosterItem.ID) -> PosterItem? { titles.first { $0.id == id } }

    // MARK: Navigation

    func go(to item: SidebarItem) {
        PerfLog.mark("tab->\(item.rawValue)")
        // Deliberately not animated. `selection` swaps which screen is in the detail stack, so an
        // animation here crossfades two complete hierarchies — a full poster grid's worth of views
        // laid out twice — for 220 ms. Sidebar tab switches are instant in AppKit and macOS apps;
        // this is what makes a switch feel instant here too.
        selection = item
        path = []
    }

    func open(_ id: PosterItem.ID) {
        path.append(id)
    }

    func toggleSidebar() {
        withMotion {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    // MARK: Actions

    func play(_ item: PosterItem) {
        if let services, let id = UUID(uuidString: item.id) {
            guard item.availability != .unaired else {
                show(Toast(title: String(localized: "Not released yet"), detail: String(localized: "Come back when \(item.title) is out."), systemImage: "calendar"))
                return
            }
            Task { await services.play(.title(id)) }
            return
        }
        playMock(item)
    }

    /// Plays one episode of a series.
    func play(_ item: PosterItem, episode: EpisodeModel) {
        guard let services, let id = UUID(uuidString: item.id) else { return playMock(item) }
        Task { await services.play(.episode(id, season: episode.season, episode: episode.number)) }
    }

    /// Plays a season as a binge. `fromStart` begins at episode 1 instead of the first unwatched one.
    func playSeason(_ item: PosterItem, season: Int, fromStart: Bool) {
        guard let services, let id = UUID(uuidString: item.id) else { return playMock(item) }
        Task { await services.play(.season(id, season: season, startingAt: fromStart ? 1 : nil)) }
    }

    private func playMock(_ item: PosterItem) {
        let detail: String
        let icon: String
        switch item.availability {
        case .local, .importing:
            detail = String(localized: "The player arrives in a later build.")
            icon = "play.circle.fill"
        case .downloading:
            detail = String(localized: "Already downloading. Buffering 12 s ahead…")
            icon = "arrow.down.circle.fill"
        case .unaired:
            detail = String(localized: "Not released yet. We'll tell you when it's available.")
            icon = "calendar"
        case .queued, .missing:
            detail = String(localized: "Finding peers… picking the best stream-friendly release.")
            icon = "antenna.radiowaves.left.and.right"
        }
        show(Toast(title: String(localized: "Starting \(item.title)"), detail: detail, systemImage: icon))
    }

    func setWatched(_ watched: Bool, for id: PosterItem.ID) {
        guard let i = titles.firstIndex(where: { $0.id == id }) else { return }
        titles[i].watch = watched ? .watched : .unwatched
        if let services, let uuid = UUID(uuidString: id) {
            Task { await services.setWatched(titleID: uuid, watched) }
        }
        show(Toast(title: watched ? String(localized: "Marked as watched") : String(localized: "Marked as unwatched"),
                   systemImage: watched ? "checkmark.circle.fill" : "eye.slash"))
    }

    func setEpisodeWatched(_ item: PosterItem, _ episode: EpisodeModel, _ watched: Bool) {
        guard let services, let titleID = UUID(uuidString: item.id) else { return }
        Task { await services.setEpisodeWatched(titleID: titleID, season: episode.season, episode: episode.number, watched) }
    }

    func remove(_ id: PosterItem.ID) {
        guard let i = titles.firstIndex(where: { $0.id == id }) else { return }
        let item = titles.remove(at: i)
        removed.append((i, item))
        if let services, let uuid = UUID(uuidString: id) {
            Task { try? await services.library.softDelete(titleId: uuid) }
        }
        show(Toast(
            title: String(localized: "Removed \(item.title)"),
            detail: String(localized: "Files stay in the Trash until you empty it."),
            systemImage: "trash", actionTitle: String(localized: "Undo"),
            action: { [weak self] in self?.undoRemove() }
        ), duration: 6)
    }

    private func undoRemove() {
        guard let last = removed.popLast() else { return }
        titles.insert(last.item, at: min(last.index, titles.count))
        if let services, let uuid = UUID(uuidString: last.item.id) {
            Task { try? await services.library.restore(titleId: uuid) }
        }
        toast = nil
    }

    func actions(for item: PosterItem) -> [PosterAction] {
        [
            PosterAction(id: "play", title: String(localized: "Play"), systemImage: "play.fill") { [weak self] in self?.play(item) },
            PosterAction(id: "details", title: String(localized: "Show Details"), systemImage: "info.circle") { [weak self] in self?.open(item.id) },
            PosterAction(
                id: "watched",
                title: item.watch == .watched ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched"),
                systemImage: item.watch == .watched ? "eye.slash" : "eye"
            ) { [weak self] in self?.setWatched(item.watch != .watched, for: item.id) },
            PosterAction(id: "remove", title: String(localized: "Remove from Library…"), systemImage: "trash", isDestructive: true) { [weak self] in
                self?.remove(item.id)
            },
        ]
    }

    func show(_ toast: Toast, duration: TimeInterval = 3.6) {
        toastTask?.cancel()
        withMotion(Tokens.Motion.bouncy) { self.toast = toast }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withMotion(Tokens.Motion.smooth) { self?.toast = nil }
        }
    }
}
