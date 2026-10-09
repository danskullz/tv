import Foundation

/// Reads media metadata without executing or otherwise opening a downloaded file as a program.
public protocol MediaProbing: Sendable {
    func probe(_ url: URL, timeout: Duration) async throws -> MediaInfo
}

public enum MediaProbeError: Error, Sendable, Equatable {
    case timedOut
    case invalidMedia
    case missingVideo
    case missingDuration
    case tooShort(actual: Double, expected: Double)
    case codecMismatch(claimed: String, actual: String)
}

public enum MediaProbeValidation {
    /// Rejects containers with no video, missing duration, or a duration far below metadata's runtime.
    public static func validate(
        _ info: MediaInfo, expectedRuntimeSeconds: Double?, minimumDurationSeconds: Double = 30,
        runtimeTolerance: Double = 0.5
    ) throws {
        guard let duration = info.durationSeconds, duration.isFinite, duration > 0 else {
            throw MediaProbeError.missingDuration
        }
        guard info.videoCodec != nil, (info.width ?? 0) > 0, (info.height ?? 0) > 0 else {
            throw MediaProbeError.missingVideo
        }
        let minimum = max(minimumDurationSeconds, (expectedRuntimeSeconds ?? 0) * (1 - runtimeTolerance))
        guard duration >= minimum else { throw MediaProbeError.tooShort(actual: duration, expected: minimum) }
    }

    public static func validateCodecClaim(_ claimed: VideoCodec?, against actual: String?) throws {
        guard let claimed, let actual, !actual.isEmpty else { return }
        let codec = actual.lowercased()
        let matches: Bool
        switch claimed {
        case .h264: matches = codec.contains("h264") || codec.contains("avc")
        case .h265: matches = codec.contains("h265") || codec.contains("hevc") || codec.contains("hvc")
        case .av1: matches = codec.contains("av1")
        case .vp9: matches = codec.contains("vp9") || codec.contains("vp09")
        case .xvid: matches = codec.contains("xvid")
        case .divx: matches = codec.contains("divx")
        case .mpeg2: matches = codec.contains("mpeg2") || codec.contains("mp2v")
        case .vc1: matches = codec.contains("vc1")
        }
        guard matches else { throw MediaProbeError.codecMismatch(claimed: claimed.rawValue, actual: actual) }
    }
}
