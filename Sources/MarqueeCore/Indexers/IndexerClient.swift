import Foundation

// MARK: - Configuration

public struct IndexerClientConfiguration: Sendable, Equatable {
    /// Per-request network timeout.
    public var requestTimeout: TimeInterval = 20
    /// Total attempts per request (1 = no retries) for 429 / 5xx / timeouts.
    public var maxAttempts: Int = 3
    public var backoffBase: TimeInterval = 1
    public var backoffMax: TimeInterval = 30
    /// 0...1. 0.5 means each delay is randomised within [50%, 100%] of the exponential value.
    public var backoffJitter: Double = 0.5
    public var capsTTL: TimeInterval = 24 * 3600
    public var maxResponseBytes: Int = 32 * 1024 * 1024
    public var defaultLimit: Int = 100
    public var prowlarrConcurrency: Int = 10
    public var userAgent: String = "Marquee"

    public init() {}
}

/// Exponential backoff with jitter. Pure so it is trivially testable.
public enum IndexerBackoff {
    /// - Parameter attempt: 0 for the delay after the first failure, 1 after the second, ...
    /// - Parameter random: a value in 0...1.
    public static func delay(
        attempt: Int, base: TimeInterval, max maxDelay: TimeInterval, jitter: Double, random: Double
    ) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 30))
        let raw = min(maxDelay, base * pow(2, exponent))
        let j = min(max(jitter, 0), 1)
        let r = min(max(random, 0), 1)
        return raw * (1 - j + j * r)
    }

    /// Parses `Retry-After` as delta-seconds or an HTTP date.
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0, seconds.isFinite { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }
}

/// Token bucket. Negative token counts represent queued reservations, so concurrent callers
/// get properly staggered waits instead of all being released together.
struct TokenBucket {
    private(set) var capacity: Double
    private(set) var interval: TimeInterval
    private var tokens: Double
    private var lastUpdate: TimeInterval
    private var blockedUntil: TimeInterval = 0

    init(limit: IndexerRateLimit, now: TimeInterval) {
        capacity = Double(limit.burst)
        interval = limit.minInterval
        tokens = capacity
        lastUpdate = now
    }

    /// Reserves one request slot and returns how long the caller must wait before sending.
    mutating func reserve(now: TimeInterval) -> TimeInterval {
        var wait: TimeInterval = 0
        if interval > 0 {
            tokens = min(capacity, tokens + max(0, now - lastUpdate) / interval)
            lastUpdate = now
            tokens -= 1
            if tokens < 0 { wait = -tokens * interval }
        }
        return max(wait, blockedUntil - now, 0)
    }

    /// Server told us to back off (Retry-After); nothing is sent before `time`.
    mutating func block(until time: TimeInterval) {
        blockedUntil = max(blockedUntil, time)
    }
}

// MARK: - Results

public struct IndexerSearchResponse: Sendable, Equatable {
    public var releases: [IndexerRelease]
    /// Total matches the indexer reports, if it says.
    public var totalAvailable: Int?
    public var offset: Int?
    public var skippedItems: Int
    /// The feed was damaged part-way; `releases` holds what could be read.
    public var isPartial: Bool
    /// Releases removed by the indexer's minimum-seeders setting.
    public var filteredBySeeders: Int
    /// The indexer lacked the right search type/ids so text search was used.
    public var usedTextFallback: Bool
    /// Seconds spent in the final HTTP round trip (excludes pacing waits).
    public var latency: TimeInterval
}

public struct IndexerTestResult: Sendable, Equatable {
    public var latency: TimeInterval
    public var capabilities: TorznabCapabilities
    public var sampleReleaseCount: Int
}

// MARK: - Client

