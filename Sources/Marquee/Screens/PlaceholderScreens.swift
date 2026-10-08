import SwiftUI
import MarqueeUI

struct DiscoverScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(
            title: "Discover is on its way",
            message: "Trending, new releases and what's coming soon will live here. Add a title and press Play. That's all it takes.",
            systemImage: "sparkles",
            tips: ["Try ⌘K to find anything in your library right now."],
            actionTitle: "Search Your Library"
        ) { model.go(to: .search) }
        .navigationTitle(Text("Discover"))
    }
}

struct CalendarScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(
            title: "Nothing scheduled yet",
            message: "New episodes and releases for the shows and movies you follow will appear here, with an \"air tonight\" view.",
            systemImage: "calendar",
            tips: ["Monitor a series from its page and its episodes land on this calendar."],
            actionTitle: "Browse TV Shows"
        ) { model.go(to: .tv) }
        .navigationTitle(Text("Calendar"))
    }
}

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("library.posterWidth") private var posterWidth = Tokens.PosterSize.standard
    @State private var query = ""
    @State private var results: [PosterItem] = []
    @State private var index: FuzzyIndex<PosterItem>?
    @State private var selection: PosterItem.ID?
    @State private var builtRevision = -1

    private struct SearchKey: Equatable { var query: String; var revision: Int }

    var body: some View {
        Group {
            if query.isEmpty {
                EmptyStateView(
                    title: "Search your library",
                    message: "Find any movie or show instantly. Typos are fine.",
                    systemImage: "magnifyingglass",
                    tips: ["Try “harbor”, “sci-fi” or just a few letters.", "Press ⌘K from anywhere to jump to a title or action."]
                )
            } else if results.isEmpty {
                EmptyStateView(
                    title: "No results for “\(query)”",
                    message: "Check the spelling, or search the wider catalogue once Discover is available.",
                    systemImage: "magnifyingglass"
                )
            } else {
                PosterGrid(
                    items: results, posterWidth: $posterWidth, selection: $selection,
                    actions: model.actions(for:), onOpen: { model.open($0.id) }, onPlay: { model.play($0) }
                )
            }
        }
        .navigationTitle(Text("Search"))
        .searchable(text: $query, placement: .toolbar, prompt: Text("Movies, shows, genres"))
        .followsLiveProgress()
        .task(id: SearchKey(query: query, revision: model.titlesRevision)) {
            if builtRevision != model.titlesRevision || index == nil {
                index = FuzzyIndex(model.titles) { $0.title + " " + $0.genres.joined(separator: " ") }
                builtRevision = model.titlesRevision
            }
            results = query.isEmpty ? [] : (index?.search(query, limit: 200) ?? [])
            selection = results.first?.id
        }
    }
}
