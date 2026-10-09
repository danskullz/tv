import MarqueeCore
import MarqueeUI
import SwiftUI

/// ⌘N: search TMDB, pick a result, choose a quality preset, add. Keyboard driven
/// (type to search, ↑/↓ to move, Return to add, Esc to close).
struct AddTitleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var results: [CatalogueResult] = []
    @State private var selection: CatalogueResult.ID?
    @State private var preset = AppSettings.defaultPreset
    @State private var isSearching = false
    @State private var adding: CatalogueResult.ID?
    @State private var message: String?
    @FocusState private var focused: Bool

    private var services: AppServices? { model.services }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .task { focused = true }
        .task(id: query) { await search() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
            TextField("Search movies and shows to add", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { addSelected() }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .accessibilityLabel(Text("Search TMDB"))
            if isSearching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if services?.hasMetadataKey != true {
            EmptyStateView(
                title: "Add a TMDB key first",
                message: "Marquee looks titles up on TMDB. It's free: create an account on themoviedb.org and paste your API key in Settings.",
                systemImage: "key", actionTitle: "Open Settings"
            ) {
                UserDefaults.standard.set("metadata", forKey: "settings.tab")
                dismiss()
                openSettings()
            }
        } else if let message {
            EmptyStateView(title: "Search didn't work", message: LocalizedStringKey(message), systemImage: "wifi.exclamationmark")
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyStateView(
                title: "Find something to watch", message: "Type a title. Add it, then press Play: Marquee finds a release and starts streaming.",
                systemImage: "plus.rectangle.on.rectangle")
        } else if results.isEmpty, !isSearching {
            EmptyStateView(title: "No results for “\(query)”", message: "Check the spelling, or try fewer words.", systemImage: "magnifyingglass")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { result in
                            row(result).id(result.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, new in if let new { proxy.scrollTo(new) } }
            }
        }
    }

    private func row(_ r: CatalogueResult) -> some View {
        let isSelected = selection == r.id
        return HStack(alignment: .top, spacing: 12) {
            ArtworkView(
                r.posterURL.map { .remote($0, placeholder: PlaceholderArt(hue: RealLibrary.hue(r.title), symbol: r.kind == .movie ? "film" : "tv")) }
                    ?? .generated(PlaceholderArt(hue: RealLibrary.hue(r.title), symbol: r.kind == .movie ? "film" : "tv")),
                targetSize: CGSize(width: 56, height: 84)
            )
            .frame(width: 56, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: r.title).font(.headline).lineLimit(1)
                    if let year = r.year { Text(verbatim: String(year)).foregroundStyle(.secondary) }
                }
                Text(r.kind == .movie ? "Movie" : "Series").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: r.overview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing(r)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selection = r.id }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ r: CatalogueResult) -> some View {
        if r.existing != nil {
            StatusPill("In Library", systemImage: "checkmark")
        } else if adding == r.id {
            ProgressView().controlSize(.small)
        } else {
            Button("Add") { add(r) }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("Add \(r.title)"))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Quality", selection: $preset) {
                ForEach(QualityProfileConfig.presets, id: \.id) { Text(verbatim: $0.name).tag($0) }
            }
            .frame(width: 200)
            Text(verbatim: preset.presetBlurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    // MARK: Actions

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let i = results.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : results.count)
        selection = results[max(0, min(results.count - 1, i + delta))].id
        return .handled
    }

    private func addSelected() {
        guard let r = results.first(where: { $0.id == selection }), r.existing == nil else { return }
        add(r)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        message = nil
        guard !q.isEmpty, let services, services.hasMetadataKey else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await services.searchCatalogue(q)
            selection = results.first?.id
        } catch is CancellationError {
        } catch let error as LocalizedError {
            message = error.errorDescription
        } catch {
            message = "TMDB couldn't be reached. Check your connection and try again."
        }
    }

    private func add(_ r: CatalogueResult) {
        guard let services, adding == nil else { return }
        adding = r.id
        let chosen = preset
        AppSettings.defaultPreset = chosen
        Task {
            defer { adding = nil }
            do {
                let title = try await services.addToLibrary(r, preset: chosen)
                if let i = results.firstIndex(where: { $0.id == r.id }) { results[i].existing = title.id }
                model.show(Toast(
                    title: String(localized: "Added \(title.title)"), detail: String(localized: "Press Play to start watching."),
                    systemImage: "checkmark.circle.fill", actionTitle: String(localized: "Show"),
                    action: { dismiss(); model.go(to: title.kind == .movie ? .movies : .tv); model.open(title.id.uuidString) }))
            } catch LibraryError.alreadyInLibrary(let existing) {
                if let i = results.firstIndex(where: { $0.id == r.id }) { results[i].existing = existing }
            } catch let error as LocalizedError {
                message = error.errorDescription
            } catch {
                message = "Couldn't add that title. Try again."
            }
        }
    }
}
