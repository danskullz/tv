import Foundation
import MarqueeCore
import MarqueeEngine
import TorrentEngine

/// What the user asked to play.
enum PlayTarget {
    /// A movie, or the next episode to watch for a series (resume the one in progress, else the first unwatched).
    case title(UUID)
    case episode(UUID, season: Int, episode: Int)
    /// A season as a binge: prefers a healthy complete pack. `startingAt == nil` starts at the first unwatched episode.
    case season(UUID, season: Int, startingAt: Int?)
}

extension AppServices {
    /// Progress-ring / row id of an episode (shared with `RealLibrary`).
    nonisolated static func episodeKey(_ titleID: UUID, season: Int, episode: Int) -> String {
        "\(titleID.uuidString)-s\(season)e\(episode)"
    }

    /// Plays `target`: search, pick, stream, and show it in the player. Failures are announced in plain language.
    func play(_ target: PlayTarget) async {
        do {
            let context = try await playContext(for: target)
            try await startPlayback(context)
        } catch let error as PlayPipelineError {
            announce("Couldn't start playback", error.plainLanguage, "exclamationmark.triangle")
        } catch let error as LocalizedError {
            announce("Couldn't start playback", error.errorDescription, "exclamationmark.triangle")
        } catch {
            announce("Couldn't start playback", "Something went wrong starting the stream. Try again.", "exclamationmark.triangle")
        }
    }

    // MARK: Context

    struct PlayContext {
        var title: Title
        var scope: PlayScope
        var episodes: [Episode]
        /// The episode being started (nil for movies).
        var current: Episode?
        var startAt: Double?
    }

    private func playContext(for target: PlayTarget) async throws -> PlayContext {
        let titleID: UUID
        switch target {
        case .title(let id), .episode(let id, _, _), .season(let id, _, _): titleID = id
        }
        guard let title = try await library.title(id: titleID) else { throw LibraryError.notFound(titleID) }
        if title.kind == .movie {
            let state = try await watchStates.state(for: title.id)
            return PlayContext(title: title, scope: .movie, episodes: [], current: nil, startAt: Self.resume(state))
        }
        let episodes = try await library.episodes(titleId: title.id)
        let states = Dictionary(uniqueKeysWithValues: try await watchStates.states(titleId: title.id).map { ($0.id, $0) })

        func firstUnwatched(inSeason season: Int?) -> Episode? {
            let playable = episodes.filter { ($0.seasonNumber > 0) && (season == nil || $0.seasonNumber == season) && Self.isAired($0) }
            return playable.first { states[$0.id]?.watched != true } ?? playable.first
        }
        let episode: Episode?
        var season: Int?
        var asSeason = false
        switch target {
        case .title:
            episode = firstUnwatched(inSeason: nil)
        case .episode(_, let s, let e):
            episode = episodes.first { $0.seasonNumber == s && $0.episodeNumber == e }
        case .season(_, let s, let from):
            season = s
            asSeason = true
            episode = from.flatMap { n in episodes.first { $0.seasonNumber == s && $0.episodeNumber == n } } ?? firstUnwatched(inSeason: s)
        }
        guard let episode else { throw PlayPipelineError.noResults(indexersSearched: 0, indexersFailed: 0) }
        let ref = EpisodeRef(season: episode.seasonNumber, episode: episode.episodeNumber)
        let scope: PlayScope = asSeason ? .season(season ?? episode.seasonNumber, startingAt: ref) : .episode(ref)
        let startAt = asSeason && target.isFromBeginning ? nil : Self.resume(states[episode.id])
        return PlayContext(title: title, scope: scope, episodes: episodes, current: episode, startAt: startAt)
    }

    nonisolated static func isAired(_ episode: Episode) -> Bool {
        guard let date = episode.airDate else { return true }
        return date <= Date()
    }

