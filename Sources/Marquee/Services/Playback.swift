import Foundation
import MarqueeCore
import MarqueeEngine
import MarqueeUI
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
            if let local = try? await localMediaResolver.file(
                titleID: context.title.id, episodeID: context.current?.id)
            {
                presentLocalPlayback(context, url: local)
                return
            }
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

    /// Builds the pipeline request for a context (runtime and ids from TMDB when available).
    fileprivate func playRequest(for context: PlayContext) async -> PlayRequest {
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
        return PlayRequest(
            title: playTitle, scope: context.scope, profile: profile,
            episodes: context.episodes.map {
                PackEpisode(
                    ref: EpisodeRef(season: $0.seasonNumber, episode: $0.episodeNumber), absolute: $0.absoluteNumber,
                    title: $0.title, isAired: Self.isAired($0))
            },
            episodeID: context.current?.id)
    }

    private func startPlayback(_ context: PlayContext) async throws {
        // A Play is already getting this episode: bring its window forward instead of
        // searching for a new source (a duplicate run would fight it for the player).
        let candidates = activePlaybacks.filter { $0.canServe(context) }
        if let existing = candidates.first(where: \.hasReadyStream) ?? candidates.first,
            await existing.takeOver(with: context, startAt: context.startAt)
        {
            return
        }
        let pipeline = try await playPipeline()
        let request = await playRequest(for: context)
        let session = ActivePlayback(services: self, context: context, pipeline: pipeline, request: request)
        activePlaybacks.append(session)
        if let saved = await orphanedDownload(for: context) {
            // Its player closed but the torrent is still downloading: serve from it instead
            // of searching for a new source. Falls back to a search when it doesn't work out.
            session.startAttaching(to: saved.id, release: saved.release, startAt: context.startAt)
        } else {
            session.start(startAt: context.startAt)
        }
    }

    /// A still-downloading torrent for this episode whose player closed (no live session).
    private func orphanedDownload(for context: PlayContext) async -> DownloadMonitor.Entry? {
        let entries = await monitor.active
        if let e = context.current {
            let key = Self.episodeKey(context.title.id, season: e.seasonNumber, episode: e.episodeNumber)
            return entries.first { $0.titleID == context.title.id && $0.progressIDs.contains(key) }
        }
        return entries.first { $0.titleID == context.title.id }
    }

    private func presentLocalPlayback(_ context: PlayContext, url: URL) {
        let title = context.title
        let episode = context.current
        let playableID = episode?.id ?? title.id
        let episodes = context.current == nil ? [] : context.episodes
            .filter { $0.seasonNumber > 0 && Self.isAired($0) }
            .map {
                PlayerEpisode(
                    id: $0.id.uuidString, title: $0.title ?? "Episode \($0.episodeNumber)",
                    subtitle: "S\($0.seasonNumber) · E\($0.episodeNumber)", artwork: RealLibrary.art(title, backdrop: true))
            }
        let subtitle = episode.map {
            "S\($0.seasonNumber) · E\($0.episodeNumber)" + ($0.title.map { " · \($0)" } ?? "")
        } ?? ""
        PlayerPresenter.shared.present(PlayerRequest(
            title: title.title, subtitle: subtitle, artwork: RealLibrary.art(title, backdrop: true),
            source: .url(url), startPosition: context.startAt ?? 0, episodes: episodes,
            currentEpisodeID: episode?.id.uuidString,
            onPositionChange: { [weak self] position, duration in
                guard let self else { return }
                Task {
                    try? await self.watchStates.recordProgress(
                        id: playableID, titleId: title.id, position: position, duration: duration,
                        watchedThreshold: 0.9)
                }
            },
            onFinished: { [weak self] in
                guard let self else { return }
                Task {
                    try? await self.watchStates.setWatched(id: playableID, titleId: title.id, watched: true)
                    self.libraryChanged()
                }
            },
            onNextEpisode: { [weak self] next in
                guard let self,
                    let nextEpisode = context.episodes.first(where: { $0.id.uuidString == next.id })
                else { return }
                Task {
                    await self.play(.episode(
                        title.id, season: nextEpisode.seasonNumber, episode: nextEpisode.episodeNumber))
                }
            },
            onClose: { [weak self] position in
                guard let self else { return }
                Task {
                    try? await self.watchStates.recordProgress(
                        id: playableID, titleId: title.id, position: position, duration: nil,
                        watchedThreshold: 0.9)
                }
            }))
    }
}

