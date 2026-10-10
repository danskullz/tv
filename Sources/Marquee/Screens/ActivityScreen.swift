import AppKit
import SwiftUI
import MarqueeCore
import MarqueeUI
import TorrentEngine

struct ActivityScreen: View {
    @Environment(AppModel.self) private var model
    @State private var dismissedFailure = false

    /// Held on the model, not here: switching tabs removes this view and would otherwise throw the
    /// list away and make every return trip start from skeletons.
    private var items: [ActivityItem] { model.activityItems }
    private var loaded: Bool { model.didLoadActivity }

    private var active: [ActivityItem] { items.filter { $0.isActive || $0.phase == .subtitles } }
    private var failed: [ActivityItem] { items.filter { $0.phase == .failed } }
    private var today: [ActivityItem] { items.filter { $0.phase == .ready && Calendar.current.isDateInToday($0.date) } }
    private var earlier: [ActivityItem] { items.filter { $0.phase == .ready && !Calendar.current.isDateInToday($0.date) } }

    var body: some View {
        Group {
            if !loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(0..<5, id: \.self) { _ in SkeletonView(cornerRadius: Tokens.Radius.m, shimmer: false).frame(height: 72) }
                    }
                    .padding(Tokens.Spacing.gutter)
                    .shimmering()
                }
            } else if items.isEmpty {
                EmptyStateView(
                    title: "Nothing happening yet",
                    message: "Downloads, imports and subtitle searches show up here, with an honest estimate of when you can start watching.",
                    systemImage: "arrow.down.circle",
                    tips: ["Press Play on any title and it starts here."],
                    actionTitle: "Browse Library",
                    // Labeled: an unlabeled trailing closure would bind to `secondaryAction`
                    // under Swift 6 forward matching and the button would never appear.
                    action: { model.go(to: .movies) }
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m, pinnedViews: []) {
                        if let f = failed.first, !dismissedFailure {
                            let failureMessage = f.failureMessage ?? String(localized: "That release couldn't be played. Marquee tried the next best one.")
                            ErrorBanner(
                                title: "\(f.title) needs attention",
                                message: "\(failureMessage)",
                                details: "\(f.detail)\nLast attempt: \(f.date.formatted(date: .abbreviated, time: .shortened))",
                                fixTitle: model.services != nil ? "Try Again" : nil,
                                onFix: model.services != nil ? { retryDownload(item: f) } : nil,
                                onDismiss: { withMotion { dismissedFailure = true } }
                            )
                            .padding(.bottom, Tokens.Spacing.s)
                        }
                        section("In Progress", active)
                        section("Earlier Today", today)
                        section("Earlier", earlier)
                    }
                    .padding(.horizontal, Tokens.Spacing.gutter)
                    .padding(.vertical, Tokens.Spacing.l)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(Text("Activity"))
        .navigationSubtitle(Text("\(active.count) in progress"))
        .followsLiveProgress()
        // Reloads whenever the library changes (a download starts, finishes or is removed):
        // `.task` alone fires only once per view identity, so without this the list goes stale
        // while it is on screen. Membership changes in the torrent table reload it too, without
        // polling — progress-only writes keep the same fingerprint.
        .task(id: model.titlesRevision) { await load() }
        .task { await watchTorrents() }
    }

    private func load() async {
        let start = ContinuousClock.now
        let previousFailure = failed.first?.id
        await model.refreshActivity()
        PerfLog.record("ActivityScreen.load", seconds: PerfLog.seconds(since: start))
        if failed.first?.id != previousFailure { dismissedFailure = false }
    }

    /// Re-runs the search for a failed title and reports what happened.
    private func retryDownload(item: ActivityItem) {
        guard let services = model.services, let uuid = UUID(uuidString: item.titleID) else { return }
        Task {
            do {
                let result = try await services.downloadNow(titleID: uuid)
                if result.grabbed > 0 {
                    model.show(Toast(title: "Download queued", detail: item.title, systemImage: "arrow.down.circle.fill"))
                } else {
                    model.show(Toast(
                        title: "No release was grabbed",
                        detail: "Check indexers, quality settings, or availability.", systemImage: "info.circle"))
                }
            } catch {
                model.show(Toast(
                    title: "Couldn't start download", detail: error.localizedDescription,
                    systemImage: "exclamationmark.triangle"))
            }
        }
    }

    /// Reloads when torrents come or go (or change state) while this screen is visible.
    private func watchTorrents() async {
        guard let services = model.services else { return }
        var baseline: Set<String>?
        for await rows in services.torrents.observeTorrents() {
            let fingerprint = Set(rows.map { $0.infoHash + ":" + $0.state.rawValue })
            defer { baseline = fingerprint }
            guard baseline != nil else { continue }
            if baseline != fingerprint { await load() }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ rows: [ActivityItem]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(Tokens.Typography.sectionTitle)
                .padding(.top, Tokens.Spacing.s)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                    ActivityRow(item: item, isLast: i == rows.count - 1) { model.open(item.titleID) }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    let isLast: Bool
    let onOpen: () -> Void

    @Environment(DownloadTracker.self) private var tracker: DownloadTracker?
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let box = tracker?.box(for: item.id)
        let fraction = item.phase == .downloading ? (box?.fraction ?? item.fraction) : item.fraction
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            rail
            HStack(spacing: Tokens.Spacing.m) {
                ArtworkView(item.poster, targetSize: CGSize(width: 44, height: 66))
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Text(verbatim: item.title).font(.headline).lineLimit(1)
                        if let q = item.quality, item.phase != .searching { QualityBadge(q) }
                    }
                    Text(verbatim: statusLine(box: box, fraction: fraction))
                        .font(.subheadline)
                        .foregroundStyle(readyNow(fraction) ? Color.green : .secondary)
                        .lineLimit(1)
                    if item.phase == .downloading {
                        ProgressBar(fraction: fraction)
                            .frame(height: 5)
                            .padding(.top, 2)
                    } else if item.phase == .searching || item.phase == .importing || item.phase == .subtitles {
                        ProgressBar(fraction: nil).frame(height: 5).padding(.top, 2)
                    }
                }
                Spacer(minLength: Tokens.Spacing.m)
                trailing(fraction: fraction, box: box)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(hovering ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous))
            .onHover { hovering = $0 }
            .motion(Tokens.Motion.fade, value: hovering)
            .padding(.bottom, Tokens.Spacing.s + 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(verbatim: statusLine(box: box, fraction: fraction)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Show Details"), onOpen)
    }

    private func readyNow(_ fraction: Double) -> Bool {
        item.phase == .downloading && fraction >= StreamingPolicy.readyFraction
    }

    /// "Ready to watch in ~2 min" until the buffer threshold, then "Ready to watch · 12 min left".
    private func statusLine(box: ProgressBox?, fraction: Double) -> String {
        switch item.phase {
        case .searching, .importing, .subtitles, .failed: return item.detail
        case .ready: return item.detail + "  ·  " + item.date.formatted(.relative(presentation: .named))
        case .downloading:
            let total = box?.etaSeconds ?? (1 - fraction) * (item.totalSeconds ?? 0)
            let speed = (box?.bytesPerSecond ?? item.bytesPerSecond).map { Formatters.speed(bytesPerSecond: $0) }
            let tail = [Formatters.percent(fraction), speed].compactMap { $0 }.joined(separator: "  ·  ")
            if fraction >= StreamingPolicy.readyFraction {
                return String(localized: "Ready to watch  ·  \(Formatters.approximate(seconds: total)) left  ·  \(tail)")
            }
            let readyIn = total * (StreamingPolicy.readyFraction - fraction) / max(0.01, 1 - fraction)
            return String(localized: "Ready to watch in \(Formatters.approximate(seconds: readyIn))  ·  \(tail)")
        }
    }

    @ViewBuilder
    private func trailing(fraction: Double, box: ProgressBox?) -> some View {
        switch item.phase {
        case .downloading:
            HStack(spacing: Tokens.Spacing.s) {
                Button { model.play(PosterItem(id: item.titleID, kind: .movie, title: item.title, poster: item.poster)) } label: {
                    Label("Watch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(fraction < StreamingPolicy.readyFraction)
                .accessibilityHint(Text(fraction < StreamingPolicy.readyFraction ? "Not buffered enough yet" : "Starts streaming"))
                // Torrent-backed rows only exist with the real services; with mock data there is
                // no engine behind these items, so no menu rather than a dead one.
                if model.services != nil {
                    Menu {
                        DownloadRowMenu(infoHash: item.id)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("More actions"))
                }
            }
        case .searching: StatusPill("Searching", systemImage: "magnifyingglass", kind: .info)
        case .importing: StatusPill("Importing", systemImage: "tray.and.arrow.down", kind: .info)
        case .subtitles: StatusPill("Subtitles", systemImage: "captions.bubble", kind: .info)
        case .ready: StatusPill("Ready", systemImage: "checkmark", kind: .success)
        case .failed: StatusPill("Needs attention", systemImage: "exclamationmark.triangle", kind: .warning)
        }
    }

    /// Timeline rail: a phase dot with a line down to the next entry.
    private var rail: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 26, height: 26)
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            }
            .padding(.top, 20)
            Rectangle()
                .fill(Color.primary.opacity(isLast ? 0 : 0.12))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 26)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch item.phase {
        case .searching: "magnifyingglass"
        case .downloading: "arrow.down"
        case .importing: "tray.and.arrow.down"
        case .subtitles: "captions.bubble"
        case .ready: "checkmark"
        case .failed: "exclamationmark"
        }
    }

    private var color: Color {
        switch item.phase {
        case .searching, .importing, .subtitles, .downloading: .accentColor
        case .ready: .green
        case .failed: .orange
        }
    }
}

