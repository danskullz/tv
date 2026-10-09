import AppKit
import Foundation
import MarqueePlayer
import MarqueeUI
import Observation

/// One playback inside the player window: owns the engine, mirrors its state for the views, and drives
/// everything that is not drawing (loading, keyboard, overlay visibility, progress reports, Up Next,
/// Now Playing, sleep assertion). Event driven: the only timers are the 2.5 s overlay auto-hide, the
/// 1.4 s HUD toast, and a 1 Hz refresh while the stats overlay is open.
@MainActor @Observable
final class PlayerSession: Identifiable {
    struct HUD: Equatable {
        var id = UUID()
        var text: String
        var symbol: String?
    }

    let id = UUID()
    let request: PlayerRequest

    // Engine
    private(set) var engine: MPVPlaybackEngine?
    private(set) var model: PlaybackViewModel?

    // Loading
    private(set) var failureMessage: String?
    private(set) var pipelineStatus: PlayerBufferingStatus?
    /// True from the first moment the engine reports playing/paused; drives the pre-roll → video hand-off.
    private(set) var hasStartedPlaying = false

    // Overlay
    private(set) var controlsVisible = true
    private(set) var hud: HUD?
    var showStats = false { didSet { statsToggled() } }
    private(set) var stats = PlaybackStats()
    private(set) var isMuted = false
    private(set) var subtitleDelay: TimeInterval = 0
    var isFullScreen = false

    // Up Next
    private(set) var upNextVisible = false
    private(set) var upNextSeconds = 0
    private(set) var upNextCancelled = false

    // Hooks installed by the window controller.
    @ObservationIgnored var toggleFullScreen: () -> Void = {}
    @ObservationIgnored var requestClose: () -> Void = {}
    @ObservationIgnored var controlsVisibilityChanged: (Bool) -> Void = { _ in }

    // Interaction state that gates auto-hide.
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var isHoveringControls = false
    @ObservationIgnored private var menuDepth = 0
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastReportedPosition: TimeInterval = -10
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private let sleepAssertion = DisplaySleepAssertion()
    @ObservationIgnored private let nowPlaying = NowPlayingBridge()

    private static let hideDelay: Duration = .milliseconds(2500)
    private static let volumeKey = "player.volume"