private extension PlayTarget {
    var isFromBeginning: Bool {
        if case .season(_, _, let from) = self { return from != nil }
        return false
    }
}

// MARK: - Status mapping

extension PlayStatus {
    /// The typed status the player shows.
    var playerStatus: PlayerBufferingStatus {
        if let stream, let mapped = stream.playerStatus { return mapped }
        switch phase {
        case .ready: return .ready
        case .failed: return .failed(message: message)
        default: return .preparing(message: message)
        }
    }
}

extension StreamStatus {
    var playerStatus: PlayerBufferingStatus? {
        switch self {
        case .fetchingMetadata: .fetchingMetadata
        case .findingPeers: .findingPeers
        case .buffering(let seconds, _): .buffering(secondsAhead: seconds)
        case .ready: .ready
        case .stalled(let reason): .stalled(message: reason.message)
        case .failed(let message): .failed(message: message)
        }
    }
}

// MARK: - One playback session

/// One Play from press to window close, spanning every episode shown in the same player window. Shows
/// the player, records watch progress, chains episodes (inside the same torrent when it is a pack, else
/// with a fresh pipeline run), and stops the stream when the window closes.
@MainActor
final class ActivePlayback {
    private unowned let services: AppServices
    private var context: AppServices.PlayContext
    private let pipeline: PlayPipeline
    private var pipelineRequest: PlayRequest
    private var operation: PlayOperation?
    private var stream: PlayStream?
    /// Set when the pipeline search/stream for this session failed: a re-press must run a
    /// fresh search instead of reusing the dead operation.
    private var pipelineFailed = false
    private var importForwarder: Task<Void, Never>?
    private var feed: AsyncStream<PlayerBufferingStatus>.Continuation?
    private var forwarder: Task<Void, Never>?
    /// Bumped whenever the shown episode changes, so late callbacks from a replaced one are ignored.
    private var generation = 0

    init(services: AppServices, context: AppServices.PlayContext, pipeline: PlayPipeline, request: PlayRequest) {
        self.services = services
        self.context = context
        self.pipeline = pipeline
        self.pipelineRequest = request
    }

    // MARK: Entry

    func start(startAt: Double?) {
        beginPipeline()
        present(source: pipelineSource(), startAt: startAt ?? 0, statuses: makeFeed())
        forwardPipeline()
    }

    /// Serves a still-downloading torrent after its player closed: no search. When the torrent
    /// is gone or holds different content, the player falls back to a fresh search on its own.
    func startAttaching(to torrent: TorrentID, release: ChosenRelease, startAt: Double?) {
        operation = pipeline.attach(pipelineRequest, to: torrent, release: release)
        present(source: pipelineSource(), startAt: startAt ?? 0, statuses: makeFeed())
        forwardAttach()
    }

    // MARK: Request building

    private var playableID: UUID { context.current?.id ?? context.title.id }

    private func subtitle(_ e: Episode?) -> String {
        guard let e else { return "" }
        return "S\(e.seasonNumber) · E\(e.episodeNumber)" + (e.title.map { " · \($0)" } ?? "")
    }

    private var playerEpisodes: [PlayerEpisode] {
        let art = RealLibrary.art(context.title, backdrop: true)
        return context.episodes
            .filter { $0.seasonNumber > 0 && AppServices.isAired($0) }
            .map {
                PlayerEpisode(
                    id: $0.id.uuidString, title: $0.title ?? "Episode \($0.episodeNumber)",
                    subtitle: "S\($0.seasonNumber) · E\($0.episodeNumber)", artwork: art)
            }
    }