    nonisolated static func resume(_ state: MarqueeCore.WatchState?) -> Double? {
        guard let state, !state.watched, state.positionSeconds > 5 else { return nil }
        return state.positionSeconds
    }

    // MARK: Start

    private func startPlayback(_ context: PlayContext) async throws {
        let pipeline = try await playPipeline()
        let title = context.title
        let profile = QualityProfileConfig.presets.first { $0.id == title.qualityProfileId } ?? AppSettings.defaultPreset

        var runtime: Double? = context.current?.runtime.map(Double.init)
        var imdb = title.imdbId
        if title.kind == .movie, let tmdbID = title.tmdbId, let client = tmdb(), let details = try? await client.movieDetails(id: tmdbID) {
            runtime = details.runtime.map(Double.init)
            imdb = imdb ?? details.imdbID
        } else if title.kind == .series, runtime == nil {
            runtime = context.episodes.compactMap(\.runtime).first.map(Double.init)
        }
        let playTitle = PlayTitle(
            id: title.id, kind: title.kind, name: title.title, year: title.year, tmdbID: title.tmdbId,
            tvdbID: title.tvdbId, imdbID: imdb, runtimeMinutes: runtime)
        let request = PlayRequest(
            title: playTitle, scope: context.scope, profile: profile,
            episodes: context.episodes.map {
                PackEpisode(
                    ref: EpisodeRef(season: $0.seasonNumber, episode: $0.episodeNumber), title: $0.title,
                    isAired: Self.isAired($0))
            },
            episodeID: context.current?.id)
        let operation = pipeline.begin(request)
        let session = ActivePlayback(services: self, context: context, operation: operation)
        activePlaybacks.append(session)
        session.present(startAt: context.startAt)
    }
}

private extension PlayTarget {
    var isFromBeginning: Bool {
        if case .season(_, _, let from) = self { return from != nil }
        return false
    }
}

extension StreamStatus {
    /// The plain-language line the player shows.
    var line: String {
        switch self {
        case .fetchingMetadata: "Fetching release details…"
        case .findingPeers: "Connecting to peers…"
        case .buffering(let seconds, _): "Buffering \(Int(seconds.rounded(.down))) s ahead…"
        case .ready: "Ready to play"
        case .stalled(let reason): reason.message
        case .failed(let message): message
        }
    }
}

/// One Play from press to window close: shows the player, records watch progress, offers the next
/// episode, and stops the stream once the last window using it closes.
@MainActor
final class ActivePlayback {
    private unowned let services: AppServices
    private var context: AppServices.PlayContext
    private var operation: PlayOperation
    private var windows = 0
    private var stream: PlayStream?

    init(services: AppServices, context: AppServices.PlayContext, operation: PlayOperation) {
        self.services = services
        self.context = context
        self.operation = operation
    }

    private var playableID: UUID { context.current?.id ?? context.title.id }

    private var subtitle: String? {
        guard let e = context.current else { return nil }
        let name = e.title.map { " · \($0)" } ?? ""
        return "S\(e.seasonNumber) · E\(e.episodeNumber)\(name)"
    }

    func present(startAt: Double?) {
        windows += 1
        let operation = self.operation
        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let forwarder = Task { [weak self] in
            for await status in operation.statuses { continuation.yield(status.message) }
            guard let stream = try? await operation.stream() else { continuation.finish(); return }
            await self?.streamStarted(stream)
            for await status in stream.control.statusUpdates() { continuation.yield(status.line) }
            continuation.finish()
        }
        services.presenter.present(PlayerSessionRequest(
            title: context.title.title, subtitle: subtitle, artworkURL: nil, startAt: startAt,
            urlProvider: { try await operation.stream().url },
            statusLines: lines,
            onProgress: { [weak self] position, duration in self?.record(position: position, duration: duration) },
            onEnded: { [weak self] in await self?.ended() },
            onClose: { [weak self] in
                forwarder.cancel()
                self?.windowClosed()
            }))
    }

