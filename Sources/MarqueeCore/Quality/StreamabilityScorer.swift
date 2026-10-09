import Foundation

/// How the video is packaged inside the torrent, as far as it affects seeking while downloading.
public enum ContainerKind: String, Sendable, Hashable, Codable {
    case mp4, mkv, avi, transportStream, other, unknown
    /// RAR/ZIP volumes stored without compression: the inner file is addressable by byte range.
    case storedArchive
    /// Compressed archives must be extracted incrementally and cannot be seeked freely.
    case compressedArchive

    /// Best guess from a parsed name; real torrent metadata should override it via
    /// ``StreamabilityInput/containerOverrides``. Archives are assumed compressed unless told otherwise.
    public static func guess(from parsed: ParsedRelease) -> ContainerKind {
        switch parsed.container {
        case "mp4"?, "m4v"?: return .mp4
        case "mkv"?, "webm"?: return .mkv
        case "avi"?: return .avi
        case "ts"?, "m2ts"?: return .transportStream
        case "rar"?, "zip"?, "7z"?, "r00"?: return .compressedArchive
        default: return parsed.flags.contains(.archive) ? .compressedArchive : .unknown
        }
    }
}

/// What Play is asking for, plus live conditions.
public struct StreamabilityInput: Sendable {
    public var wanted: WantedItem
    /// Sustained download throughput measured for this user, in bytes per second.
    public var measuredThroughputBytesPerSecond: Double?
    /// Container info from torrent metadata, keyed by candidate id.
    public var containerOverrides: [String: ContainerKind]

    public init(
        wanted: WantedItem, measuredThroughputBytesPerSecond: Double? = nil,
        containerOverrides: [String: ContainerKind] = [:]
    ) {
        self.wanted = wanted
        self.measuredThroughputBytesPerSecond = measuredThroughputBytesPerSecond
        self.containerOverrides = containerOverrides
    }
}

/// One contribution to a streamability score.
public struct StreamabilityComponent: Sendable, Hashable {
    public var name: String
    public var points: Double
    /// Short phrase for the explanation.
    public var note: String
}

/// How well a release is suited to being played while it downloads.
public struct StreamabilityScore: Sendable, Hashable, Identifiable {
    public var decision: ReleaseDecision
    public var total: Double
    public var components: [StreamabilityComponent]
    /// Average video bitrate implied by size / runtime.
    public var bitrateBytesPerSecond: Double?
    /// bitrate <= measured throughput; nil if either is unknown.
    public var fitsThroughput: Bool?
    public var container: ContainerKind
    public var explanation: DecisionExplanation
    public var id: String { decision.id }
}

/// The extra, Play-only score from SCOPE section 4.5. It re-orders releases the decision engine already
/// accepted; it never resurrects rejected ones.
///
/// Total = swarm health (log-scaled seeders, up to 50) + bitrate-vs-throughput fit (-40...+25) + container
/// (-45...+6) + pack/single fit (-40...+25) + profile preference (8 points per rank step, 48 for the engine's top pick, none past #6).
public enum StreamabilityScorer {
    /// Bitrate/throughput ratio at or below which a release streams with comfortable headroom.
    public static let headroomRatio = 0.8

    /// Accepted decisions ordered best-to-stream first.
    public static func rank(_ decisions: [ReleaseDecision], input: StreamabilityInput) -> [StreamabilityScore] {
        let accepted = decisions.filter(\.isAccepted)
        let bestSingleSeeders = accepted.filter { !$0.isPack }.map { $0.candidate.release.seeders ?? 0 }.max() ?? 0
        var scores = accepted.map { score($0, input: input, bestSingleSeeders: bestSingleSeeders) }
        scores.sort {
            if $0.total != $1.total { return $0.total > $1.total }
            return ($0.decision.rank ?? Int.max) < ($1.decision.rank ?? Int.max)
        }
        return scores.enumerated().map { index, score in
            var s = score
            s.explanation.headline = index == 0 ? "Best to stream" : "Streamable"
            return s
        }
    }

