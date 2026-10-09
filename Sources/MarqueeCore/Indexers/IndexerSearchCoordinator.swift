import Foundation

// MARK: - Health

/// Rolling health statistics for one indexer.
public struct IndexerHealth: Sendable, Equatable {
    public var consecutiveFailures = 0
    public var totalQueries = 0
    public var totalFailures = 0
    public var lastError: IndexerError?
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var lastLatency: TimeInterval?
    /// Exponential moving average of successful request latency.
    public var averageLatency: TimeInterval?
    /// Set when the coordinator disabled the indexer after repeated failures.
    public var isAutoDisabled = false

    public init() {}

    mutating func recordSuccess(latency: TimeInterval, at date: Date = Date()) {
        totalQueries += 1
        consecutiveFailures = 0
        lastSuccess = date
        lastLatency = latency
        averageLatency = averageLatency.map { $0 * 0.7 + latency * 0.3 } ?? latency
    }

    mutating func recordFailure(_ error: IndexerError, at date: Date = Date()) {
        totalQueries += 1
        totalFailures += 1
        consecutiveFailures += 1
        lastError = error
        lastFailure = date
    }
}

public enum IndexerEvent: Sendable, Equatable {
    /// Too many consecutive failures; the indexer is now skipped until re-enabled.
    case autoDisabled(indexerID: UUID, name: String, consecutiveFailures: Int, lastError: IndexerError)
    case reenabled(indexerID: UUID, name: String)
}

// MARK: - Results

public struct IndexerSearchOutcome: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case success(releaseCount: Int)
        case failure(IndexerError)
    }

    public var indexerID: UUID
    public var indexerName: String
    public var status: Status
    /// Wall time for this indexer's whole search, including pacing and retries.
    public var latency: TimeInterval
    public var skippedItems: Int
    public var isPartial: Bool
    public var id: UUID { indexerID }

    public init(
        indexerID: UUID, indexerName: String, status: Status, latency: TimeInterval = 0,
        skippedItems: Int = 0, isPartial: Bool = false
    ) {
        self.indexerID = indexerID
        self.indexerName = indexerName
        self.status = status
        self.latency = latency
        self.skippedItems = skippedItems
        self.isPartial = isPartial
    }
}

public struct CoordinatedSearchResult: Sendable, Equatable {
    /// Deduplicated, sorted by seeders (highest first).
    public var releases: [IndexerRelease]
    public var outcomes: [IndexerSearchOutcome]
    public var duplicatesRemoved: Int

    public init(releases: [IndexerRelease] = [], outcomes: [IndexerSearchOutcome] = [], duplicatesRemoved: Int = 0) {
        self.releases = releases
        self.outcomes = outcomes
        self.duplicatesRemoved = duplicatesRemoved
    }

    public var succeededCount: Int { outcomes.filter { if case .success = $0.status { true } else { false } }.count }
    public var failedCount: Int { outcomes.count - succeededCount }
}

public struct IndexerTestOutcome: Sendable, Equatable, Identifiable {
    public var indexerID: UUID
    public var indexerName: String
    public var result: Result<IndexerTestResult, IndexerError>
    public var id: UUID { indexerID }
}

public struct IndexerCoordinatorConfiguration: Sendable, Equatable {
    /// Hard cap on how long any one indexer may take for a search.
    public var perIndexerTimeout: TimeInterval = 15
    /// Consecutive failures before an indexer is auto-disabled.
    public var failureThreshold: Int = 5

    public init(perIndexerTimeout: TimeInterval = 15, failureThreshold: Int = 5) {
        self.perIndexerTimeout = perIndexerTimeout
        self.failureThreshold = max(1, failureThreshold)
    }
}

// MARK: - Deduplication

