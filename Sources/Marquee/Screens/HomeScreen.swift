import SwiftUI
import MarqueeCore
import MarqueeUI

struct HomeScreen: View {
    @Environment(AppModel.self) private var model

    /// True only before the first successful load, so a background refresh never flashes skeletons
    /// over content that is already on screen.
    private var isFirstLoad: Bool { !model.didLoadHomeShelves }

    private var shelves: [ShelfModel] { model.homeShelves }
    private var featured: PosterItem? { shelves.first { $0.id == "continue" }?.items.first }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l + 4) {
                if featured == nil { Color.clear.frame(height: 40) }
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
                if isFirstLoad {
                    ShelfSkeleton(style: .wide, count: 5)
                    ShelfSkeleton(count: 8)
                } else if shelves.allSatisfy(\.items.isEmpty) {
                    EmptyStateView(
                        title: "Your library is empty",
                        message: "Add a movie or show, then press Play. Marquee finds a release and streams it while it downloads.",
                        systemImage: "play.rectangle.on.rectangle",
                        tips: ["Press ⌘N to search for a title.", "Add a TMDB key and an indexer in Settings first (⌘,)."],
                        actionTitle: "Add to Library"
                    ) { model.isAddSheetShown = true }
                    .frame(height: 420)
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
        .heroScrollEdge()
        .navigationTitle(Text("Home"))
        .toolbar(removing: .title)
        .followsLiveProgress()
        .task(id: model.titlesRevision) {
            let start = ContinuousClock.now
            await model.refreshHomeShelves()
            PerfLog.record("HomeScreen.load", seconds: PerfLog.seconds(since: start))
        }
    }
}
