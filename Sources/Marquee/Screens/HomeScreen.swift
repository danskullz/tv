import SwiftUI
import MarqueeUI

struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var shelves: [ShelfModel] = []
    @State private var featured: PosterItem?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l + 4) {
                if let featured {
                    HeroHeader(
                        title: featured.title,
                        eyebrow: String(localized: "Continue Watching"),
                        metadata: [featured.subtitle],
                        quality: featured.quality,
                        overview: nil,
                        backdrop: featured.backdrop,
                        height: 380
                    ) {
                        PlayButton("Resume", context: featured.title) { model.play(featured) }
                        Button { model.open(featured.id) } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                        .buttonStyle(.marqueeSecondary)
                    }
                }
                if isLoading {
                    ShelfSkeleton(style: .wide, count: 5)
                    ShelfSkeleton(count: 8)
                } else {
                    ForEach(shelves) { shelf in
                        if !shelf.items.isEmpty {
                            ShelfRow(
                                shelf,
                                actions: model.actions(for:),
                                onOpen: { model.open($0.id) },
                                onSeeAll: shelf.showsSeeAll ? { model.go(to: .movies) } : nil
                            )
                        }
                    }
                }
            }
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(Text("Home"))
        .toolbar(removing: .title)
        .followsLiveProgress()
        .task {
            let loaded = (try? await model.source.homeShelves()) ?? []
            shelves = loaded
            featured = loaded.first { $0.id == "continue" }?.items.first
            isLoading = false
        }
    }
}
