import Foundation

/// How the video is packaged inside the torrent, as far as it affects seeking while downloading.
public enum ContainerKind: String, Sendable, Hashable, Codable {
    case mp4, mkv, avi, transportStream, other, unknown
    /// RAR/ZIP volumes stored without compression: the inner file is addressable by byte range.
    case storedArchive
    /// Compressed archives must be extracted incrementally and cannot be seeked freely.
    case compressedArchive

    /// Best guess from a parsed name; real torrent metadata should override it via
    /// ``StreamabilityInput/containerOverrides`` or ``StreamabilityInput/metadataFiles``.
    /// Archives are assumed compressed unless told otherwise.
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

    /// Container from a real torrent file list (torrent metadata), which overrides the name guess.
    /// Direct video files win (MP4 > MKV > AVI > transport stream); bare archives report
    /// `.compressedArchive` — callers that verify an archive is stored (uncompressed) should record
    /// `.storedArchive` in ``StreamabilityInput/containerOverrides`` instead. Returns `.unknown`
    /// when nothing is recognized, in which case scoring falls back to the name guess.
    public static func fromMetadataFiles(_ files: [String]) -> ContainerKind {
        var sawArchive = false, sawOtherVideo = false
        var sawTS = false, sawAVI = false, sawMKV = false, sawMP4 = false
        for file in files {
            let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
            switch ext {
            case "mp4", "m4v": sawMP4 = true
            case "mkv", "webm": sawMKV = true
            case "avi", "divx": sawAVI = true
            case "ts", "m2ts": sawTS = true
            case "mpg", "mpeg", "mov", "wmv", "vob": sawOtherVideo = true
            case "rar", "zip", "7z", "r00", "r01", "001": sawArchive = true
            default:
                // Multi-part RAR volumes (r02..r99).
                if ext.count == 3, ext.first == "r", ext.dropFirst().allSatisfy(\.isNumber) { sawArchive = true }
            }
        }
        if sawMP4 { return .mp4 }
        if sawMKV { return .mkv }
        if sawAVI { return .avi }
        if sawTS { return .transportStream }
        if sawOtherVideo { return .other }
        if sawArchive { return .compressedArchive }
        return .unknown
    }
}

/// What Play is asking for, plus live conditions.
public struct StreamabilityInput: Sendable {
    public var wanted: WantedItem
    /// Sustained download throughput measured for this user, in bytes per second.
    public var measuredThroughputBytesPerSecond: Double?
    /// Container info from torrent metadata, keyed by candidate id.
    public var containerOverrides: [String: ContainerKind]
    /// Torrent file lists keyed by candidate id; real extensions (via
    /// ``ContainerKind/fromMetadataFiles(_:)``) override the name guess when no explicit
    /// `containerOverrides` entry exists.
    public var metadataFiles: [String: [String]]
    /// Probed seeder counts keyed by candidate id. Indexer-advertised counts are trusted blindly
    /// unless a later probing stage records real observations here; present entries replace the
    /// advertised count for health scoring. Nil (unprobed) keeps current behavior.
    public var observedSeeders: [String: Int]?
    /// Probe round-trip latency in seconds keyed by candidate id. Present entries add a small
    /// responsiveness penalty for slow answers; nil (unprobed) keeps current behavior.
    public var observedLatencySeconds: [String: Double]?

