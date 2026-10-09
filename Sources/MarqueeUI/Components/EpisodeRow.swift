import SwiftUI

/// One episode in a season list: still, title, overview, watched state, quality badge and a live
/// download ring. Reads as a single VoiceOver element with Play and watched-toggle actions.
public struct EpisodeRow: View {
    private let episode: EpisodeModel
    private let onPlay: () -> Void
    private let onToggleWatched: () -> Void

    @State private var hovering = false

    public init(_ episode: EpisodeModel, onPlay: @escaping () -> Void, onToggleWatched: @escaping () -> Void) {
        self.episode = episode
        self.onPlay = onPlay
        self.onToggleWatched = onToggleWatched
    }

    private var isPlayable: Bool { episode.availability != .unaired }

    public var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                still
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "\(episode.number). \(episode.title)")
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(episode.watch == .watched ? .secondary : .primary)
                    Text(verbatim: metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !episode.overview.isEmpty {
                        Text(verbatim: episode.overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Tokens.Spacing.m)
                trailing
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .onHover { hovering = $0 }
        .motion(Tokens.Motion.fade, value: hovering)
        .contextMenu {
            Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
                .disabled(!isPlayable)
            Button(action: onToggleWatched) {
                Label(episode.watch == .watched ? "Mark as Unwatched" : "Mark as Watched",
                      systemImage: episode.watch == .watched ? "eye.slash" : "eye")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Episode \(episode.number), \(episode.title)"))
        .accessibilityValue(Text(verbatim: spokenState))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Play"), onPlay)
        .accessibilityAction(
            named: Text(episode.watch == .watched ? "Mark as Unwatched" : "Mark as Watched"),
            onToggleWatched
        )
    }

    private var still: some View {
        let size = CGSize(width: 136, height: 136 / Tokens.AspectRatio.still)
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.s + 2, style: .continuous)
        return ArtworkView(episode.still, targetSize: size)
            .frame(width: size.width, height: size.height)
            .overlay {
                if episode.watch == .watched { Color.black.opacity(0.35) }
            }
            .overlay {
                if hovering && isPlayable {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .overlay(alignment: .bottom) {
                if let f = episode.watch.fraction {
                    GeometryReader { proxy in
                        Rectangle().fill(.white)
                            .frame(width: proxy.size.width * f, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private var metaLine: String {
        var parts = episode.runtimeMinutes > 0 ? [Formatters.runtime(minutes: episode.runtimeMinutes)] : []
        if let date = episode.airDate {
            parts.append(episode.availability == .unaired
                         ? String(localized: "Airs \(Formatters.shortDate(date))")
                         : Formatters.shortDate(date))
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: Tokens.Spacing.s + 2) {
            if let q = episode.quality, episode.availability == .local || episode.availability == .importing {
                QualityBadge(q)
            }
            switch episode.availability {
            case .downloading:
                HStack(spacing: 6) {
                    LiveProgressRing(id: episode.id, fallback: episode.downloadFraction, lineWidth: 2.5)
                        .frame(width: 22, height: 22)
                    DownloadPercent(id: episode.id, fallback: episode.downloadFraction)
                }
            case .queued:
                StatusPill("Queued", systemImage: "clock")
            case .importing:
                StatusPill("Importing", systemImage: "tray.and.arrow.down", kind: .info)
            case .missing:
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .help(Text("Not downloaded. Play will find and stream a release."))
            case .unaired:
                Image(systemName: "calendar").foregroundStyle(.tertiary)
            case .local:
                if episode.watch == .watched {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 70, alignment: .trailing)
    }

    private var spokenState: String {
        var parts = episode.runtimeMinutes > 0 ? [Formatters.runtime(minutes: episode.runtimeMinutes)] : []
        switch episode.watch {
        case .watched: parts.append(String(localized: "Watched"))
        case .inProgress(let f): parts.append(String(localized: "\(Formatters.percent(f)) watched"))
        case .unwatched: parts.append(String(localized: "Unwatched"))
        }
        switch episode.availability {
        case .downloading:
            parts.append(episode.downloadFraction.map { String(localized: "Downloading, \(Formatters.percent($0))") } ?? String(localized: "Downloading"))
        case .queued: parts.append(String(localized: "Queued"))
        case .importing: parts.append(String(localized: "Importing"))
        case .missing: parts.append(String(localized: "Not downloaded"))
        case .unaired: parts.append(String(localized: "Not released yet"))
        case .local: break
        }
        if let q = episode.quality { parts.append(QualityBadge.spoken(q)) }
        return parts.joined(separator: ", ")
    }
}

private struct DownloadPercent: View {
    let id: String
    let fallback: Double?
    @Environment(DownloadTracker.self) private var tracker: DownloadTracker?

    var body: some View {
        if let f = tracker?.box(for: id)?.fraction ?? fallback {
            Text(verbatim: Formatters.percent(f))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }
}
