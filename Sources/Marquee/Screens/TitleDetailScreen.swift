import SwiftUI
import MarqueeUI

struct TitleDetailScreen: View {
    let id: PosterItem.ID

    @Environment(AppModel.self) private var model
    @State private var detail: TitleDetail?
    @State private var expanded: Set<Int> = []
    @State private var missing = false

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if missing {
                EmptyStateView(
                    title: "Title not found", message: "It may have been removed from your library.",
                    systemImage: "questionmark.square.dashed", actionTitle: "Back to Library"
                ) { model.path = [] }
            } else {
                skeleton
            }
        }
        .navigationTitle(Text(verbatim: detail?.item.title ?? ""))
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .followsLiveProgress()
        .task(id: id) {
            let loaded = try? await model.source.detail(for: id)
            detail = loaded
            missing = loaded == nil
            let arriving = loaded?.seasons.first { $0.episodes.contains { $0.availability == .downloading } }
            if let first = arriving ?? loaded?.seasons.first(where: { $0.firstUnwatched != nil }) ?? loaded?.seasons.first {
                expanded = [first.number]
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            SkeletonView(cornerRadius: 0).frame(height: 440)
            SkeletonView().frame(width: 320, height: 18).padding(.horizontal, Tokens.Spacing.gutter)
            SkeletonView().frame(height: 72).padding(.horizontal, Tokens.Spacing.gutter)
            Spacer()
        }
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityLabel(Text("Loading"))
    }

    // MARK: Content

    private func content(_ d: TitleDetail) -> some View {
        let item = d.item
        return ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                HeroHeader(
                    title: item.title,
                    eyebrow: item.kind == .movie ? String(localized: "Movie") : String(localized: "Series"),
                    metadata: metadata(d),
                    quality: item.quality,
                    overview: d.overview,
                    backdrop: item.backdrop,
                    height: 480
                ) { actions(d) }

                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    DownloadStatusLine(item: item)
                    if item.kind == .movie { movieBody(d) } else { seasonsBody(d) }
                    castRow(d)
                }
                .padding(.horizontal, Tokens.Spacing.gutter)
                .padding(.bottom, Tokens.Spacing.xl)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func metadata(_ d: TitleDetail) -> [String] {
        var parts = ["\(d.item.year)", d.certification]
        if d.item.kind == .series {
            parts.append(d.seasons.count == 1 ? String(localized: "1 Season") : String(localized: "\(d.seasons.count) Seasons"))
        } else if let r = d.runtimeMinutes {
            parts.append(Formatters.runtime(minutes: r))
        }
        if let g = d.item.genres.first { parts.append(g) }
        if let s = d.score { parts.append("★ " + s.formatted(.number.precision(.fractionLength(1)))) }
        return parts
    }

    @ViewBuilder
    private func actions(_ d: TitleDetail) -> some View {
        let item = d.item
        if item.availability == .unaired {
            Button { model.show(Toast(title: String(localized: "We'll let you know"), detail: String(localized: "You'll get a notification when \(item.title) is available."), systemImage: "bell.fill")) } label: {
                Label("Notify Me", systemImage: "bell")
            }
            .buttonStyle(.marqueePlay)
        } else {
            if let resume = d.resume {
                PlayButton(resume.label.isEmpty ? "Resume" : "Resume \(resume.label)", context: item.title) { model.play(item) }
            } else {
                PlayButton("Play", context: item.title) { model.play(item) }
            }
            if item.kind == .series {
                Button { model.play(item) } label: { Label("Play from Episode 1", systemImage: "backward.end.fill") }
                    .buttonStyle(.marqueeSecondary)
            }
        }
        if item.availability == .missing {
            Button { model.show(Toast(title: String(localized: "Download started"), detail: item.title, systemImage: "arrow.down.circle.fill")) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.marqueeSecondary)
        }
        Button {
            model.show(Toast(title: String(localized: "Monitoring \(item.title)"), detail: String(localized: "New releases will download automatically."), systemImage: "eye.fill"))
        } label: { Label("Monitor", systemImage: "eye") }
            .buttonStyle(.marqueeSecondary)
    }

    // MARK: Movie

    @ViewBuilder
    private func movieBody(_ d: TitleDetail) -> some View {
        if !d.fileInfo.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text("File").font(Tokens.Typography.sectionTitle)
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(d.fileInfo, id: \.self) { StatusPill(verbatim: $0) }
                }
            }
        }
    }

    // MARK: Series

    private func seasonsBody(_ d: TitleDetail) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("Seasons").font(Tokens.Typography.sectionTitle)
            ForEach(d.seasons) { season in
                seasonSection(season, of: d)
            }
        }
    }

    private func seasonSection(_ season: SeasonModel, of d: TitleDetail) -> some View {
        let isOpen = expanded.contains(season.number)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.m) {
                Button {
                    withMotion { if isOpen { expanded.remove(season.number) } else { expanded.insert(season.number) } }
                } label: {
                    HStack(spacing: Tokens.Spacing.s) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(verbatim: season.title).font(.title3.weight(.semibold))
                        Text("\(season.watchedCount) of \(season.episodes.count) watched")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: season.title))
                .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed"))
                .accessibilityHint(Text("Shows or hides episodes"))
                Spacer()
                Button { model.play(d.item) } label: { Label("Play Season", systemImage: "play.fill") }
                    .accessibilityLabel(Text("Play \(season.title)"))
                Button { model.play(d.item) } label: { Label("Play from Episode 1", systemImage: "backward.end.fill") }
                    .accessibilityLabel(Text("Play \(season.title) from episode 1"))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.vertical, 6)

            if isOpen {
                LazyVStack(spacing: 0) {
                    ForEach(season.episodes) { ep in
                        EpisodeRow(ep, onPlay: { model.play(d.item) }, onToggleWatched: { toggleWatched(ep) })
                        if ep.id != season.episodes.last?.id {
                            Divider().padding(.leading, 160)
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
    }

    private func toggleWatched(_ ep: EpisodeModel) {
        guard var d = detail,
              let si = d.seasons.firstIndex(where: { $0.number == ep.season }),
              let ei = d.seasons[si].episodes.firstIndex(where: { $0.id == ep.id }) else { return }
        d.seasons[si].episodes[ei].watch = ep.watch == .watched ? .unwatched : .watched
        withMotion { detail = d }
    }

    // MARK: Cast

    @ViewBuilder
    private func castRow(_ d: TitleDetail) -> some View {
        if !d.cast.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s + 2) {
                Text("Cast").font(Tokens.Typography.sectionTitle)
                HStack(spacing: Tokens.Spacing.m) {
                    ForEach(d.cast, id: \.self) { name in
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title)
                                .foregroundStyle(.tertiary)
                            Text(verbatim: name).font(.subheadline)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: d.cast.joined(separator: ", ")))
            }
        }
    }
}

