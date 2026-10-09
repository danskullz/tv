import Foundation

/// "Wait N minutes for a better release" rule. The persisted `DelayProfile` record maps onto this
/// via ``init(record:)``.
public struct DelayProfileConfig: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var delayMinutes: Int
    /// Grab immediately when the release is in the profile's highest allowed quality group.
    public var bypassIfHighestQuality: Bool
    /// Grab immediately when the release's custom-format score is at least this.
    public var bypassIfScoreAtLeast: Int?

    public init(
        id: UUID = UUID(), name: String = "Default", delayMinutes: Int, bypassIfHighestQuality: Bool = true,
        bypassIfScoreAtLeast: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.delayMinutes = delayMinutes
        self.bypassIfHighestQuality = bypassIfHighestQuality
        self.bypassIfScoreAtLeast = bypassIfScoreAtLeast
    }

    public init(record: DelayProfile) {
        self.init(
            id: record.id, name: record.name, delayMinutes: record.delayMinutes,
            bypassIfHighestQuality: record.bypassIfHighestQuality, bypassIfScoreAtLeast: record.bypassIfScoreAtLeast)
    }

    public enum Verdict: Sendable, Hashable {
        /// Grab now. `reason` says why the delay does not apply.
        case proceed(reason: String)
        /// Hold until this moment, then re-evaluate.
        case wait(until: Date)

        public var isWaiting: Bool {
            if case .wait = self { return true }
            return false
        }
    }

    /// Decides whether a release may be grabbed at `now`.
    ///
    /// The delay counts from the release's publish date; an unknown publish date never delays
    /// (we cannot tell how long it has been out).
    public func evaluate(
        tierGroupIndex: Int?, formatScore: Int, in profile: QualityProfileConfig, publishDate: Date?, now: Date
    ) -> Verdict {
        guard delayMinutes > 0 else { return .proceed(reason: "no delay configured") }
        if bypassIfHighestQuality, let idx = tierGroupIndex, idx == profile.highestAllowedGroupIndex {
            return .proceed(reason: "highest quality in your profile")
        }
        if let threshold = bypassIfScoreAtLeast, formatScore >= threshold {
            return .proceed(reason: "custom format score \(formatScore) meets the bypass score \(threshold)")
        }
        guard let publishDate else { return .proceed(reason: "publish date unknown") }
        let releaseAt = publishDate.addingTimeInterval(TimeInterval(delayMinutes) * 60)
        if now >= releaseAt { return .proceed(reason: "waited \(delayMinutes) min") }
        return .wait(until: releaseAt)
    }
}