/// Thin linear progress bar; indeterminate when `fraction` is nil.
struct ProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(5, w * min(1, fraction)))
                        .motion(.linear(duration: 0.9), value: fraction)
                } else {
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: w * 0.3)
                        .offset(x: reduceMotion ? w * 0.35 : (sweep ? w * 0.7 : 0))
                }
            }
            .clipShape(Capsule())
        }
        .onAppear {
            guard fraction == nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityHidden(true)
    }
}

/// Pause / reveal / cancel for one torrent-backed Activity row. Only constructed when the real
/// services back the screen, so every item here does what it says.
private struct DownloadRowMenu: View {
    let infoHash: String

    @Environment(AppModel.self) private var model
    @State private var isPaused = false

    var body: some View {
        Group {
            if isPaused {
                Button("Resume", systemImage: "play.fill") { Task { await setPaused(false) } }
            } else {
                Button("Pause", systemImage: "pause.fill") { Task { await setPaused(true) } }
            }
            Button("Show in Finder", systemImage: "folder") { Task { await reveal() } }
            Divider()
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { Task { await cancel() } }
        }
        .task { await refresh() }
    }

    private var id: TorrentID { TorrentID(hex: infoHash) }

    private func refresh() async {
        guard let session = model.services?.engineHost.current else { return }
        guard let status = try? await session.status(id) else { return }
        isPaused = status.isPaused
    }

