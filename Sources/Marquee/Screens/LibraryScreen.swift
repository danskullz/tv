import SwiftUI
import MarqueeUI

struct LibraryScreen: View {
    let kind: MediaKind

    @Environment(AppModel.self) private var model
    @AppStorage("library.posterWidth") private var posterWidth = Tokens.PosterSize.standard
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var sort = LibrarySort.title
    @State private var visible: [PosterItem] = []
    @State private var selection: PosterItem.ID?
    @State private var isPreviewing = false

    private struct Inputs: Equatable {
        var revision: Int
        var query: String
        var filter: LibraryFilter
        var sort: LibrarySort
    }

    private var inputs: Inputs {
        Inputs(revision: model.titlesRevision, query: query, filter: filter, sort: sort)
    }

    private var previewItem: PosterItem? {
        guard isPreviewing, let selection else { return nil }
        return visible.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                if model.titles.isEmpty { loading } else { noResults }
            } else {
                PosterGrid(
                    items: visible,
                    posterWidth: $posterWidth,
                    selection: $selection,
                    actions: model.actions(for:),
                    onOpen: { model.open($0.id) },
                    onPlay: { model.play($0) },
                    onPreview: { _ in isPreviewing.toggle() },
                    onCancel: isPreviewing ? { isPreviewing = false } : nil
                )
            }
        }
        .overlay {
            if let item = previewItem {
                QuickPreview(item: item, onPlay: { model.play(item) }, onOpen: { model.open(item.id) }, onClose: { isPreviewing = false })
            }
        }
        .navigationTitle(Text(kind == .movie ? "Movies" : "TV Shows"))
        .navigationSubtitle(Text("\(visible.count) titles"))
        .searchable(text: $query, placement: .toolbar, prompt: Text("Filter \(kind == .movie ? "movies" : "shows")"))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { f in Text(f.title).tag(f) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help(Text("Filter by status"))
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(LibrarySort.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help(Text("Sort"))
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3.fill").imageScale(.small).foregroundStyle(.secondary)
                    Slider(value: $posterWidth, in: Tokens.PosterSize.minimum...Tokens.PosterSize.maximum)
                        .frame(width: 100)
                        .accessibilityLabel(Text("Poster size"))
                    Image(systemName: "square.grid.2x2.fill").imageScale(.small).foregroundStyle(.secondary)
                }
            }
        }
        .followsLiveProgress()
        .task(id: inputs) { refresh() }
    }

    private func refresh() {
        let i = inputs
        var items = model.titles.filter { $0.kind == kind && i.filter.matches($0) }
        if !i.query.isEmpty {
            items = FuzzyIndex(items) { $0.title }.search(i.query, limit: items.count)
        } else {
            switch i.sort {
            case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case .year: items.sort { $0.year > $1.year }
            case .added: items.sort { $0.addedAt > $1.addedAt }
            }
        }
        visible = items
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil; isPreviewing = false }
        if selection == nil { selection = items.first?.id }
    }

    private var loading: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: Tokens.Spacing.cardGap)], spacing: 26) {
                ForEach(0..<24, id: \.self) { _ in PosterSkeleton(width: posterWidth) }
            }
            .padding(Tokens.Spacing.gutter)
            .shimmering()
        }
    }

    private var noResults: some View {
        EmptyStateView(
            title: "No matches",
            message: "Nothing in your library fits these filters.",
            systemImage: "line.3.horizontal.decrease.circle",
            tips: ["Press ⌘K to search everything, including titles you haven't added yet."],
            actionTitle: "Clear Filters"
        ) {
            query = ""
            filter = .all
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unwatched, inProgress, watched, downloading, notDownloaded
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .unwatched: "Unwatched"
        case .inProgress: "In Progress"
        case .watched: "Watched"
        case .downloading: "Downloading"
        case .notDownloaded: "Not Downloaded"
        }
    }

    func matches(_ item: PosterItem) -> Bool {
        switch self {
        case .all: true
        case .unwatched: item.watch == .unwatched && item.availability != .unaired
        case .inProgress: item.watch.fraction != nil
        case .watched: item.watch == .watched
        case .downloading: item.availability.isActive
        case .notDownloaded: item.availability == .missing || item.availability == .unaired
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, year, added
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .year: "Year"
        case .added: "Date Added"
        }
    }
}

/// Quick Look style preview for the selected poster (Space).
struct QuickPreview: View {
    let item: PosterItem
    let onPlay: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(item.backdrop, targetSize: CGSize(width: 560, height: 315))
                    .aspectRatio(Tokens.AspectRatio.backdrop, contentMode: .fit)
                VStack(alignment: .leading, spacing: Tokens.Spacing.s + 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: item.title).font(.title.weight(.bold))
                        Spacer()
                        if let q = item.quality { QualityBadge(q) }
                    }
                    Text(verbatim: ([item.subtitle] + item.genres).joined(separator: "  ·  "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Spacing.s + 2) {
                        PlayButton(context: item.title, action: onPlay)
                        Button(action: onOpen) { Label("Details", systemImage: "info.circle") }
                            .buttonStyle(.marqueeSecondary)
                        Spacer()
                        Text("Space to close").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
                .padding(Tokens.Spacing.l)
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 40, y: 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Preview of \(item.title)"))
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}
