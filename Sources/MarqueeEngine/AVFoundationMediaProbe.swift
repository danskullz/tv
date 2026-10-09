import AVFoundation
import CoreMedia
import Foundation
import MarqueeCore

/// Media probing in the engine keeps the UI-free core independent from the player implementation.
public struct AVFoundationMediaProbe: MediaProbing {
    public init() {}

    public func probe(_ url: URL, timeout: Duration = .seconds(30)) async throws -> MediaInfo {
        try await withThrowingTaskGroup(of: MediaInfo.self) { group in
            group.addTask { try await Self.read(url) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MediaProbeError.timedOut
            }
            guard let result = try await group.next() else { throw MediaProbeError.invalidMedia }
            group.cancelAll()
            return result
        }
    }

    private static func read(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.load(.tracks)
        var videoCodec: String?
        var width: Int?
        var height: Int?
        var audioTracks: [MediaInfo.AudioTrack] = []

        for track in tracks {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let codec = Self.fourCC(CMFormatDescriptionGetMediaSubType(format))
            switch track.mediaType {
            case .video:
                if videoCodec == nil {
                    videoCodec = codec
                    let size = try await track.load(.naturalSize)
                    width = Int(abs(size.width).rounded())
                    height = Int(abs(size.height).rounded())
                }
            case .audio:
                let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame
                audioTracks.append(MediaInfo.AudioTrack(codec: codec, channels: channels.map(Int.init)))
            default: continue
            }
        }
        guard videoCodec != nil else { throw MediaProbeError.missingVideo }
        guard duration.isFinite, duration > 0 else { throw MediaProbeError.missingDuration }
        return MediaInfo(
            durationSeconds: duration, container: url.pathExtension.lowercased(), videoCodec: videoCodec,
            width: width, height: height, audioTracks: audioTracks)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }
}
