import AppKit
import MarqueeUI

// MARK: - Entry point for the rest of the app
//
// `PlayerPresenter` is the single way to put something on screen in the player.
//
//     PlayerPresenter.shared.present(PlayerRequest(
//         title: "Harbor Lights",
//         subtitle: "S1 · E3 · Low Tide",
//         artwork: show.backdrop,
//         source: .deferred { try await pipeline.streamURL(for: episode) },   // or .url(fileURL)
//         startPosition: resumeSeconds,
//         statusUpdates: pipeline.bufferingStatus(for: episode),               // AsyncStream<PlayerBufferingStatus>
//         episodes: season.map(PlayerEpisode.init),                            // optional, enables Up Next
//         currentEpisodeID: episode.id,
//         onPositionChange: { position, duration in store.saveProgress(position, duration) },
//         onFinished: { store.markWatched(episode) },
//         onNextEpisode: { next in presenter.present(request(for: next)) },
//         onClose: { position in pipeline.release(episode) }))
//
// Behaviour contract:
// - One player window at a time. `present` while a player is open swaps the content in the same window
//   (keeps full screen), which is how Up Next chains episodes; the replaced request's `onClose` is NOT
//   called (the caller initiated the swap).
// - With a deferred source the window opens immediately in its pre-roll state (blurred artwork, title,
//   the status line from `statusUpdates`); the provider runs while that is on screen. A provider that
//   throws, or a `.failed` status, shows a plain message with Retry and Close; Retry calls `onRetry`
//   (if any) and runs the provider again.
// - All callbacks run on the main actor. `onPositionChange` is throttled to about 1 Hz while playing and
//   is also sent on pause, seek and close. `onFinished` fires once when the media reaches its end (or
//   Up Next is accepted). `onNextEpisode` receives the episode to play: the one after
//   `currentEpisodeID` for auto-advance / Play Now, or any episode the viewer picks from the episode
//   list. `onClose` fires when the viewer closes the window, with the last position.
// - Up Next needs `episodes` and a `currentEpisodeID` that is in the list with an episode after it.

/// Where the media comes from.
enum PlayerSource: Sendable {
    /// Ready now: a local file or an HTTP(S) URL (including a local stream server).
    case url(URL)
    /// Resolved after the window is on screen (search, add torrent, wait for the stream server...).
    case deferred(@Sendable () async throws -> URL)
}

/// Everything the player needs to start one playback.
struct PlayerRequest: Sendable {
    var title: String
    /// Secondary line, e.g. "S1 · E3 · Low Tide". Empty for movies.
    var subtitle: String
    var artwork: Artwork?
    var source: PlayerSource
    /// Seconds from the start; 0 starts at the beginning.
    var startPosition: TimeInterval
    /// Pipeline progress shown while nothing is playing yet. `nil` = the player derives a basic status itself.
    var statusUpdates: AsyncStream<PlayerBufferingStatus>?
    /// The season / list this episode belongs to, in play order. Empty for movies.
    var episodes: [PlayerEpisode]
    var currentEpisodeID: String?
    var onPositionChange: (@MainActor @Sendable (_ position: TimeInterval, _ duration: TimeInterval?) -> Void)?
    var onFinished: (@MainActor @Sendable () -> Void)?
    var onNextEpisode: (@MainActor @Sendable (_ episode: PlayerEpisode) -> Void)?
    var onRetry: (@MainActor @Sendable () -> Void)?
    var onClose: (@MainActor @Sendable (_ position: TimeInterval) -> Void)?

    init(
        title: String, subtitle: String = "", artwork: Artwork? = nil, source: PlayerSource, startPosition: TimeInterval = 0,
        statusUpdates: AsyncStream<PlayerBufferingStatus>? = nil, episodes: [PlayerEpisode] = [], currentEpisodeID: String? = nil,
        onPositionChange: (@MainActor @Sendable (TimeInterval, TimeInterval?) -> Void)? = nil,
        onFinished: (@MainActor @Sendable () -> Void)? = nil,
        onNextEpisode: (@MainActor @Sendable (PlayerEpisode) -> Void)? = nil,
        onRetry: (@MainActor @Sendable () -> Void)? = nil,
        onClose: (@MainActor @Sendable (TimeInterval) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.source = source
        self.startPosition = startPosition
        self.statusUpdates = statusUpdates
        self.episodes = episodes
        self.currentEpisodeID = currentEpisodeID
        self.onPositionChange = onPositionChange
        self.onFinished = onFinished
        self.onNextEpisode = onNextEpisode
        self.onRetry = onRetry
        self.onClose = onClose
    }

    /// The episode after `currentEpisodeID`, if any.
    var nextEpisode: PlayerEpisode? {
        guard let id = currentEpisodeID, let i = episodes.firstIndex(where: { $0.id == id }), i + 1 < episodes.count else { return nil }
        return episodes[i + 1]
    }
}

/// Opens, replaces and closes the player window.
@MainActor
final class PlayerPresenter {
    static let shared = PlayerPresenter()

    private var controller: PlayerWindowController?

    var isPresenting: Bool { controller != nil }

    func present(_ request: PlayerRequest) {
        let session = PlayerSession(request: request)
        if let controller {
            controller.replace(session: session)
        } else {
            let controller = PlayerWindowController(session: session)
            controller.onWindowClosed = { [weak self, weak controller] in
                if self?.controller === controller { self?.controller = nil }
            }
            self.controller = controller
            controller.show()
        }
    }

    /// Closes the player (no `onClose` callback; the caller asked for it).
    func dismiss() {
        controller?.close(notify: false)
    }
}