public enum ReleaseDeduplicator {
    /// Lowercased, diacritic-folded, punctuation-free title for comparison.
    public static func normalizedTitle(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Merges releases that are the same torrent: same info hash, or (when a hash is missing)
    /// same normalized title and size. The survivor is the one with most seeders, then best
    /// indexer priority; missing fields are filled from the others and `alsoFoundOn` lists the rest.
    /// Output order follows first appearance of each group.
    public static func deduplicate(
        _ releases: [IndexerRelease], priority: (UUID) -> Int = { _ in 25 }
    ) -> (releases: [IndexerRelease], removed: Int) {
        var groups: [[IndexerRelease]] = []
        var groupHash: [Int: String] = [:]
        var byHash: [String: Int] = [:]
        var byTitleSize: [String: Int] = [:]

        for release in releases {
            let hash = release.infoHash?.lowercased()
            let titleKey = normalizedTitle(release.title) + "|" + String(release.size ?? -1)
            var index: Int?
            if let hash {
                if let i = byHash[hash] {
                    index = i
                } else if let i = byTitleSize[titleKey], groupHash[i] == nil {
                    index = i
                }
            } else {
                index = byTitleSize[titleKey]
            }
            if let index {
                groups[index].append(release)
                if let hash, groupHash[index] == nil { groupHash[index] = hash }
            } else {
                groups.append([release])
                index = groups.count - 1
                if let hash { groupHash[index!] = hash }
            }
            if let hash { byHash[hash] = index! }
            if byTitleSize[titleKey] == nil { byTitleSize[titleKey] = index! }
        }

        var merged: [IndexerRelease] = []
        for group in groups {
            guard group.count > 1 else { merged.append(group[0]); continue }
            let ranked = group.sorted { a, b in
                let sa = a.seeders ?? -1, sb = b.seeders ?? -1
                if sa != sb { return sa > sb }
                return priority(a.indexerID) < priority(b.indexerID)
            }
            var best = ranked[0]
            for other in ranked.dropFirst() {
                best.infoHash = best.infoHash ?? other.infoHash
                best.magnetURL = best.magnetURL ?? other.magnetURL
                best.downloadURL = best.downloadURL ?? other.downloadURL
                best.infoURL = best.infoURL ?? other.infoURL
                best.size = best.size ?? other.size
                best.publishDate = best.publishDate ?? other.publishDate
                best.imdbID = best.imdbID ?? other.imdbID
                best.tvdbID = best.tvdbID ?? other.tvdbID
                best.tmdbID = best.tmdbID ?? other.tmdbID
                best.grabs = best.grabs ?? other.grabs
                if other.indexerID != best.indexerID, !best.alsoFoundOn.contains(other.indexerID) {
                    best.alsoFoundOn.append(other.indexerID)
                }
            }
            merged.append(best)
        }
        return (merged, releases.count - merged.count)
    }

    /// Seeders descending (unknown last), then indexer priority, newer first, then title.
    public static func sortBySeeders(_ releases: [IndexerRelease], priority: (UUID) -> Int = { _ in 25 }) -> [IndexerRelease] {
        releases.sorted { a, b in
            let sa = a.seeders ?? -1, sb = b.seeders ?? -1
            if sa != sb { return sa > sb }
            let pa = priority(a.indexerID), pb = priority(b.indexerID)
            if pa != pb { return pa < pb }
            let da = a.publishDate ?? .distantPast, db = b.publishDate ?? .distantPast
            if da != db { return da > db }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: - Coordinator

/// Fans a search out to every enabled indexer in parallel, with a per-indexer timeout, then merges,
/// deduplicates and ranks the results. Tracks per-indexer health and auto-disables flaky indexers.
public actor IndexerSearchCoordinator {
    private struct Entry {
        var definition: IndexerDefinition
        var client: IndexerClient
        var health = IndexerHealth()
    }

    private var entries: [UUID: Entry] = [:]
    private let secrets: SecretStore
    private let transport: IndexerTransport
    private let clock: IndexerClock
    private let clientConfiguration: IndexerClientConfiguration
    private let configuration: IndexerCoordinatorConfiguration
    private var continuations: [UUID: AsyncStream<IndexerEvent>.Continuation] = [:]

    public init(
        secrets: SecretStore,
        transport: IndexerTransport = URLSessionIndexerTransport(),
        clock: IndexerClock = SystemIndexerClock(),
        clientConfiguration: IndexerClientConfiguration = IndexerClientConfiguration(),
        configuration: IndexerCoordinatorConfiguration = IndexerCoordinatorConfiguration()
    ) {
        self.secrets = secrets
        self.transport = transport
        self.clock = clock
        self.clientConfiguration = clientConfiguration
        self.configuration = configuration
    }

    // MARK: Registry

    /// Replaces the full indexer set. Existing indexers keep their health unless the user re-enabled
    /// one that had been auto-disabled.
    public func setIndexers(_ definitions: [IndexerDefinition]) async {
        let ids = Set(definitions.map(\.id))
        for id in entries.keys where !ids.contains(id) { entries[id] = nil }
        for definition in definitions { await upsert(definition) }
    }

    public func upsert(_ definition: IndexerDefinition) async {
        if var entry = entries[definition.id] {
            let wasAutoDisabled = entry.health.isAutoDisabled
            if wasAutoDisabled, definition.enabled {
                entry.health = IndexerHealth()
                emit(.reenabled(indexerID: definition.id, name: definition.name))
            }
            entry.definition = definition
            entries[definition.id] = entry
            await entry.client.update(definition: definition)
        } else {
            let client = IndexerClient(
                definition: definition, secrets: secrets, transport: transport, clock: clock,
                configuration: clientConfiguration)
            entries[definition.id] = Entry(definition: definition, client: client)
        }
    }

    public func remove(id: UUID) {
        entries[id] = nil
    }

    public var indexers: [IndexerDefinition] {
        entries.values.map(\.definition).sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
    }

    public func health(for id: UUID) -> IndexerHealth? { entries[id]?.health }

    public func allHealth() -> [UUID: IndexerHealth] { entries.mapValues(\.health) }

    /// Re-enables an auto-disabled indexer and clears its failure streak.
    public func reenable(id: UUID) async {
        guard var entry = entries[id] else { return }
        entry.definition.enabled = true
        entry.health = IndexerHealth()
        entries[id] = entry
        await entry.client.update(definition: entry.definition)
        emit(.reenabled(indexerID: id, name: entry.definition.name))
    }

    // MARK: Events

    /// A new stream of health events. Each call gets its own stream.
    public func events() -> AsyncStream<IndexerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<IndexerEvent>.makeStream(bufferingPolicy: .unbounded)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func emit(_ event: IndexerEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: Search

    private struct Attempt: Sendable {
        var indexerID: UUID
        var name: String
        var result: Result<IndexerSearchResponse, IndexerError>
        var latency: TimeInterval
    }

    /// Searches all enabled indexers (optionally narrowed by ids or tags) in parallel.
    public func search(
        _ query: TorznabQuery, indexerIDs: Set<UUID>? = nil, tags: Set<String>? = nil
    ) async -> CoordinatedSearchResult {
        let targets = entries.values.filter { entry in
            guard entry.definition.enabled else { return false }
            if let indexerIDs, !indexerIDs.contains(entry.definition.id) { return false }
            if let tags, tags.isDisjoint(with: entry.definition.tags) { return false }
            return true
        }
        let timeout = configuration.perIndexerTimeout
        let clock = self.clock

        let attempts = await withTaskGroup(of: Attempt.self) { group in
            for entry in targets {
                let client = entry.client
                let id = entry.definition.id
                let name = entry.definition.name
                group.addTask {
                    let started = clock.now()
                    let result: Result<IndexerSearchResponse, IndexerError>
                    do {
                        let response = try await Self.withTimeout(seconds: timeout, clock: clock) {
                            try await client.search(query)
                        }
                        result = .success(response)
                    } catch let error as IndexerError {
                        result = .failure(error)
                    } catch is CancellationError {
                        result = .failure(.cancelled)
                    } catch {
                        result = .failure(.network(SecretRedactor.redact(String(describing: error))))
                    }
                    return Attempt(indexerID: id, name: name, result: result, latency: max(0, clock.now() - started))
                }
            }
            var collected: [Attempt] = []
            for await attempt in group { collected.append(attempt) }
            return collected
        }

        var all: [IndexerRelease] = []
        var outcomes: [IndexerSearchOutcome] = []
        for attempt in attempts {
            switch attempt.result {
            case .success(let response):
                all += response.releases
                record(success: attempt.latency, for: attempt.indexerID)
                outcomes.append(IndexerSearchOutcome(
                    indexerID: attempt.indexerID, indexerName: attempt.name,
                    status: .success(releaseCount: response.releases.count), latency: attempt.latency,
                    skippedItems: response.skippedItems, isPartial: response.isPartial))
            case .failure(let error):
                record(failure: error, for: attempt.indexerID)
                outcomes.append(IndexerSearchOutcome(
                    indexerID: attempt.indexerID, indexerName: attempt.name, status: .failure(error),
                    latency: attempt.latency, skippedItems: 0, isPartial: false))
            }
        }
        outcomes.sort { $0.indexerName.localizedStandardCompare($1.indexerName) == .orderedAscending }

        let priorities = entries.mapValues(\.definition.priority)
        let priority: (UUID) -> Int = { priorities[$0] ?? 25 }
        let (deduped, removed) = ReleaseDeduplicator.deduplicate(all, priority: priority)
        return CoordinatedSearchResult(
            releases: ReleaseDeduplicator.sortBySeeders(deduped, priority: priority),
            outcomes: outcomes, duplicatesRemoved: removed)
    }

    /// Runs `IndexerClient.test()` on every enabled indexer in parallel ("Test all"). Does not touch health stats.
    public func testAll(includeDisabled: Bool = false) async -> [IndexerTestOutcome] {
        let targets = entries.values.filter { includeDisabled || $0.definition.enabled }
        let timeout = configuration.perIndexerTimeout
        let clock = self.clock
        return await withTaskGroup(of: IndexerTestOutcome.self) { group in
            for entry in targets {
                let client = entry.client
                let id = entry.definition.id
                let name = entry.definition.name
                group.addTask {
                    do {
                        let result = try await Self.withTimeout(seconds: timeout, clock: clock) { try await client.test() }
                        return IndexerTestOutcome(indexerID: id, indexerName: name, result: .success(result))
                    } catch let error as IndexerError {
                        return IndexerTestOutcome(indexerID: id, indexerName: name, result: .failure(error))
                    } catch is CancellationError {
                        return IndexerTestOutcome(indexerID: id, indexerName: name, result: .failure(.cancelled))
                    } catch {
                        return IndexerTestOutcome(
                            indexerID: id, indexerName: name,
                            result: .failure(.network(SecretRedactor.redact(String(describing: error)))))
                    }
                }
            }
            var out: [IndexerTestOutcome] = []
            for await outcome in group { out.append(outcome) }
            return out.sorted { $0.indexerName.localizedStandardCompare($1.indexerName) == .orderedAscending }
        }
    }

    // MARK: Health bookkeeping

    private func record(success latency: TimeInterval, for id: UUID) {
        entries[id]?.health.recordSuccess(latency: latency)
    }

    private func record(failure error: IndexerError, for id: UUID) {
        guard error.countsAgainstHealth, var entry = entries[id] else { return }
        entry.health.recordFailure(error)
        if entry.definition.enabled, entry.health.consecutiveFailures >= configuration.failureThreshold {
            entry.definition.enabled = false
            entry.health.isAutoDisabled = true
            entries[id] = entry
            let definition = entry.definition
            emit(.autoDisabled(
                indexerID: id, name: definition.name,
                consecutiveFailures: entry.health.consecutiveFailures, lastError: error))
        } else {
            entries[id] = entry
        }
    }

    // MARK: Timeout

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval, clock: IndexerClock, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: seconds)
                throw IndexerError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw IndexerError.timeout }
            return first
        }
    }
}