/// Talks to one Torznab indexer: capabilities, searches, pacing, retries.
public actor IndexerClient {
    public private(set) var definition: IndexerDefinition

    private let secrets: SecretStore
    private let transport: IndexerTransport
    private let clock: IndexerClock
    private let configuration: IndexerClientConfiguration
    private let random: @Sendable () -> Double

    private var bucket: TokenBucket
    private var cachedCaps: (caps: TorznabCapabilities, fetchedAt: TimeInterval)?
    private var capsTask: Task<TorznabCapabilities, Error>?
    private var torlockResponseCache: [URL: (data: Data, expiresAt: TimeInterval)] = [:]

    public init(
        definition: IndexerDefinition,
        secrets: SecretStore,
        transport: IndexerTransport = FlareSolverrIndexerTransport(),
        clock: IndexerClock = SystemIndexerClock(),
        configuration: IndexerClientConfiguration = IndexerClientConfiguration(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.definition = definition
        self.secrets = secrets
        self.transport = transport
        self.clock = clock
        self.configuration = configuration
        self.random = random
        self.bucket = TokenBucket(limit: definition.rateLimit, now: clock.now())
    }

    /// Applies edited settings. Pacing resets when the rate limit changes; cached capabilities are
    /// dropped when the address changes.
    public func update(definition new: IndexerDefinition) {
        if new.rateLimit != definition.rateLimit { bucket = TokenBucket(limit: new.rateLimit, now: clock.now()) }
        if new.baseURL != definition.baseURL || new.apiPath != definition.apiPath || new.id != definition.id {
            cachedCaps = nil
            capsTask?.cancel()
            capsTask = nil
        }
        if new.implementation != definition.implementation {
            cachedCaps = nil
            capsTask?.cancel()
            capsTask = nil
        }
        definition = new
    }

    // MARK: Capabilities

    public func capabilities(forceRefresh: Bool = false) async throws -> TorznabCapabilities {
        if !forceRefresh, let cached = cachedCaps, clock.now() - cached.fetchedAt < configuration.capsTTL {
            return cached.caps
        }
        if !forceRefresh, let capsTask { return try await capsTask.value }

        let task = Task { try await self.fetchCapabilities() }
        capsTask = task
        defer { capsTask = nil }
        // The first caller owns the request: cancelling it cancels the fetch.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func fetchCapabilities() async throws -> TorznabCapabilities {
        let key = try apiKey()
        return try await redactingErrors(key) {
            if definition.implementation == "torlock" {
                let caps = Self.basicTextCapabilities(serverTitle: "TorLock")
                cachedCaps = (caps, clock.now())
                return caps
            }
            if definition.implementation == "prowlarr" {
                guard let key, !key.isEmpty else {
                    throw IndexerError.invalidConfiguration("Enter the Prowlarr API key.")
                }
                let url = try ProwlarrAPIEndpoint.url(server: definition.baseURL, endpoint: "indexer")
                let (data, _) = try await fetch(url, key: key)
                _ = try Self.parseProwlarrIndexers(data)
                let caps = TorznabCapabilities(
                    serverTitle: "Prowlarr",
                    searchModes: [
                        "search": TorznabSearchMode(available: true, supportedParams: ["q"]),
                        "tv-search": TorznabSearchMode(available: true, supportedParams: ["q"]),
                        "movie-search": TorznabSearchMode(available: true, supportedParams: ["q"]),
                    ])
                cachedCaps = (caps, clock.now())
                return caps
            }
            let url = try TorznabEndpoint.url(definition: definition, function: "caps", parameters: [], apiKey: key)
            let (data, _) = try await fetch(url, key: key)
            let caps = try TorznabCapabilities.parse(data)
            cachedCaps = (caps, clock.now())
            return caps
        }
    }

    // MARK: Search

    public func search(_ query: TorznabQuery) async throws -> IndexerSearchResponse {
        if definition.implementation == "prowlarr" { return try await searchProwlarr(query) }
        if let provider = BuiltInProvider(rawValue: definition.implementation) {
            return try await searchBuiltIn(provider, query: query)
        }
        let caps = try await capabilities()
        let plan = try TorznabQueryBuilder.plan(
            for: query, definition: definition, capabilities: caps, defaultLimit: configuration.defaultLimit)
        let key = try apiKey()
        return try await redactingErrors(key) {
            let url = try TorznabEndpoint.url(
                definition: definition, function: plan.function.tParameter, parameters: plan.parameters, apiKey: key)
            let (data, latency) = try await fetch(url, key: key)
            let feed = try TorznabResultParser.parse(data, indexerID: definition.id, indexerName: definition.name)

            var releases = feed.releases
            var filtered = 0
            if definition.minimumSeeders > 0 {
                let minimum = definition.minimumSeeders
                releases = releases.filter { ($0.seeders ?? Int.max) >= minimum }
                filtered = feed.releases.count - releases.count
            }
            return IndexerSearchResponse(
                releases: releases, totalAvailable: feed.total, offset: feed.offset,
                skippedItems: feed.skippedItems, isPartial: feed.isPartial, filteredBySeeders: filtered,
                usedTextFallback: plan.usedTextFallback, latency: latency)
        }
    }

    /// Verifies address, API key and search in one go: fresh capabilities plus a one-result search.
    public func test() async throws -> IndexerTestResult {
        if let provider = BuiltInProvider(rawValue: definition.implementation) {
            let response = try await search(.generic("ubuntu", limit: 1))
            return IndexerTestResult(
                latency: response.latency, capabilities: Self.basicTextCapabilities(serverTitle: provider.name),
                sampleReleaseCount: response.releases.count)
        }
        let caps = try await capabilities(forceRefresh: true)
        let response = try await search(.generic(nil, limit: 1))
        return IndexerTestResult(latency: response.latency, capabilities: caps, sampleReleaseCount: response.releases.count)
    }

    // MARK: Prowlarr REST API

    private static func basicTextCapabilities(serverTitle: String) -> TorznabCapabilities {
        TorznabCapabilities(
            serverTitle: serverTitle,
            searchModes: ["search": TorznabSearchMode(available: true, supportedParams: ["q"])])
    }

    private func searchBuiltIn(_ provider: BuiltInProvider, query: TorznabQuery) async throws -> IndexerSearchResponse {
        let started = clock.now()
        if query.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            !(provider == .eztv && query.imdbID != nil)
        {
            return IndexerSearchResponse(
                releases: [], totalAvailable: nil, offset: nil, skippedItems: 0, isPartial: false,
                filteredBySeeders: 0, usedTextFallback: false, latency: max(0, clock.now() - started))
        }
        let url = try BuiltInProviderSearch.url(provider: provider, server: definition.baseURL, query: query)
        let key = try apiKey()
        let (data, _) = try await redactingErrors(key) { try await fetch(url, key: key) }
        var releases = try BuiltInProviderSearch.parse(
            data, provider: provider, indexerID: definition.id, indexerName: definition.name,
            query: query, server: definition.baseURL)
        var filtered = 0
        if definition.minimumSeeders > 0 {
            releases = releases.filter { release in
                guard let seeds = release.seeders else { return true }
                let keep = seeds >= definition.minimumSeeders
                if !keep { filtered += 1 }
                return keep
            }
        }
        return IndexerSearchResponse(
            releases: releases, totalAvailable: nil, offset: nil, skippedItems: 0, isPartial: false,
            filteredBySeeders: filtered, usedTextFallback: false, latency: max(0, clock.now() - started))
    }

    private struct ProwlarrIndexer: Sendable {
        var id: Int
        var enabled: Bool
        var isUsenet: Bool
    }

    private struct ProwlarrAttempt: Sendable {
        var result: Result<(Data, TimeInterval), IndexerError>
    }

    private func searchProwlarr(_ query: TorznabQuery) async throws -> IndexerSearchResponse {
        guard let key = try apiKey(), !key.isEmpty else {
            throw IndexerError.invalidConfiguration("Enter the Prowlarr API key.")
        }
        return try await redactingErrors(key) {
            let started = clock.now()
            let indexersURL = try ProwlarrAPIEndpoint.url(server: definition.baseURL, endpoint: "indexer")
            let (indexersData, _) = try await fetch(indexersURL, key: key)
            let indexers = try Self.parseProwlarrIndexers(indexersData)
                .filter { $0.enabled && !$0.isUsenet }
            let categories = Self.prowlarrCategories(for: query)
            let targets = indexers.isEmpty ? ["-2"] : indexers.map { String($0.id) }
            let maxConcurrent = max(1, configuration.prowlarrConcurrency)
            let server = definition.baseURL

            let attempts = await withTaskGroup(of: ProwlarrAttempt.self) { group in
                var next = 0
                let initialCount = min(targets.count, maxConcurrent)
                for _ in 0..<initialCount {
                    let target = targets[next]
                    next += 1
                    group.addTask {
                        await self.fetchProwlarrTarget(
                            query, indexerID: target, categories: categories, server: server, key: key)
                    }
                }
                var results: [ProwlarrAttempt] = []
                while let result = await group.next() {
                    results.append(result)
                    if next < targets.count {
                        let target = targets[next]
                        next += 1
                        group.addTask {
                            await self.fetchProwlarrTarget(
                                query, indexerID: target, categories: categories, server: server, key: key)
                        }
                    }
                }
                return results
            }

            var releases: [IndexerRelease] = []
            var failed = 0
            var firstError: IndexerError?
            for attempt in attempts {
                switch attempt.result {
                case .success(let (data, _)):
                    releases += try ProwlarrResultParser.parse(data, indexerID: definition.id)
                case .failure(let error):
                    failed += 1
                    firstError = firstError ?? error
                }
            }
            guard failed < attempts.count else { throw firstError ?? IndexerError.network("Prowlarr search failed.") }

            var filtered = 0
            if definition.minimumSeeders > 0 {
                releases = releases.filter { release in
                    guard let seeds = release.seeders else { return true }
                    let keep = seeds >= definition.minimumSeeders
                    if !keep { filtered += 1 }
                    return keep
                }
            }
            return IndexerSearchResponse(
                releases: releases, totalAvailable: nil, offset: nil, skippedItems: 0, isPartial: failed > 0,
                filteredBySeeders: filtered, usedTextFallback: false, latency: max(0, clock.now() - started))
        }
    }

    private func fetchProwlarrTarget(
        _ query: TorznabQuery, indexerID: String, categories: [Int], server: URL, key: String
    ) async -> ProwlarrAttempt {
        do {
            let url = try ProwlarrAPIEndpoint.url(
                server: server, endpoint: "search",
                query: Self.prowlarrQuery(query, indexerID: indexerID, categories: categories))
            return ProwlarrAttempt(result: .success(try await fetch(url, key: key)))
        } catch let error as IndexerError {
            return ProwlarrAttempt(result: .failure(error))
        } catch is CancellationError {
            return ProwlarrAttempt(result: .failure(.cancelled))
        } catch {
            return ProwlarrAttempt(result: .failure(.network(String(describing: error))))
        }
    }

    private static func parseProwlarrIndexers(_ data: Data) throws -> [ProwlarrIndexer] {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch {
            if ProwlarrResultParser.looksLikeHTML(data) {
                throw IndexerError.malformedResponse(
                    "Prowlarr returned an HTML page instead of JSON. Check the URL base, reverse proxy, or access challenge.")
            }
            throw IndexerError.malformedResponse("Prowlarr returned invalid JSON while listing indexers.")
        }
        guard let values = object as? [[String: Any]] else {
            if let response = object as? [String: Any], let message = response["message"] as? String {
                throw IndexerError.apiError(code: 900, description: SecretRedactor.redact(message))
            }
            throw IndexerError.malformedResponse("Prowlarr returned an unexpected indexer list.")
        }
        return values.compactMap { item in
            guard let idValue = item["id"] else { return nil }
            let id: Int?
            if let number = idValue as? NSNumber { id = number.intValue }
            else if let string = idValue as? String { id = Int(string) }
            else { id = nil }
            guard let id else { return nil }
            let protocolValue = String(describing: item["protocol"] ?? "").lowercased()
            let enabled = (item["enable"] as? Bool) ?? ((item["enable"] as? NSNumber)?.boolValue ?? false)
            return ProwlarrIndexer(
                id: id, enabled: enabled, isUsenet: protocolValue == "usenet" || protocolValue == "2")
        }
    }

    private static func prowlarrCategories(for query: TorznabQuery) -> [Int] {
        if let categories = query.categories, !categories.isEmpty { return categories }
        switch query.kind {
        case .generic: return []
        case .tv: return [5000]
        case .movie: return [2000]
        }
    }

    private static func prowlarrQuery(
        _ query: TorznabQuery, indexerID: String, categories: [Int]
    ) -> [URLQueryItem] {
        var text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.kind == .tv, let season = query.season {
            text += String(format: " S%02d", season)
            if let episode = query.episode { text += String(format: "E%02d", episode) }
        } else if query.kind == .movie, let year = query.year {
            text += " \(year)"
        }
        var items = [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "type", value: "search"),
            URLQueryItem(name: "indexerIds", value: indexerID),
        ]
        items += categories.map { URLQueryItem(name: "categories", value: String($0)) }
        if let limit = query.limit { items.append(URLQueryItem(name: "limit", value: String(max(1, limit)))) }
        if let offset = query.offset, offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        return items
    }

    // MARK: Internals

    private func apiKey() throws -> String? {
        do {
            return try secrets.get(account: definition.apiKeyAccount)
        } catch {
            throw IndexerError.invalidConfiguration("The API key couldn't be read.")
        }
    }

    private func redactingErrors<T: Sendable>(_ key: String?, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as IndexerError {
            throw error.redacted(secrets: key.map { [$0] } ?? [])
        }
    }

    /// Paces, sends, and retries transient failures with exponential backoff and jitter.
    private func fetch(_ url: URL, key: String?) async throws -> (Data, TimeInterval) {
        if definition.implementation == "torlock",
            let cached = torlockResponseCache[url], cached.expiresAt > clock.now()
        {
            return (cached.data, 0)
        }
        var headers = ["User-Agent": configuration.userAgent]
        if definition.implementation == "prowlarr" {
            headers["Accept"] = "application/json"
            if let key, !key.isEmpty { headers["X-Api-Key"] = key }
        } else if BuiltInProvider(rawValue: definition.implementation) != nil {
            headers["Accept"] = "application/json, application/rss+xml, application/xml, text/html, */*"
        }
        let request = IndexerHTTPRequest(
            url: url, timeout: max(configuration.requestTimeout, definition.flareSolverrURL == nil ? 0 : 90),
            headers: headers,
            flareSolverrURL: definition.implementation == "prowlarr" ? nil : definition.flareSolverrURL)
        var attempt = 0
        while true {
            let wait = bucket.reserve(now: clock.now())
            if wait > 0 { try await clock.sleep(for: wait) }

            let started = clock.now()
            var failure: IndexerError
            var retryAfter: TimeInterval?
            do {
                let response = try await transport.send(request)
                if (200..<300).contains(response.statusCode) {
                    guard response.body.count <= configuration.maxResponseBytes else { throw IndexerError.responseTooLarge }
                    if definition.implementation == "torlock" {
                        torlockResponseCache = torlockResponseCache.filter { $0.value.expiresAt > clock.now() }
                        if torlockResponseCache.count >= 128, let oldest = torlockResponseCache.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
                            torlockResponseCache[oldest.key] = nil
                        }
                        torlockResponseCache[url] = (response.body, clock.now() + 60)
                    }
                    return (response.body, max(0, clock.now() - started))
                }
                retryAfter = IndexerBackoff.parseRetryAfter(response.header("Retry-After"))
                failure = Self.error(forStatus: response.statusCode, retryAfter: retryAfter)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as IndexerError {
                failure = error
            } catch let error as URLError {
                failure = Self.error(for: error)
                if error.code == .cancelled { throw CancellationError() }
            } catch {
                failure = .network(SecretRedactor.redact(String(describing: error), secrets: key.map { [$0] } ?? []))
            }

            guard failure.isRetryable, attempt + 1 < max(1, configuration.maxAttempts) else { throw failure }

            var delay = IndexerBackoff.delay(
                attempt: attempt, base: configuration.backoffBase, max: configuration.backoffMax,
                jitter: configuration.backoffJitter, random: random())
            if let retryAfter {
                // A server asking for longer than we're willing to wait gets reported, not waited on.
                guard retryAfter <= configuration.backoffMax else { throw failure }
                delay = max(delay, retryAfter)
                bucket.block(until: clock.now() + delay)
            }
            try await clock.sleep(for: delay)
            attempt += 1
        }
    }

    static func error(forStatus status: Int, retryAfter: TimeInterval?) -> IndexerError {
        switch status {
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 401: return .authenticationFailed(detail: "HTTP 401")
        case 500...599: return .serverError(status: status)
        default: return .httpStatus(status)
        }
    }

    static func error(for urlError: URLError) -> IndexerError {
        switch urlError.code {
        case .timedOut: return .timeout
        default: return .network(SecretRedactor.redact(urlError.localizedDescription))
        }
    }
}