    private func present(source: PlayerSource, startAt: TimeInterval, statuses: AsyncStream<PlayerBufferingStatus>) {
        generation += 1
        let mine = generation
        let current = context.current
        PlayerPresenter.shared.present(PlayerRequest(
            title: context.title.title, subtitle: subtitle(current), artwork: RealLibrary.art(context.title, backdrop: true),
            source: source, startPosition: startAt, statusUpdates: statuses,
            episodes: context.current == nil ? [] : playerEpisodes, currentEpisodeID: current?.id.uuidString,
            onPositionChange: { [weak self] position, duration in
                guard let self, self.generation == mine else { return }
                self.record(position: position, duration: duration)
            },
            onFinished: { [weak self] in
                guard let self, self.generation == mine else { return }
                self.finished()
            },
            onNextEpisode: { [weak self] episode in self?.switchTo(episodeID: episode.id) },
            onRetry: { [weak self] in
                guard let self, self.generation == mine else { return }
                self.retry()
            },
            onClose: { [weak self] position in
                guard let self, self.generation == mine else { return }
                self.closed(position: position)
            }))
    }

    /// Resolves the stream from whatever pipeline operation is current (a Retry replaces it).
    private func pipelineSource() -> PlayerSource {
        .deferred { [weak self] in
            guard let operation = await self?.operation else { throw CancellationError() }
            return try await operation.stream().url
        }
    }

    // MARK: Pipeline

    private func beginPipeline() {
        operation?.cancel()
        operation = pipeline.begin(pipelineRequest)
    }

    /// One status stream per presented request, fed by the pipeline's lines and then the stream's own state.
    private func makeFeed() -> AsyncStream<PlayerBufferingStatus> {
        feed?.finish()
        let (stream, continuation) = AsyncStream<PlayerBufferingStatus>.makeStream(bufferingPolicy: .bufferingNewest(8))
        feed = continuation
        return stream
    }

    private func forwardPipeline() {
        forwarder?.cancel()
        guard let operation else { return }
        pipelineFailed = false
        forwarder = Task { [weak self] in
            for await status in operation.statuses {
                guard let self, !Task.isCancelled else { return }
                self.feed?.yield(status.playerStatus)
                // Let the pick ("Found 14 releases · picked 1080p WEB-DL") be readable before connecting lines replace it.
                if status.phase == .choosing { try? await Task.sleep(for: .milliseconds(900)) }
            }
            guard let self, !Task.isCancelled else { return }
            guard let stream = try? await operation.stream() else {
                await self.markPipelineFailed()
                return
            }
            await self.streamStarted(stream)
        }
    }

    /// Attach-mode forwarding: like `forwardPipeline`, but a dead end (torrent gone, different
    /// content) falls back to a fresh search in the same window instead of failing.
    private func forwardAttach() {
        forwarder?.cancel()
        guard let operation else { return }
        pipelineFailed = false
        forwarder = Task { [weak self] in
            for await status in operation.statuses {
                guard let self, !Task.isCancelled else { return }
                self.feed?.yield(status.playerStatus)
            }
            guard let self, !Task.isCancelled else { return }
            if let stream = try? await operation.stream() {
                await self.streamStarted(stream, recordHistory: false)
            } else {
                self.beginPipeline()
                self.forwardPipeline()
            }
        }
    }

    private func markPipelineFailed() {
        pipelineFailed = true
    }

    private func streamStarted(_ stream: PlayStream, recordHistory: Bool = true) async {
        self.stream = stream
        await registerDownload(stream, recordHistory: recordHistory)
        observeCompletedFiles(from: stream)
        watchStream(stream)
    }

