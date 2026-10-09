import SwiftUI
import MarqueeUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("appearance") private var appearance = AppearanceChoice.system
    @State private var showWelcome = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView(
                selection: $model.selection, activeCount: model.activeDownloads,
                onSelect: { model.go(to: $0) }
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
            .id(model.selection)
        }
        .overlay { CommandPalette() }
        .overlay(alignment: .bottom) { ToastView(toast: model.toast) }
        .sheet(isPresented: $model.isAddSheetShown) { AddTitleSheet() }
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
        case .movies: LibraryScreen(kind: .movie)
        case .tv: LibraryScreen(kind: .series)
        case .calendar: CalendarScreen()
        case .activity: ActivityScreen()
        case .search: SearchScreen()
        }
    }
}

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
    /// Row activation. Rows are explicit buttons with an explicit highlight: the outline's own
    /// tap-to-select does not fire on this OS version, and `.badge()` breaks row highlighting,
    /// so both are driven here instead of by `List(selection:)`.
    var onSelect: (SidebarItem) -> Void = { _ in }

    var body: some View {
        List {
            row(.home)
            row(.discover)
            Section("Library") {
                row(.movies)
                row(.tv)
            }
            Section {
                row(.calendar)
                row(.activity)
                row(.search)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .softScrollEdge()
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .accessibilityLabel(Text("Sidebar"))
    }

    private func row(_ item: SidebarItem) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 6) {
                Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
                if item == .activity, activeCount > 0 {
                    Spacer(minLength: 4)
                    Text("\(activeCount)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(
                            selection == item ? Color.white.opacity(0.28) : Color.primary.opacity(0.12)))
                        .foregroundStyle(selection == item ? .white : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == item ? .white : .primary)
        .listRowBackground(
            Group {
                if selection == item {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                        .padding(.vertical, 2)
                } else {
                    Color.clear
                }
            }
        )
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