    init(request: PlayerRequest) {
        self.request = request
        do {
            var config = MPVPlaybackEngine.Configuration()
            for pair in (ProcessInfo.processInfo.environment["MARQUEE_MPV_OPTIONS"] ?? "").split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { config.extraOptions[kv[0]] = kv[1] }
            }
            let engine = try MPVPlaybackEngine(configuration: config)
            self.engine = engine
            let model = PlaybackViewModel(engine: engine)
            model.eventHandler = { [weak self] event in self?.handle(event) }
            self.model = model
            engine.setSubtitlesRaised(true)
            if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double { engine.setVolume(saved) }
        } catch {
            failureMessage = String(localized: "The video player couldn't start. Reinstalling Marquee should fix this.")
        }
        nowPlaying.attach(to: self)
        startConsumingStatus()
        startLoading()
    }

    // MARK: Derived

    var snapshot: PlaybackSnapshot { model?.snapshot ?? PlaybackSnapshot() }
    var nextEpisode: PlayerEpisode? { request.nextEpisode }
    var isPlaying: Bool { snapshot.state == .playing }
    var isSeekable: Bool { snapshot.isSeekable && (snapshot.duration ?? 0) > 0 }

    /// What the pre-roll says. Truthful: the pipeline's own status when there is one, otherwise what the engine knows.
    var prerollStatusLine: String {
        if let pipelineStatus { return pipelineStatus.statusLine }
        let s = snapshot
        if let ahead = s.bufferedAhead, ahead >= 1, s.state == .buffering { return PlayerBufferingStatus.buffering(secondsAhead: ahead).statusLine }
        return PlayerBufferingStatus.ready.statusLine
    }

    /// Shown over live video when playback stalls mid-stream.
    var stallLine: String? {
        guard hasStartedPlaying, failureMessage == nil else { return nil }
        if let pipelineStatus, pipelineStatus.isStalled { return pipelineStatus.statusLine }
        guard snapshot.state == .buffering else { return nil }
        if case .buffering(let ahead)? = pipelineStatus { return PlayerBufferingStatus.buffering(secondsAhead: ahead).statusLine }
        return PlayerBufferingStatus.buffering(secondsAhead: 0).statusLine
    }

    var showsPreroll: Bool { !hasStartedPlaying || failureMessage != nil }

    // MARK: Loading

    private func startConsumingStatus() {
        guard let stream = request.statusUpdates else { return }
        statusTask = Task { [weak self] in
            for await status in stream {
                guard let self, !self.isClosed else { return }
                self.pipelineStatus = status
                if let message = status.failureMessage { self.failureMessage = message }
            }
        }
    }

    private func startLoading() {
        guard let engine else { return }
        loadTask?.cancel()
        let source = request.source
        let start = request.startPosition
        loadTask = Task { [weak self] in
            do {
                let url: URL
                switch source {
                case .url(let u): url = u
                case .deferred(let provider): url = try await provider()
                }
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                engine.load(url, startAt: start > 0 ? start : nil)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isClosed else { return }
                self.failureMessage = Self.plainMessage(for: error)
            }
        }
    }

    private static func plainMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty { return text }
        return String(localized: "This video couldn't be prepared. You can try again.")
    }

    func retry() {
        failureMessage = nil
        pipelineStatus = nil
        hasStartedPlaying = false
        didFinish = false
        request.onRetry?()
        engine?.stop()
        startLoading()
    }

    /// Debug/test hook: shows an arbitrary failure.
    func simulateFailure(_ message: String) { failureMessage = message }

    // MARK: Engine events

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .state(let state):
            switch state {
            case .playing, .paused: hasStartedPlaying = true
            case .ended: hasStartedPlaying = true
            case .failed(let message): failureMessage = message
            default: break
            }
            if state == .playing { failureMessage = nil }
            sleepAssertion.setActive(state == .playing, reason: request.title)
            nowPlaying.refresh(from: self)
            if state == .paused || state == .ended { showControls(autoHide: false) } else if state == .playing { scheduleHide() }
            if state == .paused { reportPosition(force: true) }
            if state == .ended { playbackEnded() }
        case .position(let position):
            reportPosition(force: false, position: position)
            updateUpNext(position: position)
        case .duration:
            updateUpNext(position: snapshot.position)
            nowPlaying.refresh(from: self)
        case .tracks: break
        case .speed, .volume, .bufferedAhead, .seekable: break
        }
    }

    private func reportPosition(force: Bool, position: TimeInterval? = nil) {
        let p = position ?? snapshot.position
        guard hasStartedPlaying, force || abs(p - lastReportedPosition) >= 1 else { return }
        lastReportedPosition = p
        request.onPositionChange?(p, snapshot.duration)
    }

    private func updateUpNext(position: TimeInterval) {
        guard nextEpisode != nil, !upNextCancelled, let duration = snapshot.duration, duration > 120 else {
            if upNextVisible { upNextVisible = false }
            return
        }
        let remaining = duration - position
        let visible = remaining <= 30 && remaining > 0 && failureMessage == nil
        if visible != upNextVisible { withMotion(Tokens.Motion.smooth) { upNextVisible = visible } }
        if visible {
            let seconds = Int(remaining.rounded(.up))
            if seconds != upNextSeconds { upNextSeconds = seconds }
        }
    }

    private func playbackEnded() {
        guard !didFinish else { return }
        didFinish = true
        reportPosition(force: true, position: snapshot.duration ?? snapshot.position)
        request.onFinished?()
        if !upNextCancelled, let next = nextEpisode { request.onNextEpisode?(next) }
    }

    // MARK: Transport

    func togglePlayPause() {
        engine?.togglePause()
        userActivity()
    }

    func skip(by seconds: TimeInterval) {
        guard isSeekable else { return }
        engine?.seek(by: seconds)
        let target = min(max(0, snapshot.position + seconds), snapshot.duration ?? .infinity)
        showHUD(seconds > 0 ? "+\(Int(seconds)) s" : "\u{2212}\(Int(-seconds)) s", symbol: seconds > 0 ? "goforward" : "gobackward")
        reportPosition(force: true, position: target)
        nowPlaying.refresh(from: self)
        userActivity()
    }

    func seek(to seconds: TimeInterval) {
        guard isSeekable else { return }
        engine?.seek(to: seconds)
        reportPosition(force: true, position: seconds)
        nowPlaying.refresh(from: self, elapsedOverride: seconds)
        userActivity()
    }

    func scrubbingChanged(_ scrubbing: Bool) {
        isScrubbing = scrubbing
        if scrubbing { showControls(autoHide: false) } else { scheduleHide() }
    }

    func setVolume(_ volume: Double, announce: Bool = false) {
        let v = min(1, max(0, volume))
        engine?.setVolume(v)
        UserDefaults.standard.set(v, forKey: Self.volumeKey)
        if isMuted && v > 0 { setMuted(false, announce: false) }
        if announce { showHUD(String(localized: "Volume \(Formatters.percent(v))"), symbol: v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }
        userActivity()
    }

    func nudgeVolume(_ delta: Double) { setVolume((isMuted ? 0 : snapshot.volume) + delta, announce: true) }

    func toggleMute() { setMuted(!isMuted, announce: true) }

    private func setMuted(_ muted: Bool, announce: Bool) {
        isMuted = muted
        engine?.setMuted(muted)
        if announce { showHUD(muted ? String(localized: "Muted") : String(localized: "Volume \(Formatters.percent(snapshot.volume))"),
                              symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
        userActivity()
    }

    func setSpeed(_ speed: Double) {
        engine?.setSpeed(speed)
        showHUD(String(localized: "Speed \(speed.formatted(.number.precision(.fractionLength(0...2))))×"), symbol: "speedometer")
        userActivity()
    }

    func selectAudio(_ id: Int?) {
        engine?.selectAudioTrack(id)
        userActivity()
    }

    func selectSubtitle(_ id: Int?) {
        engine?.selectSubtitleTrack(id)
        userActivity()
    }

    func cycleAudio() {
        let s = snapshot
        guard let next = TrackCycling.nextAudio(in: s.audioTracks, after: s.selectedAudioTrack),
              let track = s.audioTracks.first(where: { $0.id == next }) else { return }
        engine?.selectAudioTrack(next)
        showHUD(track.menuTitle(), symbol: "waveform")
        userActivity()
    }

    func cycleSubtitles() {
        let s = snapshot
        guard let next = TrackCycling.nextSubtitle(in: s.subtitleTracks, after: s.selectedSubtitleTrack) else {
            showHUD(String(localized: "No subtitles available"), symbol: "captions.bubble")
            return
        }
        engine?.selectSubtitleTrack(next)
        if let id = next, let track = s.subtitleTracks.first(where: { $0.id == id }) {
            showHUD(String(localized: "Subtitles: \(track.displayName())"), symbol: "captions.bubble.fill")
        } else {
            showHUD(String(localized: "Subtitles off"), symbol: "captions.bubble")
        }
        userActivity()
    }

    func nudgeSubtitleDelay(_ delta: TimeInterval) {
        subtitleDelay = delta == 0 ? 0 : SubtitleDelay.adjusted(subtitleDelay, by: delta)
        engine?.setSubtitleDelay(subtitleDelay)
        showHUD(String(localized: "Subtitle delay \(SubtitleDelay.label(subtitleDelay))"), symbol: "captions.bubble")
        userActivity()
    }

    // MARK: Up Next

    func playNext() {
        guard let next = nextEpisode else { return }
        guard !didFinish else { return }
        didFinish = true
        reportPosition(force: true, position: snapshot.duration ?? snapshot.position)
        request.onFinished?()
        request.onNextEpisode?(next)
    }

    func play(episode: PlayerEpisode) {
        request.onNextEpisode?(episode)
    }

    func cancelUpNext() {
        withMotion(Tokens.Motion.smooth) {
            upNextCancelled = true
            upNextVisible = false
        }
    }

    // MARK: Keyboard

    /// Returns true when the key was consumed. Called from the window before normal dispatch.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !isClosed else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
            toggleFullScreen()
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlayPause()
        case 123: skip(by: shift ? -60 : -10)
        case 124: skip(by: shift ? 60 : 10)
        case 126: nudgeVolume(0.05)
        case 125: nudgeVolume(-0.05)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m": toggleMute()
            case "f": toggleFullScreen()
            case "s": cycleSubtitles()
            case "a": cycleAudio()
            case "i": showStats.toggle(); userActivity()
            case "[": nudgeSubtitleDelay(-SubtitleDelay.step)
            case "]": nudgeSubtitleDelay(SubtitleDelay.step)
            case "\\": nudgeSubtitleDelay(0)
            case "k": togglePlayPause()
            default: return false
            }
        }
        return true
    }

    // MARK: Overlay visibility

    /// Pointer moved or a key was pressed: show the controls and (re)arm the auto-hide.
    func userActivity() {
        showControls(autoHide: true)
    }

    func controlsHoverChanged(_ hovering: Bool) {
        isHoveringControls = hovering
        if hovering { showControls(autoHide: false) } else { scheduleHide() }
    }

    func menuTrackingChanged(_ tracking: Bool) {
        menuDepth = max(0, menuDepth + (tracking ? 1 : -1))
        if tracking { showControls(autoHide: false) } else { scheduleHide() }
    }

    private func showControls(autoHide: Bool) {
        if !controlsVisible {
            withMotion(Tokens.Motion.fade) { controlsVisible = true }
            engine?.setSubtitlesRaised(true)
            controlsVisibilityChanged(true)
        }
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private var canAutoHide: Bool {
        hasStartedPlaying && failureMessage == nil && snapshot.state != .paused && snapshot.state != .ended
            && !isScrubbing && !isHoveringControls && menuDepth == 0 && !NSWorkspace.shared.isVoiceOverEnabled
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard canAutoHide else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, let self, self.canAutoHide else { return }
            withMotion(Tokens.Motion.smooth) { self.controlsVisible = false }
            self.engine?.setSubtitlesRaised(false)
            self.controlsVisibilityChanged(false)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: HUD & stats

    func showHUD(_ text: String, symbol: String? = nil) {
        hudTask?.cancel()
        withMotion(Tokens.Motion.fade) { hud = HUD(text: text, symbol: symbol) }
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, let self else { return }
            withMotion(Tokens.Motion.fade) { self.hud = nil }
        }
    }

    private func statsToggled() {
        statsTask?.cancel()
        guard showStats else { return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine else { return }
                self.stats = engine.stats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Teardown

    func shutdown(notifyClose: Bool) {
        guard !isClosed else { return }
        isClosed = true
        let position = snapshot.position
        if hasStartedPlaying, !didFinish { request.onPositionChange?(position, snapshot.duration) }
        loadTask?.cancel(); statusTask?.cancel(); hideTask?.cancel(); hudTask?.cancel(); statsTask?.cancel()
        sleepAssertion.setActive(false, reason: request.title)
        nowPlaying.detach()
        model?.eventHandler = nil
        engine?.shutdown()
        if notifyClose { request.onClose?(position) }
    }
}