    private func setPaused(_ paused: Bool) async {
        guard let services = model.services, let session = services.engineHost.current else { return }
        do {
            if paused { try await session.pause(id) } else { try await session.resume(id) }
            isPaused = paused
            services.libraryChanged()
        } catch {
            model.show(Toast(
                title: paused ? "Couldn't pause the download" : "Couldn't resume the download",
                detail: error.localizedDescription, systemImage: "exclamationmark.triangle"))
        }
    }

    private func reveal() async {
        guard let services = model.services else { return }
        guard let row = try? await services.torrents.torrent(infoHash: infoHash) else {
            model.show(Toast(title: "Couldn't find the download", systemImage: "exclamationmark.triangle"))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.savePath, isDirectory: true)])
    }

    private func cancel() async {
        guard let services = model.services else { return }
        if let session = services.engineHost.current {
            do {
                try await session.remove(id, deleteFiles: true)
            } catch TorrentError.notFound {
                // Already gone from the engine; still clean up our rows below.
            } catch {
                model.show(Toast(
                    title: "Couldn't cancel the download", detail: error.localizedDescription,
                    systemImage: "exclamationmark.triangle"))
                return
            }
        }
        await services.monitor.unregister(id)
        try? await services.torrents.remove(infoHash: infoHash)
        services.libraryChanged()
        model.show(Toast(title: "Download cancelled", systemImage: "xmark.circle"))
    }
}
