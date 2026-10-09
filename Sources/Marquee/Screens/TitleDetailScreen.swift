import SwiftUI
import AppKit
import MarqueeCore
import MarqueeUI

struct TitleDetailScreen: View {
    let id: PosterItem.ID

    @Environment(AppModel.self) private var model
    @State private var detail: TitleDetail?
    @State private var expanded: Set<Int> = []
    @State private var missing = false
    @State private var browseDetail: BrowseDetails?
    @State private var browseError: String?
    @State private var selectedPerson: PersonSummary?
    @State private var showWhyRelease = false

    var body: some View {
        Group {
            if AppServices.parseCatalogueID(id) != nil {
                if let browseDetail { catalogueContent(browseDetail) }
                else if let browseError {
                    VStack(spacing: 12) {
                        ErrorBanner(title: "Title details couldn't load", message: "Check your connection and retry.", details: browseError, fixTitle: "Retry") {
                            Task { await loadCatalogueDetail() }
                        }
                        EmptyStateView(title: "Keep browsing", message: "The rest of Discover is still available.", systemImage: "wifi.exclamationmark")
                    }.padding(.top, 30)
                } else { skeleton }
            } else if let detail {
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
        .navigationTitle(Text(verbatim: browseDetail?.item.title ?? detail?.item.title ?? ""))
        .heroScrollEdge()
        .toolbar(removing: .title)
        .followsLiveProgress()
        .task(id: LoadKey(id: id, revision: model.titlesRevision)) {
            if AppServices.parseCatalogueID(id) != nil {
                await loadCatalogueDetail()
                return
            }
            let loaded = try? await model.source.detail(for: id)
            let firstLoad = detail == nil
            detail = loaded
            missing = loaded == nil
            let arriving = loaded?.seasons.first { $0.episodes.contains { $0.availability == .downloading } }
            if firstLoad,
                let first = arriving ?? loaded?.seasons.first(where: { $0.firstUnwatched != nil }) ?? loaded?.seasons.first
            {
                expanded = [first.number]
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonFilmographySheet(person: person) { model.open($0) }
                .frame(minWidth: 680, minHeight: 560)
        }
        .sheet(isPresented: $showWhyRelease) {
            WhyReleaseSheet(titleID: id, title: detail?.item.title ?? "")
                .frame(minWidth: 580, minHeight: 480)
        }
    }

    private struct LoadKey: Equatable {
        var id: PosterItem.ID
        var revision: Int
    }

    private func loadCatalogueDetail() async {
        guard let services = model.services else { browseError = "Set up metadata in Settings to browse TMDB."; return }
        browseError = nil
        do { browseDetail = try await services.browseDetails(id: id) }
        catch is CancellationError { }
        catch { browseError = error.localizedDescription }
    }

    private func catalogueContent(_ d: BrowseDetails) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                HeroHeader(
                    title: d.item.title,
                    eyebrow: d.item.kind == .movie ? String(localized: "Movie") : String(localized: "Series"),
                    metadata: catalogueMetadata(d), overview: d.tagline ?? d.overview,
                    backdrop: d.item.backdrop, height: 480
                ) {
                    if d.item.isInLibrary {
                        Button {} label: { Label("In Your Library", systemImage: "checkmark.circle.fill") }
                            .disabled(true).buttonStyle(.marqueePlay)
                    } else {
                        Button { want(d.item) } label: { Label("Want It", systemImage: "plus") }.buttonStyle(.marqueePlay)
                    }
                    if !d.trailers.isEmpty {
                        Button { open(d.trailers.first?.externalURL) } label: { Label("Watch Trailer", systemImage: "play.rectangle") }
                            .buttonStyle(.marqueeSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                    if !d.overview.isEmpty { Text(verbatim: d.overview).font(.body).textSelection(.enabled).frame(maxWidth: 780, alignment: .leading) }
                    legalAvailability(d)
                    castAndCrew(d)
                    if let collection = d.collection {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Collection").font(Tokens.Typography.sectionTitle)
                            Text(verbatim: collection.name).font(.headline)
                            if let overview = collection.overview, !overview.isEmpty {
                                Text(verbatim: overview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        if !collection.parts.isEmpty {
                            ShelfRow(ShelfModel(id: "collection-\(collection.id)", title: collection.name,
                                                items: collection.parts.map(AppServices.poster)), onOpen: { model.open($0.id) })
                        }
                    }
                    if !d.seasons.isEmpty { seasons(d) }
                    if !d.recommendations.isEmpty {
                        ShelfRow(ShelfModel(id: "similar-\(d.item.id)", title: "More Like This", items: d.recommendations), onOpen: { model.open($0.id) })
                    }
                }.padding(.horizontal, Tokens.Spacing.gutter).padding(.bottom, Tokens.Spacing.xl)
            }
        }.ignoresSafeArea(.container, edges: .top)
    }

    private func catalogueMetadata(_ d: BrowseDetails) -> [String] {
        var parts = [d.item.year > 0 ? String(d.item.year) : nil, d.certification, d.runtime.map(Formatters.runtime(minutes:)),
                     d.genres.first, d.score.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) }].compactMap { $0 }
        if let imdb = d.imdbID { parts.append("IMDb \(imdb)") }
        return parts
    }

    @ViewBuilder
    private func legalAvailability(_ d: BrowseDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to Watch Legally").font(Tokens.Typography.sectionTitle)
            if d.providers.isEmpty {
                Text("No streaming providers are listed for \(AppServices.regionCode). Availability varies by region.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(d.providers) { provider in
                            HStack(spacing: 8) {
                                if let url = provider.logoPath?.url(size: .w92) {
                                    ArtworkView(.remote(url, placeholder: PlaceholderArt(hue: RealLibrary.hue(provider.name), symbol: "play.tv")), targetSize: CGSize(width: 30, height: 30))
                                        .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                                Text(verbatim: provider.name).font(.subheadline.weight(.medium))
                            }.padding(.vertical, 7).padding(.horizontal, 10).background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Text("Availability provided by TMDB. Check the service for current terms.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func castAndCrew(_ d: BrowseDetails) -> some View {
        if !d.cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast").font(Tokens.Typography.sectionTitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(d.cast.prefix(18)) { member in
                            Button { selectedPerson = PersonSummary(id: member.id, name: member.name, profilePath: member.profilePath) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(member.profilePath?.url(size: .w185).map { .remote($0, placeholder: PlaceholderArt(hue: RealLibrary.hue(member.name), symbol: "person.fill")) }
                                        ?? .generated(PlaceholderArt(hue: RealLibrary.hue(member.name), symbol: "person.fill")), targetSize: CGSize(width: 76, height: 76))
                                        .frame(width: 76, height: 76).clipShape(Circle())
                                    Text(verbatim: member.name).font(.subheadline.weight(.medium)).lineLimit(1).frame(width: 116, alignment: .leading)
                                    Text(verbatim: member.character ?? "Cast").font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 116, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        if !d.crew.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Crew").font(Tokens.Typography.sectionTitle)
                Text(verbatim: d.crew.prefix(5).map { "\($0.name) · \($0.job ?? $0.department ?? "Crew")" }.joined(separator: "   •   "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func seasons(_ d: BrowseDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons & Episodes").font(Tokens.Typography.sectionTitle)
            ForEach(d.seasons) { season in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: season.name).font(.headline)
                    ForEach(season.episodes) { episode in
                        HStack(spacing: 12) {
                            ArtworkView(episode.stillPath?.url(size: .w300).map { .remote($0, placeholder: PlaceholderArt(hue: RealLibrary.hue(episode.name), symbol: "tv")) }
                                ?? .generated(PlaceholderArt(hue: RealLibrary.hue(episode.name), symbol: "tv")), targetSize: CGSize(width: 150, height: 84))
                                .frame(width: 150, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Episode \(episode.episodeNumber) · \(episode.name)").font(.headline).lineLimit(1)
                                if let date = episode.airDate { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                if let overview = episode.overview, !overview.isEmpty { Text(verbatim: overview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func want(_ item: PosterItem) {
        guard let services = model.services else { return }
        Task {
            do {
                let title = try await services.want(item)
                model.show(Toast(title: String(localized: "Added \(title.title)"), detail: "Now monitored in your library.", systemImage: "checkmark.circle.fill"))
            } catch LibraryError.alreadyInLibrary(let existing) {
                model.show(Toast(title: "Already in your library", systemImage: "checkmark.circle.fill", actionTitle: "Show", action: {
                    model.go(to: item.kind == .movie ? .movies : .tv); model.open(existing.uuidString)
                }))
            } catch { model.show(Toast(title: "Couldn't add title", detail: error.localizedDescription, systemImage: "exclamationmark.triangle")) }
        }
    }

    private func open(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

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
        return parts.filter { !$0.isEmpty }
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
                Button { model.playSeason(item, season: d.seasons.first { $0.number > 0 }?.number ?? 1, fromStart: true) } label: { Label("Play from Episode 1", systemImage: "backward.end.fill") }
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
        if model.services != nil {
            Button { showWhyRelease = true } label: { Label("Why This Release?", systemImage: "questionmark.circle") }
                .buttonStyle(.plain)
        }
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
                Button { model.playSeason(d.item, season: season.number, fromStart: false) } label: { Label("Play Season", systemImage: "play.fill") }
                    .accessibilityLabel(Text("Play \(season.title)"))
                Button { model.playSeason(d.item, season: season.number, fromStart: true) } label: { Label("Play from Episode 1", systemImage: "backward.end.fill") }
                    .accessibilityLabel(Text("Play \(season.title) from episode 1"))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.vertical, 6)

            if isOpen {
                LazyVStack(spacing: 0) {
                    ForEach(season.episodes) { ep in
                        EpisodeRow(ep, onPlay: { model.play(d.item, episode: ep) }, onToggleWatched: { toggleWatched(ep) })
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
        let nowWatched = ep.watch != .watched
        d.seasons[si].episodes[ei].watch = nowWatched ? .watched : .unwatched
        model.setEpisodeWatched(d.item, ep, nowWatched)
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
