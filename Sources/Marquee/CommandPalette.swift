import SwiftUI
import MarqueeUI

/// ⌘K overlay: fuzzy filter over titles and actions, fully keyboard driven
/// (type to filter, ↑/↓ to move, Return to run, Esc to close).
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var highlighted = 0
    @State private var index: FuzzyIndex<Entry>?
    @State private var results: [Entry] = []
    @FocusState private var fieldFocused: Bool

    enum Target: Sendable {
        case title(PosterItem.ID)
        case go(SidebarItem)
        case toggleSidebar
        case addTitle
        case settings
        case welcome
        case gallery
    }

    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let tag: String
        let target: Target
        let keywords: String
    }

    var body: some View {
        ZStack {
            if model.isPaletteShown {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                panel
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 90)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .motion(Tokens.Motion.snappy, value: model.isPaletteShown)
        .onChange(of: model.isPaletteShown) { _, shown in
            if shown {
                query = ""
                highlighted = 0
                rebuildIndex()
                refresh()
                fieldFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            highlighted = 0
            refresh()
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search titles and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runHighlighted() }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .accessibilityLabel(Text("Command palette"))
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            Divider()

            if results.isEmpty {
                Text("No matches for “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, entry in
                                row(entry, isHighlighted: i == highlighted)
                                    .id(entry.id)
                                    .onTapGesture { run(entry) }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 9 * 46)
                    .onChange(of: highlighted) { _, new in
                        if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "Move")
                hint("↩", "Open")
                hint("esc", "Close")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 30)
        }
        .frame(width: 620)
        .marqueeGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: key)
                .font(.caption.weight(.semibold).monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }

    private func row(_ entry: Entry, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.systemImage)
                .frame(width: 26, height: 26)
                .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.title).font(.body).lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(verbatim: entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(verbatim: entry.tag)
                .font(.caption)
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(isHighlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: entry.title))
        .accessibilityValue(Text(verbatim: entry.tag))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Data

    private func rebuildIndex() {
        var entries: [Entry] = []
        let actions: [(String, String, String, Target, String)] = [
            (String(localized: "Go to Home"), "house", "go-home", .go(.home), "home"),
            (String(localized: "Go to Discover"), "sparkles", "go-discover", .go(.discover), "discover trending"),
            (String(localized: "Go to Movies"), "film", "go-movies", .go(.movies), "movies library films"),
            (String(localized: "Go to TV Shows"), "tv", "go-tv", .go(.tv), "tv shows series library"),
            (String(localized: "Go to Calendar"), "calendar", "go-calendar", .go(.calendar), "calendar schedule upcoming"),
            (String(localized: "Go to Activity"), "arrow.down.circle", "go-activity", .go(.activity), "activity downloads queue imports"),
            (String(localized: "Go to Search"), "magnifyingglass", "go-search", .go(.search), "search find"),
            (String(localized: "Add to Library…"), "plus", "add-title", .addTitle, "add new movie show search tmdb"),
            (String(localized: "Toggle Sidebar"), "sidebar.left", "sidebar", .toggleSidebar, "sidebar hide show"),
            (String(localized: "Open Settings"), "gearshape", "settings", .settings, "settings preferences options"),
            (String(localized: "Show Welcome Guide"), "hand.wave", "welcome", .welcome, "welcome setup first run onboarding"),
            (String(localized: "Open Component Gallery"), "square.grid.2x2", "gallery", .gallery, "design components gallery"),
        ]
        for (title, symbol, id, target, keywords) in actions {
            let isNav: Bool = { if case .go = target { return true } else { return false } }()
            entries.append(Entry(id: id, title: title, subtitle: isNav ? String(localized: "Jump to a section") : "", systemImage: symbol,
                                 tag: String(localized: "Action"), target: target, keywords: keywords))
        }
        for t in model.titles {
            entries.append(Entry(
                id: t.id, title: t.title, subtitle: t.subtitle,
                systemImage: t.kind == .movie ? "film" : "tv",
                tag: t.kind == .movie ? String(localized: "Movie") : String(localized: "Series"),
                target: .title(t.id), keywords: t.genres.joined(separator: " ")
            ))
        }
        index = FuzzyIndex(entries) { $0.title + " " + $0.keywords }
    }

    private func refresh() {
        guard let index else { return }
        results = index.search(query, limit: 40)
    }

    // MARK: Actions

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        highlighted = max(0, min(results.count - 1, highlighted + delta))
        return .handled
    }

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ entry: Entry) {
        dismiss()
        switch entry.target {
        case .title(let id):
            if model.selection == .home || model.selection == nil { model.path = [id] }
            else { model.path.append(id) }
        case .go(let item): model.go(to: item)
        case .toggleSidebar: model.toggleSidebar()
        case .addTitle: model.isAddSheetShown = true
        case .settings: openSettings()
        case .welcome: NotificationCenter.default.post(name: .showWelcome, object: nil)
        case .gallery: openWindow(id: "gallery")
        }
    }

    private func dismiss() {
        withMotion { model.isPaletteShown = false }
    }
}