    public static func score(_ decision: ReleaseDecision, input: StreamabilityInput, bestSingleSeeders: Int) -> StreamabilityScore {
        let release = decision.candidate.release
        let parsed = decision.candidate.parsed
        var components: [StreamabilityComponent] = []

        // Swarm health.
        let seeders = release.seeders
        let health: StreamabilityComponent
        switch seeders {
        case 0?:
            health = .init(name: "health", points: -100, note: "no seeders")
        case let s?:
            var points = 50 * min(1, log(1 + Double(s)) / log(301))
            if let leechers = release.leechers ?? release.peers.map({ max(0, $0 - s) }) {
                points += min(5, 5 * log(1 + Double(leechers)) / log(101))
            }
            health = .init(name: "health", points: points, note: "\(s) seeder\(s == 1 ? "" : "s")")
        case nil:
            health = .init(name: "health", points: 10, note: "seeder count unknown")
        }
        components.append(health)

        // Bitrate vs throughput.
        var bitrate: Double?
        if let size = release.size, let minutes = input.wanted.coveredRuntimeMinutes(for: parsed), minutes > 0 {
            bitrate = Double(size) / (minutes * 60)
        }
        var fits: Bool?
        if let bitrate, let throughput = input.measuredThroughputBytesPerSecond, throughput > 0 {
            let ratio = bitrate / throughput
            fits = ratio <= 1
            let (points, phrase): (Double, String)
            if ratio <= 0.5 { (points, phrase) = (25, "well within") }
            else if ratio <= headroomRatio { (points, phrase) = (15, "comfortably within") }
            else if ratio <= 1 { (points, phrase) = (5, "just within") }
            else if ratio <= 1.25 { (points, phrase) = (-15, "slightly above") }
            else { (points, phrase) = (-40, "well above") }
            components.append(.init(
                name: "bitrate", points: points,
                note: "bitrate \(mbit(bitrate)) is \(phrase) your \(mbit(throughput)) connection"))
        }

        // Container.
        let container = input.containerOverrides[decision.id] ?? ContainerKind.guess(from: parsed)
        switch container {
        case .mp4: components.append(.init(name: "container", points: 6, note: "MP4 container"))
        case .mkv: components.append(.init(name: "container", points: 4, note: "MKV container"))
        case .avi: components.append(.init(name: "container", points: -4, note: "AVI container (poor seeking)"))
        case .transportStream: components.append(.init(name: "container", points: -2, note: "transport stream"))
        case .storedArchive:
            components.append(.init(name: "container", points: -10, note: "stored RAR archive (streams, with extra lookups)"))
        case .compressedArchive:
            components.append(.init(name: "container", points: -45, note: "compressed archive (must unpack while playing)"))
        case .other, .unknown: break
        }

        // Pack vs single.
        if let packComponent = packComponent(decision, input: input, bestSingleSeeders: bestSingleSeeders) {
            components.append(packComponent)
        }

        // The user's own preference, as ranked by the decision engine.
        if let rank = decision.rank {
            let points = 8 * Double(max(0, 7 - rank))
            if points > 0 { components.append(.init(name: "profile", points: points, note: "rank #\(rank) in your profile")) }
        }

        let total = components.reduce(0) { $0 + $1.points }
        return StreamabilityScore(
            decision: decision, total: total, components: components, bitrateBytesPerSecond: bitrate,
            fitsThroughput: fits, container: container,
            explanation: DecisionExplanation(
                headline: "Streamable",
                reasons: ["\(decision.tier.displayName)"] + components.map(\.note)))
    }

