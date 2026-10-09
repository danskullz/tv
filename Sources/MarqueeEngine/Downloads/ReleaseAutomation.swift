import Foundation
import MarqueeCore

public struct AutomationTarget: Sendable, Hashable {
    public var wanted: WantedTarget
    public var profile: QualityProfileConfig
    public var formats: [CustomFormatConfig]
    public var delayProfile: DelayProfileConfig?
    public var savePath: URL
    public var minimumSeeders: Int
    public var seedRatioGoal: Double?
    public var seedTimeGoalMinutes: Int?

    public init(
        wanted: WantedTarget, profile: QualityProfileConfig, formats: [CustomFormatConfig] = BuiltInFormats.all,
        delayProfile: DelayProfileConfig? = nil, savePath: URL, minimumSeeders: Int = 1,
        seedRatioGoal: Double? = nil, seedTimeGoalMinutes: Int? = nil
    ) {
        self.wanted = wanted
        self.profile = profile
        self.formats = formats
        self.delayProfile = delayProfile
        self.savePath = savePath
        self.minimumSeeders = minimumSeeders
        self.seedRatioGoal = seedRatioGoal
        self.seedTimeGoalMinutes = seedTimeGoalMinutes
    }
}

public protocol ReleaseGrabber: Sendable {
    func add(_ request: DownloadRequest) async throws -> Torrent
}

extension DownloadManager: ReleaseGrabber {}

public enum AutomationSearchOrigin: Sendable, Equatable { case rss, searchNow }

public struct AutomationRunResult: Sendable, Equatable {
    public var searched: Int
    public var accepted: Int
    public var grabbed: Int
    public var delayed: Int
    public var indexerFailures: Int
    public init(searched: Int = 0, accepted: Int = 0, grabbed: Int = 0, delayed: Int = 0, indexerFailures: Int = 0) {
        self.searched = searched
        self.accepted = accepted
        self.grabbed = grabbed
        self.delayed = delayed
        self.indexerFailures = indexerFailures
    }
}

