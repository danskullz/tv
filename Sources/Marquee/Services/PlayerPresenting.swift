import AppKit
import MarqueePlayer
import SwiftUI

// The only file that knows how a player window is shown. The app talks to `PlayerPresenting`; the
// temporary implementation below opens a bare libmpv window. When the real player window lands
// (`PlayerPresenter.present(PlayerRequest)`), replace `TemporaryPlayerPresenter` with an adapter that
// maps `PlayerSessionRequest` onto `PlayerRequest` and nothing else changes.

/// "Up next" offered when an episode ends.
struct UpNextOffer {
    var title: String
    var play: @MainActor () -> Void
}

/// Everything the player needs to open, play, and report back.
struct PlayerSessionRequest {
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var startAt: TimeInterval?
    /// Resolves when the stream is ready; throws a plain-language error if it never will be.
    var urlProvider: @Sendable () async throws -> URL
    /// Plain-language progress lines while the stream starts and buffers ("Searching 3 indexers…").
    var statusLines: AsyncStream<String>
    /// Playback position and duration in seconds, a few times a minute.
    var onProgress: @MainActor (Double, Double?) -> Void
    /// The media finished. May offer the next episode.
    var onEnded: @MainActor () async -> UpNextOffer?
    /// The player window closed.
    var onClose: @MainActor () -> Void
}

@MainActor
protocol PlayerPresenting: AnyObject {
    func present(_ request: PlayerSessionRequest)
}

// MARK: - Temporary implementation

@MainActor
final class TemporaryPlayerPresenter: PlayerPresenting {
    private var windows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []

    func present(_ request: PlayerSessionRequest) {
        let model = TemporaryPlayerModel(request)
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: TemporaryPlayerView(model: model)))
        window.title = request.title
        window.subtitle = request.subtitle ?? ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 540))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                model.shutdown()
                request.onClose()
                if let window { self?.windows.removeAll { $0 === window } }
            }
        }
        observers.append(token)
    }
}

@MainActor
@Observable
final class TemporaryPlayerModel {
    private(set) var engine: MPVPlaybackEngine?
    private(set) var viewModel: PlaybackViewModel?
    private(set) var statusLine = ""
    private(set) var failure: String?
    private(set) var upNext: UpNextOffer?
    private let request: PlayerSessionRequest
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastReported = -100.0
    @ObservationIgnored private var didEnd = false

    init(_ request: PlayerSessionRequest) {
        self.request = request
        tasks.append(Task { [weak self] in
            guard let lines = self?.request.statusLines else { return }
            for await line in lines { self?.statusLine = line }
        })
        tasks.append(Task { [weak self] in await self?.open() })
    }

    private func open() async {
        do {
            let url = try await request.urlProvider()
            let engine = try MPVPlaybackEngine(configuration: MPVPlaybackEngine.Configuration())
            self.engine = engine
            viewModel = PlaybackViewModel(engine: engine)
            engine.load(url, startAt: request.startAt)
        } catch let error as LocalizedError where error.errorDescription != nil {
            failure = error.errorDescription
        } catch is CancellationError {
        } catch {
            failure = "This couldn't be played right now. Try again in a moment."
        }
    }

    /// Called by the view as the playback snapshot changes.
    func snapshotChanged() {
        guard let s = viewModel?.snapshot else { return }
        if abs(s.position - lastReported) >= 5 {
            lastReported = s.position
            request.onProgress(s.position, s.duration)
        }
        if s.state == .ended, !didEnd {
            didEnd = true
            request.onProgress(s.duration ?? s.position, s.duration)
            Task { [weak self] in
                guard let self else { return }
                upNext = await request.onEnded()
            }
        }
    }

    func shutdown() {
        if let s = viewModel?.snapshot, s.position > 0, !didEnd { request.onProgress(s.position, s.duration) }
        tasks.forEach { $0.cancel() }
        engine?.shutdown()
        engine = nil
    }
}

private struct TemporaryPlayerView: View {
    let model: TemporaryPlayerModel

    var body: some View {
        ZStack {
            Color.black
            if let engine = model.engine { MPVPlayerView(engine: engine) }
            overlay
        }
        .frame(minWidth: 640, minHeight: 360)
        .onKeyPress(.space) {
            model.engine?.togglePause()
            return .handled
        }
        .onChange(of: model.viewModel?.snapshot) { _, _ in model.snapshotChanged() }
    }

    @ViewBuilder
    private var overlay: some View {
        if let failure = model.failure {
            message(failure, systemImage: "exclamationmark.triangle")
        } else if let next = model.upNext {
            VStack(spacing: 12) {
                Text("Up next").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: next.title).font(.title2.weight(.semibold))
                Button("Play Next Episode") { next.play() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if showsStatus {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text(verbatim: model.statusLine.isEmpty ? String(localized: "Starting…") : model.statusLine)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(22)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var showsStatus: Bool {
        guard let state = model.viewModel?.snapshot.state else { return true }
        switch state {
        case .idle, .loading, .buffering: return true
        default: return false
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(verbatim: text).font(.headline).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 420)
    }
}