    /// Forwards a ready stream's buffering states into whatever feed is current (takeover
    /// swaps the feed under it, so this never needs restarting).
    private func watchStream(_ stream: PlayStream) {
        forwarder = Task { [weak self] in
            for await s in stream.control.statusUpdates() {
                guard let self, !Task.isCancelled else { return }
                if let mapped = s.playerStatus { self.feed?.yield(mapped) }
            }
        }
    }

    // MARK: Reuse

    /// True while this session is getting (or already serves) something to watch.
    var isLive: Bool { stream != nil || operation != nil }

    /// True when a stream URL is ready to show immediately.
    var hasReadyStream: Bool { stream != nil }

    /// Whether a new Play for `context` should reuse this session instead of searching again:
    /// the same movie, the same episode (even while still connecting), or a pack-mate of a
    /// ready season-pack stream (served via `advance(to:)` with no new search). A session whose
    /// search already failed is not reusable — the next Play must try again.
    func canServe(_ context: AppServices.PlayContext) -> Bool {
        guard isLive, !pipelineFailed || stream != nil, context.title.id == self.context.title.id else { return false }
        switch (self.context.current, context.current) {
        case (nil, nil):
            return true
        case let (have?, want?):
            if have.seasonNumber == want.seasonNumber, have.episodeNumber == want.episodeNumber { return true }
            if let stream, stream.release.isPack { return true }
            return false
        default:
            return false
        }
    }

    /// Takes over for a new Play of (usually) the same episode: brings the player window
    /// forward on the existing torrent. The pipeline/status loops always yield into the current
    /// feed, so swapping it via `present` is enough — no loop is restarted and no new search
    /// runs. Returns false when this session can't serve it, so the caller runs a fresh
    /// pipeline instead.
    func takeOver(with newContext: AppServices.PlayContext, startAt: Double?) async -> Bool {
        guard canServe(newContext) else { return false }
        let wantRef = newContext.current.map { EpisodeRef(season: $0.seasonNumber, episode: $0.episodeNumber) }
        if let stream {
            if let want = wantRef {
                if stream.episodes.contains(want) {
                    adopt(newContext)
                    present(source: .url(stream.url), startAt: startAt ?? 0, statuses: makeFeed())
                    await registerDownload(stream, recordHistory: false)
                    return true
                }
                if let handle = try? await stream.control.advance(to: want) {
                    let next = PlayStream(url: handle.url, episodes: handle.episodes, release: stream.release, control: stream.control)
                    self.stream = next
                    adopt(newContext)
                    present(source: .url(handle.url), startAt: startAt ?? 0, statuses: makeFeed())
                    await registerDownload(next, recordHistory: false)
                    return true
                }
                return false
            }
            adopt(newContext)
            present(source: .url(stream.url), startAt: startAt ?? 0, statuses: makeFeed())
            await registerDownload(stream, recordHistory: false)
            return true
        }
        // Still connecting: same episode only (canServe), so just adopt the resume point
        // and bring the in-flight operation's window forward. No new search.
        adopt(newContext)
        present(source: pipelineSource(), startAt: startAt ?? 0, statuses: makeFeed())
        return true
    }

    /// Adopts the library context of a reusing Play (title metadata, episode list, position).
    private func adopt(_ newContext: AppServices.PlayContext) {
        context.title = newContext.title
        context.episodes = newContext.episodes
        context.current = newContext.current
        context.startAt = newContext.startAt
    }

    private func registerDownload(_ stream: PlayStream, recordHistory: Bool = true) async {
        let title = context.title
        var progressIDs: [String] = []
        if let e = context.current {
            progressIDs = [AppServices.episodeKey(title.id, season: e.seasonNumber, episode: e.episodeNumber)]
        }
        let label = context.current.map { "\(title.title) · \(subtitle($0))" } ?? title.title
        await services.monitor.register(
            DownloadMonitor.Entry(
                id: stream.control.torrent, titleID: title.id, label: label, releaseName: stream.release.title,
                release: stream.release,
                progressIDs: progressIDs, startedAt: Date(), isStreamOnly: false),
            savePath: services.downloadFolder.path)
        if recordHistory {
            try? await services.history.append(HistoryEvent(
                type: .streamStarted, entityType: .torrent, entityId: stream.control.torrent.hex, titleId: title.id,
                payload: ["release": .string(stream.release.title), "grab": .string(stream.release.grabID.uuidString)]))
        }
        services.libraryChanged()
    }

