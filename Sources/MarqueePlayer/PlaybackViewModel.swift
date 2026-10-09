import Foundation
import Observation

/// `@Observable` mirror of a `PlaybackEngine` for SwiftUI. Consumes the engine's event stream, so
/// it does no work while nothing changes.
@MainActor @Observable
public final class PlaybackViewModel {
    public private(set) var snapshot: PlaybackSnapshot
    public let engine: any PlaybackEngine
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(engine: any PlaybackEngine) {
        self.engine = engine
        self.snapshot = engine.snapshot
        let stream = engine.events
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    deinit { task?.cancel() }

    private func apply(_ event: PlaybackEvent) {
        switch event {
        case .state(let s): snapshot.state = s
        case .position(let p): snapshot.position = p
        case .duration(let d): snapshot.duration = d
        case .bufferedAhead(let b): snapshot.bufferedAhead = b
        case .tracks(let audio, let subtitle, let selA, let selS):
            snapshot.audioTracks = audio; snapshot.subtitleTracks = subtitle
            snapshot.selectedAudioTrack = selA; snapshot.selectedSubtitleTrack = selS
        case .volume(let v): snapshot.volume = v
        case .speed(let s): snapshot.speed = s
        case .seekable(let s): snapshot.isSeekable = s
        }
    }
}
