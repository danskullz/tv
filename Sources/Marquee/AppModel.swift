import SwiftUI
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
    let lifecycle = AppLifecycle()
    let tracker: DownloadTracker

    var selection: SidebarItem? = .home
    var path: [PosterItem.ID] = []
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isPaletteShown = false
    var toast: Toast?
    private(set) var titles: [PosterItem] = [] { didSet { titlesRevision += 1 } }
    private(set) var titlesRevision = 0
    private(set) var activeDownloads = 0

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var removed: [(index: Int, item: PosterItem)] = []

    init(source: any LibraryDataSource = MockLibrary()) {
        self.source = source
        self.tracker = DownloadTracker(source: source, lifecycle: lifecycle)
        if let raw = UserDefaults.standard.string(forKey: "initialScreen"), let item = SidebarItem(rawValue: raw) {
            selection = item
        }
    }

    func load() async {
        lifecycle.start()
        titles = (try? await source.library()) ?? []
        if let activity = try? await source.activity() {
            activeDownloads = activity.filter(\.isActive).count
        }
        if let id = UserDefaults.standard.string(forKey: "initialDetail"), titles.contains(where: { $0.id == id }) {
            path = [id]
        }
    }

    func title(_ id: PosterItem.ID) -> PosterItem? { titles.first { $0.id == id } }

    // MARK: Navigation

    func go(to item: SidebarItem) {
        withMotion { selection = item }
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
        show(Toast(title: watched ? String(localized: "Marked as watched") : String(localized: "Marked as unwatched"),
                   systemImage: watched ? "checkmark.circle.fill" : "eye.slash"))
    }

    func remove(_ id: PosterItem.ID) {
        guard let i = titles.firstIndex(where: { $0.id == id }) else { return }
        let item = titles.remove(at: i)
        removed.append((i, item))
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