/// "Downloading · 42% · ~19 min left · ready to watch" for titles that are still arriving.
struct DownloadStatusLine: View {
    let item: PosterItem
    @Environment(DownloadTracker.self) private var tracker: DownloadTracker?

    var body: some View {
        if item.availability == .downloading {
            let box = tracker?.box(for: item.id)
            let fraction = box?.fraction ?? item.downloadFraction ?? 0
            HStack(spacing: Tokens.Spacing.m) {
                ProgressRing(fraction: fraction, lineWidth: 3.5).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(streamLine(fraction)).font(.headline)
                    Text(verbatim: detailLine(fraction, box: box)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Tokens.Spacing.m)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous))
            .accessibilityElement(children: .combine)
        } else if item.availability == .queued {
            HStack { StatusPill("Queued", systemImage: "clock"); Text("Waiting for a free download slot.").foregroundStyle(.secondary) }
        }
    }

    private func streamLine(_ f: Double) -> LocalizedStringKey {
        f >= StreamingPolicy.readyFraction ? "Downloading · ready to watch now" : "Downloading · almost ready to watch"
    }

    private func detailLine(_ f: Double, box: ProgressBox?) -> String {
        var parts = [Formatters.percent(f)]
        if let eta = box?.etaSeconds { parts.append(String(localized: "\(Formatters.approximate(seconds: eta)) left")) }
        if let bps = box?.bytesPerSecond { parts.append(Formatters.speed(bytesPerSecond: bps)) }
        return parts.joined(separator: "  ·  ")
    }
}

/// Mock of the buffer threshold after which a stream can start.
enum StreamingPolicy {
    static let readyFraction = 0.04
}