    public init(
        wanted: WantedItem, measuredThroughputBytesPerSecond: Double? = nil,
        containerOverrides: [String: ContainerKind] = [:], metadataFiles: [String: [String]] = [:],
        observedSeeders: [String: Int]? = nil, observedLatencySeconds: [String: Double]? = nil
    ) {
        self.wanted = wanted
        self.measuredThroughputBytesPerSecond = measuredThroughputBytesPerSecond
        self.containerOverrides = containerOverrides
        self.metadataFiles = metadataFiles
        self.observedSeeders = observedSeeders
        self.observedLatencySeconds = observedLatencySeconds
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
/// Total = swarm health (log-scaled seeders, up to 50 + 5 leecher bonus; probed counts in
/// `StreamabilityInput.observedSeeders` override advertised ones) + bitrate-vs-throughput fit
/// (-60...+25 measured; -40...0 against a conservative default estimate when unmeasured) +
/// container (-45...+6, real torrent file lists override the name guess) + pack/single fit
/// (-40...+25) + profile preference (4 points per rank step, max +16, nothing past #4) +
/// source (+4 magnet, +0 torrent file) + probe responsiveness (0...-10, only when probed).
public enum StreamabilityScorer {
    /// Bitrate/throughput ratio at or below which a release streams with comfortable headroom.
    public static let headroomRatio = 0.8

    /// Conservative throughput assumed when nothing was measured (2 MB/s ≈ 16 Mbit/s): only
    /// releases needing far more than this are demoted. Lighter releases still win exact ties.
    public static let defaultThroughputBytesPerSecond = 2_000_000.0

    /// Accepted decisions ordered best-to-stream first.
    public static func rank(_ decisions: [ReleaseDecision], input: StreamabilityInput) -> [StreamabilityScore] {
        let accepted = decisions.filter(\.isAccepted)
        let bestSingleSeeders = accepted.filter { !$0.isPack }.map { $0.candidate.release.seeders ?? 0 }.max() ?? 0
        var scores = accepted.map { score($0, input: input, bestSingleSeeders: bestSingleSeeders) }
        scores.sort {
            if $0.total != $1.total { return $0.total > $1.total }
            // On an exact tie the lighter download starts faster, and a magnet starts without an
            // extra HTTP fetch through the indexer; engine rank is the last resort.
            switch ($0.bitrateBytesPerSecond, $1.bitrateBytesPerSecond) {
            case let (a?, b?): if a != b { return a < b }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            let aMagnet = $0.decision.candidate.release.magnetURL != nil
            let bMagnet = $1.decision.candidate.release.magnetURL != nil
            if aMagnet != bMagnet { return aMagnet }
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

        // Swarm health. A probed seeder count replaces the indexer's advertised one;
        // indexer counts are trusted blindly until a probing stage says otherwise.
        let observedSeeders = input.observedSeeders?[decision.id]
        let advertisedSeeders = release.seeders
        let seeders = observedSeeders ?? advertisedSeeders
        let health: StreamabilityComponent
        switch seeders {
        case 0?:
            let note: String
            if let observed = observedSeeders, observed != advertisedSeeders {
                note = "observed no seeders (indexer said \(advertisedSeeders.map(String.init) ?? "?"))"
            } else {
                note = "no seeders"
            }
            health = .init(name: "health", points: -100, note: note)
        case let s?:
            var points = 50 * min(1, log(1 + Double(s)) / log(301))
            if let leechers = release.leechers ?? release.peers.map({ max(0, $0 - s) }) {
                points += min(5, 5 * log(1 + Double(leechers)) / log(101))
            }
            let note: String
            if let observed = observedSeeders, observed != advertisedSeeders {
                note = "observed \(observed) seeders (indexer said \(advertisedSeeders.map(String.init) ?? "?"))"
            } else {
                note = "\(s) seeder\(s == 1 ? "" : "s")"
            }
            health = .init(name: "health", points: points, note: note)
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
        if let bitrate {
            if let throughput = input.measuredThroughputBytesPerSecond, throughput > 0 {
                let ratio = bitrate / throughput
                fits = ratio <= 1
                let (points, phrase): (Double, String)
                if ratio <= 0.5 { (points, phrase) = (25, "well within") }
                else if ratio <= headroomRatio { (points, phrase) = (15, "comfortably within") }
                else if ratio <= 1 { (points, phrase) = (5, "just within") }
                else if ratio <= 1.25 { (points, phrase) = (-15, "slightly above") }
                // A release needing far more than the line can carry will not start: veto, not nudge.
                else { (points, phrase) = (-60, "well above") }
                components.append(.init(
                    name: "bitrate", points: points,
                    note: "bitrate \(mbit(bitrate)) is \(phrase) your \(mbit(throughput)) connection"))
            } else {
                // Unmeasured line: assume a conservative floor and only demote obvious hogs.
                // `fits` stays nil — nothing was actually measured.
                let ratio = bitrate / defaultThroughputBytesPerSecond
                if ratio > 4 {
                    components.append(.init(
                        name: "bitrate", points: -40,
                        note: "bitrate \(mbit(bitrate)) is far above a typical \(mbit(defaultThroughputBytesPerSecond)) connection"))
                } else if ratio > 2 {
                    components.append(.init(
                        name: "bitrate", points: -20,
                        note: "bitrate \(mbit(bitrate)) is likely above a typical \(mbit(defaultThroughputBytesPerSecond)) connection"))
                }
            }
        }

        // Container: explicit overrides win, then real torrent metadata, then the name guess.
        let container: ContainerKind
        if let override = input.containerOverrides[decision.id] {
            container = override
        } else if let files = input.metadataFiles[decision.id], !files.isEmpty {
            let fromFiles = ContainerKind.fromMetadataFiles(files)
            container = fromFiles == .unknown ? ContainerKind.guess(from: parsed) : fromFiles
        } else {
            container = ContainerKind.guess(from: parsed)
        }
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

        // The user's own preference, as ranked by the decision engine. Capped at +16 (4 points per
        // rank step, nothing past #4): Play must pick startable releases, so swarm health — not the
        // profile — decides between releases more than a step apart. A 3x seeder gap is worth at most
        // ~9.6 health points, which always beats one rank step (4 points).
        if let rank = decision.rank {
            let points = 4 * Double(max(0, 5 - rank))
            if points > 0 { components.append(.init(name: "profile", points: points, note: "rank #\(rank) in your profile")) }
        }

        // Source: a magnet starts without an extra HTTP fetch through the indexer (often a flaky
        // proxy link), so it earns a small bonus; a torrent file costs one extra download step.
        if release.magnetURL != nil {
            components.append(.init(name: "source", points: 4, note: "magnet link (starts directly)"))
        } else {
            components.append(.init(name: "source", points: 0, note: "torrent file (one extra download step)"))
        }

        // Probe responsiveness, only when a probing stage recorded observations.
        if let latency = input.observedLatencySeconds?[decision.id] {
            let points = max(-10, min(0, (1 - max(0, latency)) * 2))
            if points < 0 {
                components.append(.init(
                    name: "responsiveness", points: points,
                    note: String(format: "probe answered in %.1fs", latency)))
            }
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
