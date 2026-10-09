import AppKit
import IOKit.pwr_mgt
import MarqueeUI
import MediaPlayer

/// Keeps the display awake while video plays. Taken on play, released on pause, end and close.
@MainActor
final class DisplaySleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    func setActive(_ active: Bool, reason: String) {
        guard active != isHeld else { return }
        if active {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Marquee is playing \(reason)" as CFString, &id)
            if result == kIOReturnSuccess { assertionID = id; isHeld = true }
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isHeld = false
        }
    }

    deinit {
        // `isHeld` is only touched on the main actor; a leaked assertion would outlive the player, so release defensively.
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}

/// Media keys, Control Center and Now Playing. Registered while a player is open, removed on close.
/// File scope is nonisolated, so the artwork handler below stays nonisolated too.
private func makeNowPlayingArtwork(from image: CGImage) -> MPMediaItemArtwork {
    let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    return MPMediaItemArtwork(boundsSize: ns.size) { _ in ns }
}

@MainActor
final class NowPlayingBridge {
    private final class WeakSession: @unchecked Sendable {
        weak var session: PlayerSession?
    }

    private var registrations: [(command: MPRemoteCommand, token: Any)] = []
    private let box = WeakSession()
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var isAttached = false

    func attach(to session: PlayerSession) {
        guard !isAttached else { return }
        isAttached = true
        box.session = session
        let center = MPRemoteCommandCenter.shared()
        let box = self.box

        func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerSession, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { event in
                nonisolated(unsafe) let event = event
                Task { @MainActor in
                    if let session = box.session { action(session, event) }
                }
                return .success
            }
            registrations.append((command, token))
        }
        register(center.playCommand) { s, _ in s.engine?.play(); s.userActivity() }
        register(center.pauseCommand) { s, _ in s.engine?.pause() }
        register(center.togglePlayPauseCommand) { s, _ in s.togglePlayPause() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        register(center.skipForwardCommand) { s, _ in s.skip(by: 10) }
        register(center.skipBackwardCommand) { s, _ in s.skip(by: -10) }
        register(center.changePlaybackPositionCommand) { s, event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { s.seek(to: e.positionTime) }
        }
        register(center.nextTrackCommand) { s, _ in s.playNext() }
        center.nextTrackCommand.isEnabled = session.nextEpisode != nil
        for command in [center.previousTrackCommand, center.seekForwardCommand, center.seekBackwardCommand] { command.isEnabled = false }

        if let url = session.request.artwork?.url {
            artworkTask = Task.detached { [weak self] in
                guard let image = await ImagePipeline.shared.image(for: url, pixelSize: CGSize(width: 600, height: 600)),
                      !Task.isCancelled else { return }
                // Built off the main actor on purpose: MediaPlayer invokes the request handler
                // on its own queue, and a main-actor-isolated closure traps there (SIGILL).
                nonisolated(unsafe) let artwork = makeNowPlayingArtwork(from: image)
                await MainActor.run { [weak self] in
                    guard let self, self.isAttached else { return }
                    self.artwork = artwork
                    if let session = self.box.session { self.refresh(from: session) }
                }
            }
        }
    }

    func refresh(from session: PlayerSession, elapsedOverride: TimeInterval? = nil) {
        guard isAttached else { return }
        let s = session.snapshot
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.request.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedOverride ?? s.position,
            MPNowPlayingInfoPropertyPlaybackRate: s.state == .playing ? s.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if !session.request.subtitle.isEmpty { info[MPMediaItemPropertyArtist] = session.request.subtitle }
        if let duration = s.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = switch s.state {
        case .playing: .playing
        case .paused: .paused
        case .ended: .stopped
        case .idle: .stopped
        default: .playing
        }
    }

    func detach() {
        guard isAttached else { return }
        isAttached = false
        artworkTask?.cancel()
        for (command, token) in registrations {
            command.removeTarget(token)
            command.isEnabled = false
        }
        registrations.removeAll()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
