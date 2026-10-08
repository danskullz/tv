import SwiftUI
import MarqueeUI

struct ActivityScreen: View {
    @Environment(AppModel.self) private var model
    @State private var items: [ActivityItem] = []
    @State private var loaded = false
    @State private var dismissedFailure = false

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
                    actionTitle: "Browse Library"
                ) { model.go(to: .movies) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m, pinnedViews: []) {
                        if let f = failed.first, !dismissedFailure {
                            ErrorBanner(
                                title: "\(f.title) hasn't started",
                                message: "None of the releases we found had enough people sharing them. We'll keep looking, or you can try a smaller version now.",
                                details: "Indexers queried: 6\nReleases considered: 14\nRejected: 14 (seeders < 2: 11, size over limit: 3)\nLast attempt: \(f.date.formatted(date: .abbreviated, time: .shortened))",
                                fixTitle: "Try a Smaller Version",
                                onFix: { model.show(Toast(title: String(localized: "Trying a smaller version"), detail: f.title, systemImage: "arrow.triangle.2.circlepath")) },
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
        .task {
            items = (try? await model.source.activity()) ?? []
            loaded = true
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
                Menu {
                    Button("Pause", systemImage: "pause.fill") {}
                    Button("Show in Finder", systemImage: "folder") {}
                    Divider()
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) {}
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More actions"))
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