    private func observeCompletedFiles(from stream: PlayStream) {
        importForwarder?.cancel()
        let events = stream.control.events()
        let services = self.services
        let context = self.context
        let savePath = services.downloadFolder.path
        importForwarder = Task {
            for await event in events {
                guard case .fileCompleted(let torrent, let index, let path, let refs) = event else { continue }
                let target: ImportTarget
                if context.title.kind == .movie, refs.contains(StreamContent.movieEpisode) {
                    target = .movie(titleID: context.title.id)
                } else if !refs.isEmpty {
                    target = .episodes(titleID: context.title.id, refs: refs)
                } else {
                    target = .unmapped
                }
                services.importCoordinator.handle(CompletedDownload(
                    infoHash: torrent.hex, savePath: savePath, releaseName: stream.release.title,
                    grabID: stream.release.grabID,
                    files: [CompletedFile(path: path, fileIndex: index, target: target)]))
            }
        }
    }

    // MARK: Player callbacks

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

    private func finished() {
        let id = playableID, titleID = context.title.id
        let services = self.services
        Task {
            try? await services.watchStates.setWatched(id: id, titleId: titleID, watched: true)
            services.libraryChanged()
        }
    }

    private func retry() {
        importForwarder?.cancel()
        stream = nil
        beginPipeline()
        forwardPipeline()
    }

    private func closed(position: Double) {
        generation += 1
        record(position: position, duration: nil)
        forwarder?.cancel()
        importForwarder?.cancel()
        feed?.finish()
        operation?.cancel()
        let stream = self.stream
        let services = self.services
        services.activePlaybacks.removeAll { $0 === self }
        Task {
            // A stream is just a download being watched: stop serving, keep downloading.
            await stream?.control.stop(removeTorrent: false)
            services.libraryChanged()
        }
    }

    // MARK: Switching episodes

    /// Up Next, Play Now, or an episode the viewer picked from the list: same window, new content.
    private func switchTo(episodeID: String) {
        guard let next = context.episodes.first(where: { $0.id.uuidString == episodeID }) else { return }
        let ref = EpisodeRef(season: next.seasonNumber, episode: next.episodeNumber)
        let previous = stream
        forwarder?.cancel()
        Task {
            let resume = AppServices.resume(try? await services.watchStates.state(for: next.id)) ?? 0
            context.current = next
            let statuses = makeFeed()
            if let previous, let handle = try? await previous.control.advance(to: ref) {
                // Same torrent (a season pack): no search, no buffering gap.
                stream = PlayStream(url: handle.url, episodes: handle.episodes, release: previous.release, control: previous.control)
                present(source: .url(handle.url), startAt: resume, statuses: statuses)
                if let feed {
                    let status = previous.control.statusUpdates()
                    forwarder = Task { for await s in status { if let mapped = s.playerStatus { feed.yield(mapped) } } }
                }
                await registerDownload(stream!)
                return
            }
            // Another torrent: release this one (it keeps downloading) and run the pipeline again.
            await previous?.control.stop(removeTorrent: false)
            stream = nil
            pipelineRequest.scope = scopeForSwitch(to: ref)
            pipelineRequest.episodeID = next.id
            beginPipeline()
            present(source: pipelineSource(), startAt: resume, statuses: statuses)
            forwardPipeline()
        }
    }

    private func scopeForSwitch(to ref: EpisodeRef) -> PlayScope {
        if case .season(let season, _) = pipelineRequest.scope, season == ref.season { return .season(season, startingAt: ref) }
        return .episode(ref)
    }
}
