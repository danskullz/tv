import AppKit
import MarqueeCore
import MarqueeUI
import SwiftUI

struct DiscoverScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var snapshot: DiscoverSnapshot?
    @State private var filtered: [PosterItem] = []
    @State private var selection: Int?
    @State private var isLoading = true
    @State private var isFiltering = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    private var services: AppServices? { model.services }

    var body: some View {
        Group {
            if services?.hasMetadataKey != true {
                EmptyStateView(
                    title: "Discover the catalogue", message: "Connect a free TMDB key to browse trending films, series and legal streaming availability.",
                    systemImage: "sparkles", tips: ["Your library stays private and local."], actionTitle: "Set Up TMDB"
                ) {
                    UserDefaults.standard.set("metadata", forKey: "settings.tab")
                    openSettings()
                }
            } else if isLoading {
                ScrollView { LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                    SkeletonView(cornerRadius: 0).frame(height: 430)
                    ShelfSkeleton(count: 7)
                    ShelfSkeleton(count: 7)
                }.padding(.bottom, Tokens.Spacing.xl) }
            } else if let error, snapshot == nil {
                VStack(spacing: 16) {
                    ErrorBanner(title: "Discover couldn't load", message: "Check your connection, then try again.", details: error, fixTitle: "Retry") { Task { await load() } }
                        .padding(.horizontal, Tokens.Spacing.gutter)
                    EmptyStateView(title: "Your library is still here", message: "TMDB is only needed for the catalogue. Your local titles remain available.", systemImage: "wifi.exclamationmark")
                }
            } else if let snapshot {
                discover(snapshot)
            } else {
                EmptyStateView(title: "Discover is ready when you are", message: "Load catalogue data to see what's trending.",
                               systemImage: "sparkles", actionTitle: "Retry") { Task { await load() } }
            }
        }
        .navigationTitle(Text("Discover"))
        .heroScrollEdge()
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .onAppear { startLoad() }
        // `onAppear` can run before `AppServices.prepare()` has resolved the TMDB key (it is read
        // from the secret store at start-up) and it does not fire again, which used to leave a
        // deep-linked Discover tab stuck on the empty state. React to the key arriving instead.
        .onChange(of: model.services?.hasMetadataKey) { _, hasKey in
            if hasKey == true { startLoad() }
        }
        .onDisappear { loadTask?.cancel(); loadTask = nil }
    }

    private func discover(_ data: DiscoverSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                if let featured = data.featured { hero(featured) }
                if let error {
                    ErrorBanner(title: "Some shelves are unavailable", message: "Showing the catalogue sections that loaded.", details: error, onDismiss: { self.error = nil })
                        .padding(.horizontal, Tokens.Spacing.gutter)
                }
                if selection != nil {
                    HStack {
                        Label("Filtered picks", systemImage: "line.3.horizontal.decrease")
                            .font(Tokens.Typography.sectionTitle)
                        Spacer()
                        if isFiltering { ProgressView().controlSize(.small) }
                        Button("Clear") { selection = nil; filtered = [] }
                    }.padding(.horizontal, Tokens.Spacing.gutter)
                    if !filtered.isEmpty {
                PosterGrid(items: filtered, posterWidth: .constant(Tokens.PosterSize.standard), selection: .constant(nil),
                                   actions: actions, onOpen: { model.open($0.id) }, onPlay: { model.open($0.id) })
                    } else if !isFiltering {
                        Text("No titles match this filter yet.").foregroundStyle(.secondary).padding(.horizontal, Tokens.Spacing.gutter)
                    }
                    filterChips(data)
                } else {
                    filterChips(data)
                    shelf("Trending this week", items: data.trending)
                    shelf("Popular Movies", items: data.popularMovies)
                    shelf("Popular Series", items: data.popularSeries)
                    if !data.newReleases.isEmpty { shelf("New Releases", items: data.newReleases) }
                    if !data.upcoming.isEmpty { shelf("Coming Soon", items: data.upcoming) }
                    if !data.recommendations.isEmpty { shelf("Because You Watched", items: data.recommendations) }
                    let recent = Array(model.titles.sorted { $0.addedAt > $1.addedAt }.prefix(16))
                    if !recent.isEmpty { shelf("Recently Added", items: recent) }
                }
            }
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func hero(_ item: PosterItem) -> some View {
        HeroHeader(title: item.title, eyebrow: "Trending this week", metadata: item.year > 0 ? [String(item.year)] : [],
                   overview: "Explore what's popular now, then add a title to your monitored library.", backdrop: item.backdrop, height: 470) {
            Button { model.open(item.id) } label: { Label("Explore", systemImage: "info.circle") }.buttonStyle(.marqueePlay)
            Button { want(item) } label: { Label("Want It", systemImage: "plus") }.buttonStyle(.marqueeSecondary)
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, items: [PosterItem]) -> some View {
        if !items.isEmpty {
            ShelfRow(ShelfModel(id: title, title: title, items: items), actions: actions,
                     onOpen: { model.open($0.id) })
        }
    }

    private func filterChips(_ data: DiscoverSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if !data.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Genres").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(data.genres) { genre in
                            Button(genre.name) { apply(genre: genre.id, provider: nil) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(.horizontal, Tokens.Spacing.gutter)
                }
            }
            if !data.providers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Streaming on").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(data.providers.prefix(12)) { provider in
                            Button(provider.name) { apply(genre: nil, provider: provider.id) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(.horizontal, Tokens.Spacing.gutter)
                }
            }
        }
    }

    private func actions(_ item: PosterItem) -> [PosterAction] {
        [PosterAction(id: "want", title: String(localized: "Want It"), systemImage: "plus") { want(item) },
         PosterAction(id: "details", title: String(localized: "Show Details"), systemImage: "info.circle") { model.open(item.id) }]
    }

    private func want(_ item: PosterItem) {
        guard let services else { return }
        Task {
            do {
                let title = try await services.want(item)
                model.show(Toast(title: String(localized: "Added \(title.title)"), detail: "Monitoring is on.", systemImage: "checkmark.circle.fill"))
            } catch LibraryError.alreadyInLibrary(let existing) {
                model.go(to: item.kind == .movie ? .movies : .tv)
                model.open(existing.uuidString)
            } catch {
                model.show(Toast(title: "Couldn't add title", detail: error.localizedDescription, systemImage: "exclamationmark.triangle"))
            }
        }
    }

    private func apply(genre: Int?, provider: Int?) {
        selection = genre ?? provider
        isFiltering = true
        Task {
            defer { isFiltering = false }
            do { filtered = try await services?.discoverFiltered(genre: genre, provider: provider) ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        guard let services, services.hasMetadataKey else { isLoading = false; return }
        // Only flash skeletons on a genuinely cold open; otherwise keep the shelves already shown
        // and swap the data underneath them.
        if snapshot == nil { isLoading = true }
        error = nil
        defer { isLoading = false }
        let start = ContinuousClock.now
        do { snapshot = try await services.discoverSnapshot() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        PerfLog.record("DiscoverScreen.load", seconds: PerfLog.seconds(since: start))
    }

    private func startLoad() {
        guard loadTask == nil else { return }
        loadTask = Task { await load(); loadTask = nil }
    }
}
