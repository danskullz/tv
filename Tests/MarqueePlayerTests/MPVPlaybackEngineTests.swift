import AVFoundation
import Foundation
import Testing
@testable import MarqueePlayer

/// Polls the engine's snapshot (test-side only; the engine itself never polls).
private func playerAwait(_ engine: some PlaybackEngine, timeout: Duration = .seconds(15),
                         _ predicate: @Sendable (PlaybackSnapshot) -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate(engine.snapshot) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return predicate(engine.snapshot)
}

private func playerMakeHeadlessEngine() throws -> MPVPlaybackEngine {
    var config = MPVPlaybackEngine.Configuration()
    config.headless = true
    config.hwdec = "no"
    return try MPVPlaybackEngine(configuration: config)
}

@Suite(.enabled(if: MPVLibrary.shared != nil, "libmpv not built; run scripts/build-mpv.sh"))
struct MPVPlaybackEngineTests {
    @Test func testClipIsValidH264AndAAC() async throws {
        let url = try await PlayerTestClip.url()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - PlayerTestClip.duration) < 0.2)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func libraryIsLGPLBuildWithMatchingAPIVersion() throws {
        let api = try #require(MPVLibrary.shared)
        #expect(api.clientAPIVersion() >> 16 == 2)  // CLIENT_API major
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        let configuration = engine.property("mpv-configuration") ?? ""
        #expect(configuration.contains("-Dgpl=false"), "mpv-configuration: \(configuration)")
    }

    @Test func loadsPlaysAndReportsDuration() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }

        #expect(engine.snapshot.state == .idle)
        engine.load(url)

        #expect(await playerAwait(engine) { $0.state == .playing })
        #expect(await playerAwait(engine) { ($0.duration ?? 0) > 2.5 })
        // mpv publishes `seekable` a beat after playback starts; wait for it rather than racing it.
        #expect(await playerAwait(engine) { $0.isSeekable })
        let snapshot = engine.snapshot
        #expect(abs((snapshot.duration ?? 0) - PlayerTestClip.duration) < 0.3)

        // Time advances on its own.
        let start = snapshot.position
        #expect(await playerAwait(engine) { $0.position > start + 0.4 })
    }

    @Test func listsAndSelectsTracks() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(url)

        #expect(await playerAwait(engine) { !$0.audioTracks.isEmpty })
        let audio = try #require(engine.snapshot.audioTracks.first)
        #expect(audio.kind == .audio)
        #expect(audio.codec == "aac")
        #expect(audio.channelCount == 2)
        #expect(await playerAwait(engine) { $0.selectedAudioTrack == audio.id })
        #expect(engine.snapshot.subtitleTracks.isEmpty)

        engine.selectAudioTrack(nil)
        #expect(await playerAwait(engine) { $0.selectedAudioTrack == nil })
        engine.selectAudioTrack(audio.id)
        #expect(await playerAwait(engine) { $0.selectedAudioTrack == audio.id })
    }

    @Test func pausesResumesAndSeeks() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(url)
        #expect(await playerAwait(engine) { $0.state == .playing })

        engine.pause()
        #expect(await playerAwait(engine) { $0.state == .paused })

        engine.seek(to: 1.5)
        #expect(await playerAwait(engine) { abs($0.position - 1.5) < 0.1 })
        #expect(engine.snapshot.state == .paused)

        engine.seek(by: -1.0)
        #expect(await playerAwait(engine) { abs($0.position - 0.5) < 0.1 })

        engine.play()
        #expect(await playerAwait(engine) { $0.state == .playing })
        let resumedFrom = engine.snapshot.position
        #expect(await playerAwait(engine) { $0.position > resumedFrom + 0.3 })
    }

    @Test func playsToTheEnd() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(url, startAt: 2.2)
        #expect(await playerAwait(engine) { $0.state == .ended })
        #expect(engine.snapshot.position > 2.7)
    }

    @Test func volumeAndSpeed() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(url)
        #expect(await playerAwait(engine) { $0.state == .playing })

        engine.setVolume(0.4)
        #expect(await playerAwait(engine) { abs($0.volume - 0.4) < 0.01 })
        engine.setSpeed(2)
        #expect(await playerAwait(engine) { $0.speed == 2 })
    }

    @Test func eventStreamReportsStateAndFinishesOnShutdown() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        engine.load(url)

        var sawLoadingOrPlaying = false
        var positions: [TimeInterval] = []
        var sawDuration = false
        for await event in engine.events {
            switch event {
            case .state(.playing): sawLoadingOrPlaying = true
            case .position(let p): positions.append(p)
            case .duration(let d) where d != nil: sawDuration = true
            default: break
            }
            if positions.count >= 3 && sawLoadingOrPlaying && sawDuration { engine.shutdown() }
        }
        // The stream ended because shutdown() finished it.
        #expect(sawLoadingOrPlaying && sawDuration)
        // Coalesced: ≥ 0.25 s apart, so at most ~4/s even though mpv reports every frame.
        for (a, b) in zip(positions, positions.dropFirst()) where b > a { #expect(b - a >= 0.24) }
    }

    @Test func missingFileFailsWithPlainLanguage() async throws {
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(URL(fileURLWithPath: "/nonexistent/marquee-missing-file.mkv"))
        #expect(await playerAwait(engine) { if case .failed = $0.state { true } else { false } })
        guard case .failed(let message) = engine.snapshot.state else { return }
        #expect(!message.isEmpty)
        #expect(!message.contains("MPV_ERROR"))
    }

    @Test func stopReturnsToIdle() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(url)
        #expect(await playerAwait(engine) { $0.state == .playing })
        engine.stop()
        #expect(await playerAwait(engine) { $0.state == .idle })
    }

    @Test func reloadReplacesCurrentFile() async throws {
        let url = try await PlayerTestClip.url()
        let engine = try playerMakeHeadlessEngine()
        defer { engine.shutdown() }
        engine.load(url)
        #expect(await playerAwait(engine) { $0.position > 0.5 })
        engine.load(url)
        #expect(await playerAwait(engine) { $0.state == .playing && $0.position < 0.5 })
    }
}