    private func streamStarted(_ stream: PlayStream) async {
        self.stream = stream
        let title = context.title
        var progressIDs: [String] = []
        if let e = context.current {
            progressIDs = [AppServices.episodeKey(title.id, season: e.seasonNumber, episode: e.episodeNumber)]
        }
        let label = subtitle.map { "\(title.title) · \($0)" } ?? title.title
        await services.monitor.register(
            DownloadMonitor.Entry(
                id: stream.control.torrent, titleID: title.id, label: label, releaseName: stream.release.title,
                progressIDs: progressIDs, startedAt: Date(), isStreamOnly: false),
            savePath: services.downloadFolder.path)
        try? await services.history.append(HistoryEvent(
            type: .streamStarted, entityType: .torrent, entityId: stream.control.torrent.hex, titleId: title.id,
            payload: ["release": .string(stream.release.title), "grab": .string(stream.release.grabID.uuidString)]))
        services.libraryChanged()
    }

    private func record(position: Double, duration: Double?) {
        let id = playableID, titleID = context.title.id
        let services = self.services
        let control = stream?.control
        Task {
            if let duration, duration > 0 { await control?.setMediaDuration(duration) }
            try? await services.watchStates.recordProgress(
                id: id, titleId: titleID, position: position, duration: duration, watchedThreshold: 0.9)
        }
    }

    private func ended() async -> UpNextOffer? {
        try? await services.watchStates.setWatched(id: playableID, titleId: context.title.id, watched: true)
        services.libraryChanged()
        guard let current = context.current else { return nil }
        let next = context.episodes.first {
            $0.seasonNumber > 0
                && ($0.seasonNumber, $0.episodeNumber) > (current.seasonNumber, current.episodeNumber)
                && AppServices.isAired($0)
        }
        guard let next else { return nil }
        let name = next.title.map { " · \($0)" } ?? ""
        return UpNextOffer(title: "S\(next.seasonNumber) · E\(next.episodeNumber)\(name)") { [weak self] in
            Task { await self?.playNext(next) }
        }
    }

    /// Continues inside the same torrent when it is a pack (no new search, no buffering gap), else plays it afresh.
    private func playNext(_ next: Episode) async {
        let ref = EpisodeRef(season: next.seasonNumber, episode: next.episodeNumber)
        if let stream, let handle = try? await stream.control.advance(to: ref) {
            context.current = next
            let advanced = PlayStream(url: handle.url, episodes: handle.episodes, release: stream.release, control: stream.control)
            self.stream = advanced
            let states = try? await services.watchStates.state(for: next.id)
            presentAdvanced(url: handle.url, startAt: AppServices.resume(states), control: stream.control)
        } else {
            await services.play(.episode(context.title.id, season: next.seasonNumber, episode: next.episodeNumber))
        }
    }

    private func presentAdvanced(url: URL, startAt: Double?, control: PlayStreamControl) {
        windows += 1
        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let forwarder = Task {
            for await status in control.statusUpdates() { continuation.yield(status.line) }
            continuation.finish()
        }
        services.presenter.present(PlayerSessionRequest(
            title: context.title.title, subtitle: subtitle, artworkURL: nil, startAt: startAt,
            urlProvider: { url }, statusLines: lines,
            onProgress: { [weak self] position, duration in self?.record(position: position, duration: duration) },
            onEnded: { [weak self] in await self?.ended() },
            onClose: { [weak self] in
                forwarder.cancel()
                self?.windowClosed()
            }))
    }

    private func windowClosed() {
        windows -= 1
        guard windows <= 0 else { return }
        services.activePlaybacks.removeAll { $0 === self }
        operation.cancel()  // no-op once the stream exists
        let stream = self.stream
        let services = self.services
        Task {
            // A stream is just a download being watched: stop serving, keep downloading.
            await stream?.control.stop(removeTorrent: false)
            services.libraryChanged()
        }
    }
}