    private static func packComponent(
        _ decision: ReleaseDecision, input: StreamabilityInput, bestSingleSeeders: Int
    ) -> StreamabilityComponent? {
        let parsed = decision.candidate.parsed
        let seeders = decision.candidate.release.seeders ?? 0
        switch input.wanted.scope {
        case .movie:
            return nil
        case .episodes:
            if !decision.isPack { return .init(name: "pack", points: 10, note: "single episode (smallest download)") }
            if seeders >= max(10, 4 * bestSingleSeeders) {
                return .init(name: "pack", points: 5, note: "season pack is much healthier than single episodes (\(seeders) vs \(bestSingleSeeders) seeders)")
            }
            return .init(name: "pack", points: -12, note: "season pack (more to download than one episode)")
        case .season:
            switch parsed.kind {
            case .seasonPack, .animeAbsolute:
                if decision.isPack {
                    return seeders >= 3
                        ? .init(name: "pack", points: 25, note: "complete season pack with a healthy swarm")
                        : .init(name: "pack", points: 5, note: "season pack, but a thin swarm")
                }
            case .multiSeason, .completeSeries:
                return .init(name: "pack", points: 12, note: "multi-season pack (works, but larger than needed)")
            default: break
            }
            return .init(name: "pack", points: -40, note: "single release cannot cover the whole season")
        }
    }

    /// "Try a smaller version": the best-ranked accepted release (other than `current`) whose bitrate fits
    /// the measured throughput with headroom. When nothing fits, the lowest-bitrate alternative is offered
    /// and the explanation says so. Without a throughput measurement, the best-ranked smaller release.
    public static func smallerVersion(
        than current: ReleaseDecision, among decisions: [ReleaseDecision], input: StreamabilityInput
    ) -> StreamabilityScore? {
        let bestSingleSeeders = decisions.filter { $0.isAccepted && !$0.isPack }.map { $0.candidate.release.seeders ?? 0 }.max() ?? 0
        let currentScore = score(current, input: input, bestSingleSeeders: bestSingleSeeders)
        let currentSize = current.candidate.release.size ?? Int64.max

        let options: [StreamabilityScore] = decisions.compactMap { decision in
            guard decision.isAccepted, decision.id != current.id,
                (decision.candidate.release.seeders ?? 1) > 0,
                let size = decision.candidate.release.size, size < currentSize
            else { return nil }
            if input.wanted.isSeason, !decision.isPack { return nil }
            let s = score(decision, input: input, bestSingleSeeders: bestSingleSeeders)
            guard s.bitrateBytesPerSecond != nil else { return nil }
            return s
        }
        func byEngineRank(_ a: StreamabilityScore, _ b: StreamabilityScore) -> Bool {
            (a.decision.rank ?? Int.max) < (b.decision.rank ?? Int.max)
        }

        var pick: StreamabilityScore?
        var note: String
        if let throughput = input.measuredThroughputBytesPerSecond, throughput > 0 {
            let fitting = options.filter { ($0.bitrateBytesPerSecond ?? .infinity) <= throughput * headroomRatio }
            if let best = fitting.sorted(by: byEngineRank).first {
                pick = best
                note = "bitrate \(mbit(best.bitrateBytesPerSecond ?? 0)) fits your measured \(mbit(throughput))"
            } else {
                pick = options.min { ($0.bitrateBytesPerSecond ?? .infinity) < ($1.bitrateBytesPerSecond ?? .infinity) }
                note = "nothing fits your measured \(mbit(throughput)) with headroom; this is the lightest available"
            }
        } else {
            pick = options.sorted(by: byEngineRank).first
            note = "smaller download than the current release"
        }
        guard var result = pick else { return nil }
        let from = currentScore.bitrateBytesPerSecond.map { " (current \(mbit($0)))" } ?? ""
        result.explanation = DecisionExplanation(
            headline: "Try a smaller version",
            reasons: ["\(result.decision.tier.displayName)", note + from]
                + result.components.filter { $0.name == "health" }.map(\.note))
        return result
    }

    private static func mbit(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f Mbit/s", bytesPerSecond * 8 / 1_000_000)
    }
}
