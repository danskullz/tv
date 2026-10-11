import SwiftUI
import MarqueeUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("appearance") private var appearance = AppearanceChoice.system
    @State private var showWelcome = false

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = model.updater
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView(
                selection: Binding(get: { model.selection }, set: {
                    guard let next = $0 else { return }
                    model.go(to: next)
                }),
                activeCount: model.activeDownloads
            )
        } detail: {
            NavigationStack(path: $model.path) {
                screen
                    .navigationDestination(for: PosterItem.ID.self) { id in
                        TitleDetailScreen(id: id)
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.isAddSheetShown = true } label: {
                                Label("Add to Library", systemImage: "plus")
                            }
                            .help(Text("Add a movie or show (⌘N)"))
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { withMotion { model.isPaletteShown = true } } label: {
                                Label("Jump to…", systemImage: "command")
                            }
                            .help(Text("Search titles and actions (⌘K)"))
                        }
                    }
            }
            // No `.id(model.selection)` here on purpose. It used to force the whole stack and the
            // screen to be torn down and rebuilt on every sidebar click. The detail stack is reset
            // by `AppModel.go(to:)` clearing `path`, and the screen aggregates live on `AppModel`
            // rather than in each screen's `@State`, so a switch no longer re-fetches anything.
        }
        .overlay { CommandPalette() }
        .overlay(alignment: .bottom) { ToastView(toast: model.toast) }
        .sheet(isPresented: $model.isAddSheetShown) { AddTitleSheet() }
        .sheet(isPresented: $updater.isSheetShown) { UpdateSheet() }
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeSheet { showWelcome = false }
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await model.load()
            if !hasSeenWelcome { showWelcome = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWelcome)) { _ in showWelcome = true }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.selection ?? .home {
        case .home: HomeScreen()
        case .discover: DiscoverScreen()
        // Movies and TV are the same view type, so they need distinct identities or the second
        // one would inherit the first one's filters, sort and scroll position. Every other case is
        // its own type and is kept alive across tab switches.
        case .movies: LibraryScreen(kind: .movie).id(LibraryTab.movie)
        case .tv: LibraryScreen(kind: .series).id(LibraryTab.series)
        case .calendar: CalendarScreen()
        case .activity: ActivityScreen()
        case .search: SearchScreen()
        }
    }
}

/// Identity for the two screens that share `LibraryScreen`.
private enum LibraryTab: Hashable { case movie, series }

extension Notification.Name {
    static let showWelcome = Notification.Name("marquee.showWelcome")
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let activeCount: Int

    var body: some View {
        List(selection: $selection) {
            row(.home)
            row(.discover)
            Section("Library") {
                row(.movies)
                row(.tv)
            }
            Section {
                row(.calendar)
                activityRow
                row(.search)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .softScrollEdge()
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .accessibilityLabel(Text("Sidebar"))
    }

    /// Activity carries the active-download count as row content rather than via `.badge()`.
    /// `.badge()` on a row inside a selection `List` collapses that row's hit area on this OS:
    /// Calendar's row went to zero height and swallowed Activity's, so clicking Activity opened
    /// Calendar instead. Never put `.badge()` on a selectable sidebar row here.
    private var activityRow: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Label { Text(SidebarItem.activity.title) } icon: { Image(systemName: SidebarItem.activity.systemImage) }
            Spacer(minLength: 4)
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(activeCount) active downloads"))
            }
        }
        .tag(SidebarItem.activity)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
            .tag(item)
    }
}

extension View {
    /// Screens that open with a full-bleed hero let the artwork run under the toolbar with no edge effect.
    @ViewBuilder
    func heroScrollEdge() -> some View {
        if #available(macOS 26, *) {
            toolbarBackground(.hidden, for: .windowToolbar).scrollEdgeEffectHidden(true, for: .top)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    /// Keeps the sidebar one continuous glass surface instead of a separate title-bar band.
    @ViewBuilder
    func softScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .leading)
        } else {
            self
        }
    }
}

/// Bottom-center HUD for transient confirmations.
struct ToastView: View {
    let toast: Toast?

    var body: some View {
        ZStack {
            if let toast {
                HStack(spacing: 12) {
                    Image(systemName: toast.systemImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: toast.title).font(.headline)
                        if let detail = toast.detail {
                            Text(verbatim: detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let actionTitle = toast.actionTitle, let action = toast.action {
                        Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .marqueeGlass(in: Capsule())
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .allowsHitTesting(toast != nil)
    }
}
