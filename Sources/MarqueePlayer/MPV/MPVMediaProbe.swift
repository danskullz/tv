import Foundation
import MarqueeCore

/// Uses libmpv's headless demuxer to inspect containers AVFoundation doesn't open (notably Matroska).
public struct MPVMediaProbe: MediaProbing {
    public init() {}

    public func probe(_ url: URL, timeout: Duration) async throws -> MediaInfo {
        let cancellation = ProbeEngineCancellation()
        return try await withThrowingTaskGroup(of: MediaInfo.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await Self.inspect(url, cancellation: cancellation)
                } onCancel: {
                    cancellation.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MediaProbeError.timedOut
            }
            guard let result = try await group.next() else { throw MediaProbeError.invalidMedia }
            group.cancelAll()
            return result
        }
    }

    private static func inspect(_ url: URL, cancellation: ProbeEngineCancellation) async throws -> MediaInfo {
        var configuration = MPVPlaybackEngine.Configuration()
        configuration.headless = true
        configuration.nullAudio = true
        configuration.hwdec = "no"
        let engine = try MPVPlaybackEngine(configuration: configuration)
        cancellation.install(engine)
        defer {
            cancellation.clear()
            engine.shutdown()
        }
        try Task.checkCancellation()
        engine.load(url, startAt: nil)
        for await event in engine.events {
            switch event {
            case .state(.failed): throw MediaProbeError.invalidMedia
            case .state(.playing), .tracks, .duration:
                let snapshot = engine.snapshot
                let width = Int(engine.property("video-params/w") ?? "")
                let height = Int(engine.property("video-params/h") ?? "")
                guard let trackList = engine.property("track-list")?.data(using: .utf8),
                    let tracks = try? JSONSerialization.jsonObject(with: trackList) as? [[String: Any]],
                    let video = tracks.first(where: { $0["type"] as? String == "video" }),
                    let duration = snapshot.duration, duration > 0
                else { continue }
                let codec = (video["codec"] as? String) ?? (video["decoder"] as? String) ?? "unknown"
                let videoWidth = width ?? Self.int(video["demux-w"])
                let videoHeight = height ?? Self.int(video["demux-h"])
                guard let videoWidth, let videoHeight else { continue }
                let audio = snapshot.audioTracks.map {
                    MediaInfo.AudioTrack(codec: $0.codec ?? "unknown", channels: $0.channelCount, language: $0.language)
                }
                return MediaInfo(
                    durationSeconds: duration, container: url.pathExtension.lowercased(), videoCodec: codec,
                    width: videoWidth, height: videoHeight, audioTracks: audio)
            default:
                continue
            }
        }
        try Task.checkCancellation()
        throw MediaProbeError.invalidMedia
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value.rounded()) }
        return nil
    }
}

private final class ProbeEngineCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: MPVPlaybackEngine?
    private var cancelled = false

    func install(_ engine: MPVPlaybackEngine) {
        lock.lock()
        self.engine = engine
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { engine.shutdown() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let engine = self.engine
        lock.unlock()
        engine?.shutdown()
    }

    func clear() {
        lock.lock()
        engine = nil
        lock.unlock()
    }
}