/// RSS and on-demand release automation. RSS work is coalesced by AppKit and is only enabled
/// explicitly by the app when it has monitored targets.
public actor ReleaseAutomation {
    public typealias TargetProvider = @Sendable () async throws -> [AutomationTarget]
    public typealias SourceResolver = @Sendable (IndexerRelease) async throws -> DownloadSource
    public typealias IndexerRefresher = @Sendable () async -> Void

    private let search: any ReleaseSearching
    private let targets: TargetProvider
    private let grabber: any ReleaseGrabber
    private let grabs: any GrabRepository
    private let blocklist: any BlocklistRepository
    private let history: any HistoryRepository
    private let health: any HealthIssueRepository
    private let indexers: (any IndexerRepository)?
    private let sourceResolver: SourceResolver
    private let refreshIndexers: IndexerRefresher
    private let interval: TimeInterval
    private var scheduler: NSBackgroundActivityScheduler?

    public init(
        search: any ReleaseSearching, targets: @escaping TargetProvider, grabber: any ReleaseGrabber,
        grabs: any GrabRepository, blocklist: any BlocklistRepository, history: any HistoryRepository,
        health: any HealthIssueRepository, indexers: (any IndexerRepository)? = nil,
        refreshIndexers: @escaping IndexerRefresher = {}, interval: TimeInterval = 15 * 60,
        sourceResolver: SourceResolver? = nil
    ) {
        self.search = search
        self.targets = targets
        self.grabber = grabber
        self.grabs = grabs
        self.blocklist = blocklist
        self.history = history
        self.health = health
        self.indexers = indexers
        self.refreshIndexers = refreshIndexers
        self.interval = max(60, interval)
        self.sourceResolver = sourceResolver ?? { try await Self.defaultSource($0) }
    }

    /// Schedules coalesced RSS refreshes. Call only when targets and indexers exist; each wake checks
    /// again before making any network request.
    public func start() {
        guard scheduler == nil else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "com.marquee.rss-sync")
        activity.interval = interval
        activity.tolerance = min(interval / 3, 5 * 60)
        activity.repeats = true
        activity.schedule { [weak self] completion in
            Task {
                await self?.syncRSS()
                completion(.finished)
            }
        }
        scheduler = activity
    }

    public func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }

    @discardableResult
    public func syncRSS(now: Date = Date()) async -> AutomationRunResult {
        guard let targets = try? await targets(), !targets.isEmpty else { return AutomationRunResult() }
        await refreshIndexers()
        guard await search.enabledIndexerCount() > 0 else { return AutomationRunResult() }
        let found = await search.search(.generic())
        await recordIndexerHealth(found, now: now)
        return await process(found.releases, for: targets, origin: .rss, ignoreDelay: false, now: now)
    }

    @discardableResult
    public func searchNow(target: AutomationTarget, now: Date = Date()) async -> AutomationRunResult {
        await refreshIndexers()
        guard await search.enabledIndexerCount() > 0 else { return AutomationRunResult() }
        let found = await search.search(Self.query(for: target.wanted))
        await recordIndexerHealth(found, now: now)
        return await process(found.releases, for: [target], origin: .searchNow, ignoreDelay: true, now: now)
    }

    @discardableResult
    public func searchNow(targets: [AutomationTarget], now: Date = Date()) async -> AutomationRunResult {
        var total = AutomationRunResult()
        guard !targets.isEmpty else { return total }
        await refreshIndexers()
        guard await search.enabledIndexerCount() > 0 else { return total }
        for target in targets {
            let found = await search.search(Self.query(for: target.wanted))
            await recordIndexerHealth(found, now: now)
            let result = await process(found.releases, for: [target], origin: .searchNow, ignoreDelay: true, now: now)
            total.indexerFailures += found.failedCount
            total.searched += result.searched
            total.accepted += result.accepted
            total.grabbed += result.grabbed
            total.delayed += result.delayed
            total.indexerFailures += result.indexerFailures
        }
        return total
    }

    private func process(
        _ releases: [IndexerRelease], for targets: [AutomationTarget], origin: AutomationSearchOrigin,
        ignoreDelay: Bool, now: Date
    ) async -> AutomationRunResult {
        var result = AutomationRunResult(searched: releases.count)
        var hashesGrabbed = Set<String>()
        for target in targets {
            let titleID = target.wanted.title.id
            let entries = (try? await blocklist.entries(titleId: titleID)) ?? []
            let releaseBlocklist = ReleaseBlocklist(entries: entries)
            let candidates = releases.map(ReleaseCandidate.init(release:)).filter { candidate in
                guard target.wanted.item.matchesTitle(candidate.parsed) else { return false }
                if case .mismatch = target.wanted.item.match(candidate.parsed) { return false }
                return true
            }
            guard !candidates.isEmpty else { continue }
            let context = DecisionContext(
                wanted: target.wanted.item, profile: target.profile, formats: target.formats,
                current: target.wanted.currentFile, blocklist: releaseBlocklist,
                minimumSeeders: target.minimumSeeders, delayProfile: target.delayProfile,
                now: now, ignoreDelay: ignoreDelay)
            let decisions = ReleaseDecisionEngine(context).decide(candidates)
            let accepted = decisions.filter(\.isAccepted)
            result.accepted += accepted.count
            result.delayed += decisions.filter { $0.rejections.contains { if case .delayed = $0 { true } else { false } } }.count

            var grabbedID: UUID?
            var grabbedReleaseID: String?
            var failedReleaseIDs = Set<String>()
            for decision in accepted {
                let release = decision.candidate.release
                let hash = release.infoHash?.lowercased()
                if let hash, hashesGrabbed.contains(hash) { continue }
                do {
                    let source = try await sourceResolver(release)
                    let id = UUID()
                    let request = DownloadRequest(
                        source: source, release: release, titleId: titleID,
                        episodeIds: target.wanted.episode.map { [$0.id] } ?? [], grabId: id,
                        savePath: target.savePath, seedRatioGoal: target.seedRatioGoal,
                        seedTimeGoalMinutes: target.seedTimeGoalMinutes)
                    _ = try await grabber.add(request)
                    grabbedID = id
                    grabbedReleaseID = release.id
                    if let hash { hashesGrabbed.insert(hash) }
                    result.grabbed += 1
                    break
                } catch DownloadManagerError.alreadyManaged {
                    break
                } catch DownloadManagerError.insufficientSpace(let required, let available) {
                    failedReleaseIDs.insert(release.id)
                    result.delayed += 1
                    await appendDecision(
                        target: target, release: release, outcome: .rejected,
                        origin: origin, grabId: UUID(), score: decision.formatScore,
                        reason: ["rejections": .array([.object([
                            "code": .string("notEnoughFreeSpace"),
                            "message": .string("Needs \(required) bytes but only \(available) is free"),
                        ])])])
                } catch {
                    failedReleaseIDs.insert(release.id)
                    let reason = String(describing: error)
                    if let hash = release.infoHash {
                        try? await blocklist.add(BlocklistEntry(
                            titleId: titleID, episodeId: target.wanted.episode?.id,
                            indexerId: release.indexerID, releaseTitle: release.title,
                            infoHash: hash, reason: reason))
                    }
                    await appendDecision(
                        target: target, release: release, outcome: .failed,
                        origin: origin, grabId: UUID(), score: decision.formatScore,
                        reason: ["failure": .string(reason)])
                }
            }

            for decision in decisions where decision.candidate.release.id != grabbedReleaseID
                && !failedReleaseIDs.contains(decision.candidate.release.id)
            {
                let release = decision.candidate.release
                let rejections: [JSONValue] = decision.rejections.map { .object(["code": .string($0.code), "message": .string($0.message)]) }
                let didDelay = decision.rejections.contains { if case .delayed = $0 { true } else { false } }
                let reason: [String: JSONValue] = [
                    "profile": .string(target.profile.name),
                    "quality": .string(decision.tier.displayName),
                    "formatScore": .int(decision.formatScore),
                    "explanation": .string(decision.explanation.text),
                    "rejections": .array(rejections),
                ]
                await appendDecision(
                    target: target, release: release, outcome: .rejected,
                    origin: origin, grabId: UUID(), score: decision.formatScore, reason: reason)
                if didDelay {
                    await history.appendQuietly(HistoryEvent(
                        type: "releaseDelayed", entityType: .release, entityId: release.infoHash,
                        titleId: titleID, payload: ["release": .string(release.title)]))
                }
            }
            if let grabbedID, let releaseID = grabbedReleaseID,
                let release = releases.first(where: { $0.id == releaseID }),
                let decision = decisions.first(where: { $0.candidate.release.id == releaseID })
            {
                await appendDecision(
                    target: target, release: release, outcome: .grabbed,
                    origin: origin, grabId: grabbedID, score: decision.formatScore,
                    reason: ["profile": .string(target.profile.name), "explanation": .string(decision.explanation.text)])
            }
        }
        return result
    }

    private func appendDecision(
        target: AutomationTarget, release: IndexerRelease, outcome: Grab.Outcome,
        origin: AutomationSearchOrigin, grabId: UUID, score: Int, reason: [String: JSONValue]
    ) async {
        let grab = Grab(
            id: grabId, titleId: target.wanted.title.id, episodeId: target.wanted.episode?.id,
            releaseTitle: release.title, infoHash: release.infoHash,
            origin: origin == .rss ? .rss : .search, outcome: outcome, score: score,
            reason: .object(reason))
        try? await grabs.save(grab)
        let type: HistoryEventType = outcome == .grabbed ? .grabbed : (outcome == .failed ? .torrentFailed : .grabRejected)
        await history.appendQuietly(HistoryEvent(
            type: type, entityType: .grab, entityUUID: grabId, titleId: target.wanted.title.id,
            payload: ["release": .string(release.title), "outcome": .string(outcome.rawValue)]))
    }

    private func recordIndexerHealth(_ result: CoordinatedSearchResult, now: Date) async {
        for outcome in result.outcomes {
            switch outcome.status {
            case .success:
                try? await health.resolve(code: "indexerFailure", entityId: outcome.indexerID.uuidString)
                try? await indexers?.recordSearchOutcome(
                    id: outcome.indexerID, succeeded: true, threshold: 5, disableFor: 6 * 60 * 60, now: now)
            case .failure(let error):
                _ = try? await health.report(
                    code: "indexerFailure", severity: .warning,
                    message: "\(outcome.indexerName) failed: \(error.userMessage)",
                    fixAction: "testIndexer", entityId: outcome.indexerID.uuidString)
                try? await indexers?.recordSearchOutcome(
                    id: outcome.indexerID, succeeded: false, threshold: 5, disableFor: 6 * 60 * 60, now: now)
            }
        }
    }

    private static func query(for target: WantedTarget) -> TorznabQuery {
        let title = target.title
        if title.kind == .movie {
            return .movie(title: title.title, year: title.year, imdbID: title.imdbId, tmdbID: title.tmdbId)
        }
        return .tv(
            title: title.title, season: target.episode?.seasonNumber, episode: target.episode?.episodeNumber,
            imdbID: title.imdbId, tvdbID: title.tvdbId, tmdbID: title.tmdbId)
    }

    private static func defaultSource(_ release: IndexerRelease) async throws -> DownloadSource {
        if let magnet = release.magnetURL { return .magnet(magnet.absoluteString) }
        guard let url = release.downloadURL else { throw DownloadManagerError.noDownloadLink }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw DownloadManagerError.unsupportedPayload
        }
        return .torrent(data)
    }
}
