import Foundation

/// Human-readable strings for durations, speeds and progress. Localizable and VoiceOver-friendly.
public enum Formatters {
    /// "1 h 52 min"
    public static func runtime(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow, zeroValueUnits: .hide))
    }

    /// "~2 min", "under a minute", "~1 hr 5 min"
    public static func approximate(seconds: TimeInterval) -> String {
        if seconds < 45 { return String(localized: "under a minute") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "~\(minutes) min") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? String(localized: "~\(h) hr") : String(localized: "~\(h) hr \(m) min")
    }

    /// "12.4 MB/s"
    public static func speed(bytesPerSecond: Double) -> String {
        let text = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return String(localized: "\(text)/s")
    }

    public static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    public static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
