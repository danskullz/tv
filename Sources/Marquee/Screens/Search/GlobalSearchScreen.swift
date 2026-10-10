import MarqueeCore
import MarqueeUI
import SwiftUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("library.posterWidth") private var posterWidth = Tokens.PosterSize.standard
    @AppStorage("search.recent") private var recentStorage = "[]"
    @State private var query = ""
    @State private var localResults: [PosterItem] = []
    @State private var catalogue: [BrowseHit] = []
    @State private var index: FuzzyIndex<PosterItem>?
    @State private var builtRevision = -1
    @State private var isSearching = false
    @State private var error: String?
    @State private var person: PersonSummary?
    @State private var selected = 0
    @FocusState private var searchFocused: Bool

    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(recentStorage.utf8))) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Movies, shows, people, and your library", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onSubmit(activateFirst)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .accessibilityLabel(Text("Search Marquee and TMDB"))
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Tokens.Spacing.gutter)
            .frame(height: 54)
            Divider()
            content
        }
        .navigationTitle(Text("Search"))
        .task { searchFocused = true }
        .task(id: SearchKey(query: query, revision: model.titlesRevision)) { await search() }
        .sheet(item: $person) { person in
            PersonFilmographySheet(person: person) { id in model.open(id) }
                .frame(minWidth: 680, minHeight: 560)
        }
        .onSubmit(of: .search, activateFirst)
    }

    private struct SearchKey: Equatable { let query: String; let revision: Int }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A ScrollView proposes an unbounded height, so `EmptyStateView`'s
            // `.frame(maxHeight: .infinity)` resolves to its natural height instead of claiming all
            // the space and shoving "Recent Searches" off the bottom of the window. Fixing it here
            // rather than in the shared component leaves the screens that rely on that expansion to
            // centre their empty state untouched.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    EmptyStateView(title: "Find your next favorite", message: "Search your library instantly, then look across movies, series and people in TMDB.", systemImage: "sparkle.magnifyingglass")
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent Searches").font(Tokens.Typography.sectionTitle)
                            FlowLayout(spacing: 8) {
                                ForEach(recent, id: \.self) { term in
                                    Button(term) { query = term }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }.padding(.horizontal, Tokens.Spacing.gutter)
                    }
                }
                .padding(.bottom, Tokens.Spacing.xl)
            }
        } else if let error, catalogue.isEmpty, localResults.isEmpty, !isSearching {
            VStack(spacing: 16) {
                if model.services?.hasMetadataKey != true {
                    EmptyStateView(title: "Search your library", message: "Add a TMDB key to search the wider catalogue.", systemImage: "key", actionTitle: "Open Settings") {
                        UserDefaults.standard.set("metadata", forKey: "settings.tab")
                        openSettings()
                    }
                }
                ErrorBanner(title: "Search couldn't finish", message: "Check your connection and try again.", details: error, fixTitle: "Retry") {
                    Task { await search() }
                }
            }.padding(.vertical, 24)
        } else if model.services?.hasMetadataKey != true && localResults.isEmpty {
            EmptyStateView(title: "Search the catalogue", message: "Add a TMDB key to find movies, series and people beyond your library.",
                           systemImage: "key", actionTitle: "Open Settings") {
                UserDefaults.standard.set("metadata", forKey: "settings.tab")
                openSettings()
            }
        } else if localResults.isEmpty && catalogue.isEmpty && !isSearching {
            EmptyStateView(title: "No matches for “\(query)”", message: "Try another spelling or search with fewer words.", systemImage: "magnifyingglass")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                    if !localResults.isEmpty {
                        PosterGrid(items: localResults, posterWidth: $posterWidth, selection: .constant(nil),
                                   actions: model.actions(for:), onOpen: { model.open($0.id) }, onPlay: { model.play($0) })
                            .overlay(alignment: .topLeading) { Text("YOUR LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, Tokens.Spacing.gutter) }
                    }
                    if !localResults.isEmpty, model.services?.hasMetadataKey != true {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill").foregroundStyle(.secondary)
                            Text("Connect TMDB to search the wider catalogue.").font(.callout).foregroundStyle(.secondary)
                            Button("Settings") {
                                UserDefaults.standard.set("metadata", forKey: "settings.tab")
                                openSettings()
                            }
                        }.padding(.horizontal, Tokens.Spacing.gutter)
                    }
                    let titles = catalogue.compactMap { hit -> PosterItem? in
                        if case .title(let item) = hit.payload { return item }
                        return nil
                    }
                    if !titles.isEmpty {
                        ShelfRow(ShelfModel(id: "catalogue-search", title: "MOVIES & SERIES", items: titles),
                                 onOpen: { open($0.id) })
                    }
                    let people = catalogue.compactMap { hit -> PersonSummary? in
                        if case .person(let person) = hit.payload { return person }
                        return nil
                    }
                    if !people.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PEOPLE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, Tokens.Spacing.gutter)
                            LazyVStack(spacing: 2) {
                                ForEach(people) { person in
                                    Button { self.person = person } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tertiary).frame(width: 40)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(verbatim: person.name).font(.headline)
                                                if let department = person.knownForDepartment { Text(verbatim: department).font(.caption).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        }.padding(10).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, Tokens.Spacing.gutter)
                        }
                    }
                }.padding(.vertical, Tokens.Spacing.l)
            }
        }
    }

    private func open(_ id: String) {
        remember(query)
        model.open(id)
    }

    private func activateFirst() {
        guard !query.isEmpty else { return }
        remember(query)
        let remote = catalogue.compactMap { hit -> PosterItem? in
            if case .title(let item) = hit.payload { return item }; return nil
        }
        let merged = BrowseDataShaping.mergeSearch(library: localResults, catalogue: remote, query: query, id: \.id, title: \.title)
        if let first = merged.first {
            if UUID(uuidString: first.id) != nil { model.play(first) }
            else { open(first.id) }
        } else if let person = catalogue.compactMap({ hit -> PersonSummary? in
            if case .person(let person) = hit.payload { return person }; return nil
        }).first { self.person = person }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = localResults.count + catalogue.count
        guard count > 0 else { return .handled }
        selected = max(0, min(count - 1, selected + delta))
        return .handled
    }

    private func remember(_ term: String) {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let values = ([cleaned] + recent.filter { $0.localizedCaseInsensitiveCompare(cleaned) != .orderedSame }).prefix(8)
        if let data = try? JSONEncoder().encode(Array(values)), let text = String(data: data, encoding: .utf8) { recentStorage = text }
    }

    private func search() async {
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil
        guard !query.isEmpty else { localResults = []; catalogue = []; return }
        if builtRevision != model.titlesRevision || index == nil {
            index = FuzzyIndex(model.titles) { $0.title + " " + $0.genres.joined(separator: " ") }
            builtRevision = model.titlesRevision
        }
        localResults = index?.search(query, limit: 30) ?? []
        catalogue = []
        selected = 0
        guard model.services?.hasMetadataKey == true else { catalogue = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do { catalogue = try await model.services?.searchBrowse(query) ?? [] }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
