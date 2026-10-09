import Foundation

/// Human-readable labels for audio and subtitle tracks ("English", "Dolby Digital Plus · 5.1").
public extension MediaTrack {
    /// Language name in the user's locale, falling back to the file's track title, then "Track N".
    func languageName(locale: Locale = .current) -> String? {
        guard let code = language?.lowercased(), !code.isEmpty, !["und", "zxx", "mis", "mul"].contains(code) else { return nil }
        return locale.localizedString(forLanguageCode: code)?.localizedCapitalized
    }

    /// Short codec name: "Dolby Digital Plus", "DTS-HD", "AAC", "SRT", "PGS".
    var codecName: String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "ac3": return "Dolby Digital"
        case "eac3": return "Dolby Digital Plus"
        case "truehd": return "Dolby TrueHD"
        case "mlp": return "MLP"
        case "dts": return "DTS"
        case "dts-hd", "dtshd": return "DTS-HD"
        case "aac": return "AAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case let c where c.hasPrefix("pcm"): return "PCM"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt": return "WebVTT"
        case "mov_text": return "Text"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub": return "VobSub"
        case "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    /// "Mono", "Stereo", "5.1", "7.1", or "N ch".
    var channelLayout: String? {
        guard let n = channelCount, n > 0 else { return nil }
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n) ch"
        }
    }

    /// Primary line: language, or the file's own title when the language is untagged.
    func displayName(locale: Locale = .current) -> String {
        var name = languageName(locale: locale) ?? title.flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(id)"
        if kind == .subtitle {
            if isForced { name += " (Forced)" }
            else if let t = title, t.range(of: "sdh", options: .caseInsensitive) != nil { name += " (SDH)" }
            else if let t = title, t.range(of: "commentary", options: .caseInsensitive) != nil { name += " (Commentary)" }
        }
        return name
    }

    /// Secondary line: codec and layout for audio ("Dolby Digital Plus · 5.1"), codec for subtitles.
    var detail: String? {
        let parts: [String?] = kind == .audio ? [codecName, channelLayout] : [codecName, isExternal ? "External" : nil]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    /// One line for menus: "English — Dolby Digital Plus · 5.1".
    func menuTitle(locale: Locale = .current) -> String {
        guard let detail else { return displayName(locale: locale) }
        return "\(displayName(locale: locale)) — \(detail)"
    }
}

/// Track cycling for the `A` and `S` keys.
public enum TrackCycling {
    /// Next audio track after `current`, wrapping around. `nil` when there is nothing to switch to.
    public static func nextAudio(in tracks: [MediaTrack], after current: Int?) -> Int? {
        guard tracks.count > 1 else { return nil }
        guard let current, let i = tracks.firstIndex(where: { $0.id == current }) else { return tracks.first?.id }
        return tracks[(i + 1) % tracks.count].id
    }

    /// Next subtitle choice: track, track, …, off (`.some(nil)`), then back to the first track.
    /// Returns `nil` when the file has no subtitle tracks.
    public static func nextSubtitle(in tracks: [MediaTrack], after current: Int?) -> Int?? {
        guard !tracks.isEmpty else { return nil }
        guard let current, let i = tracks.firstIndex(where: { $0.id == current }) else { return .some(tracks[0].id) }
        return i + 1 < tracks.count ? .some(tracks[i + 1].id) : .some(nil)
    }
}

/// Subtitle sync nudging for `[` and `]`.
public enum SubtitleDelay {
    public static let step: TimeInterval = 0.1

    /// Applies `delta` and snaps to the 0.1 s grid so repeated nudges never accumulate floating point error.
    public static func adjusted(_ current: TimeInterval, by delta: TimeInterval) -> TimeInterval {
        ((current + delta) / step).rounded() * step
    }

    /// "+0.3 s", "−1.2 s", "0.0 s".
    public static func label(_ delay: TimeInterval) -> String {
        let value = (delay / step).rounded() * step
        if abs(value) < 0.05 { return "0.0 s" }
        return String(format: "%@%.1f s", value > 0 ? "+" : "\u{2212}", abs(value))
    }
}
