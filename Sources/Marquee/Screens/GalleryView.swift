import SwiftUI
import MarqueeUI

/// Living gallery of design-system components for design review (Window menu, ⌥⌘G).
struct GalleryView: View {
    @State private var width = 150.0
    @State private var selection: PosterItem.ID? = "a"

    private static let items: [PosterItem] = {
        func art(_ h: Double, _ s: String, _ v: Int) -> Artwork { .generated(PlaceholderArt(hue: h, symbol: s, variant: v)) }
        return [
            PosterItem(id: "a", kind: .movie, title: "Amber Skies", subtitle: "2019 · 1 h 52 m", poster: art(0.08, "sun.haze.fill", 0), quality: .p1080),
            PosterItem(id: "b", kind: .series, title: "Harbor Lights", subtitle: "S2 · E4 · 31 min left", poster: art(0.58, "sailboat.fill", 1), watch: .inProgress(0.55)),
            PosterItem(id: "c", kind: .series, title: "Northern Static", subtitle: "Downloading", poster: art(0.74, "antenna.radiowaves.left.and.right", 2), availability: .downloading, downloadFraction: 0.42),
            PosterItem(id: "d", kind: .movie, title: "Night Ferry", subtitle: "Watched", poster: art(0.33, "ferry.fill", 3), watch: .watched),
            PosterItem(id: "e", kind: .movie, title: "Foxglove", subtitle: "Queued", poster: art(0.92, "pawprint.fill", 4), availability: .queued),
        ]
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                section("Play button & actions") {
                    HStack(spacing: 12) {
                        PlayButton("Play") {}
                        PlayButton("Resume S2 · E4") {}
                        Button { } label: { Label("Monitor", systemImage: "eye") }.buttonStyle(.marqueeSecondary)
                        Button { } label: { Label("Disabled", systemImage: "nosign") }.buttonStyle(.marqueeSecondary).disabled(true)
                    }
                    .padding(Tokens.Spacing.l)
                    .background(LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: Tokens.Radius.l))
                }
                section("Badges & pills") {
                    HStack(spacing: 10) {
                        QualityBadge(.p720); QualityBadge(.p1080); QualityBadge(.uhdHDR); QualityBadge(Quality(.uhd, hdr: true, remux: true))
                        StatusPill("Queued", systemImage: "clock")
                        StatusPill("Importing", systemImage: "tray.and.arrow.down", kind: .info)
                        StatusPill("Ready", systemImage: "checkmark", kind: .success)
                        StatusPill("Needs attention", systemImage: "exclamationmark.triangle", kind: .warning)
                        StatusPill("Failed", systemImage: "xmark", kind: .danger)
                    }
                }
                section("Progress rings") {
                    HStack(spacing: 20) {
                        ProgressRing(fraction: 0.15).frame(width: 28, height: 28)
                        ProgressRing(fraction: 0.5).frame(width: 40, height: 40)
                        ProgressRing(fraction: 0.9, lineWidth: 5).frame(width: 56, height: 56)
                        ProgressRing(fraction: nil).frame(width: 40, height: 40)
                    }
                }
                section("Sliders") {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                        HStack(spacing: Tokens.Spacing.m) {
                            Text("compact").font(Tokens.Typography.cardSubtitle).frame(width: 70, alignment: .trailing)
                            MarqueeSlider(value: $width, in: Tokens.PosterSize.minimum...Tokens.PosterSize.maximum, width: 116, scale: .compact)
                                .accessibilityLabel(Text("Compact poster size"))
                        }
                        HStack(spacing: Tokens.Spacing.m) {
                            Text("regular").font(Tokens.Typography.cardSubtitle).frame(width: 70, alignment: .trailing)
                            MarqueeSlider(value: $width, in: Tokens.PosterSize.minimum...Tokens.PosterSize.maximum, width: 220, scale: .regular)
                                .accessibilityLabel(Text("Regular poster size"))
                        }
                    }
                }
                section("Poster cards (size slider, arrows, Return, Space)") {
                    MarqueeSlider(value: $width, in: Tokens.PosterSize.minimum...Tokens.PosterSize.maximum, width: 220)
                        .accessibilityLabel(Text("Poster size"))
                    HStack(alignment: .top, spacing: Tokens.Spacing.cardGap) {
                        ForEach(Self.items) { item in
                            PosterCard(item, width: width, selection: item.id == selection ? .focused : .none)
                        }
                    }
                }
                section("Skeleton") {
                    ShelfSkeleton(count: 6).padding(.horizontal, -Tokens.Spacing.gutter)
                }
                section("Error banner") {
                    ErrorBanner(
                        title: "Can't reach your indexer",
                        message: "Your indexer didn't answer, so search results may be missing.",
                        details: "HTTP 503 from https://indexer.example/api\nRetry in 30 s (attempt 3 of 5)",
                        fixTitle: "Test Connection", onFix: {}, onDismiss: {}
                    )
                }
                section("Empty state") {
                    EmptyStateView(
                        title: "Your library is empty", message: "Add a folder or press Play on something to get started.",
                        systemImage: "film.stack", tips: ["Drop a folder here to import it."], actionTitle: "Add Folder…"
                    ) {}
                    .frame(height: 300)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Tokens.Radius.l))
                }
            }
            .padding(Tokens.Spacing.gutter)
        }
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(title).font(Tokens.Typography.sectionTitle)
            content()
        }
    }
}
