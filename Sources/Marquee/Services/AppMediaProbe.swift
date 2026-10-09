import Foundation
import MarqueeCore
import MarqueeEngine
import MarqueePlayer

/// Selects the system demuxer for QuickTime containers and headless mpv for the rest (MKV, AVI, ...).
struct AppMediaProbe: MediaProbing {
    private let avFoundation = AVFoundationMediaProbe()
    private let mpv = MPVMediaProbe()

    func probe(_ url: URL, timeout: Duration) async throws -> MediaInfo {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": try await avFoundation.probe(url, timeout: timeout)
        default: try await mpv.probe(url, timeout: timeout)
        }
    }
}
