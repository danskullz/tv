import Foundation

/// The outcome of a check.
public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate(latest: UpdateVersion?)
    case available(AppcastRelease)

    public var release: AppcastRelease? {
        if case .available(let release) = self { return release }
        return nil
    }
}

/// Decides whether a newer build exists, at most once a day.
///
/// An actor rather than a `@MainActor` type: the check is network I/O, and the rule that an app
/// costs nothing while idle starts with not waking the main thread to find out nothing changed.
public actor UpdateChecker {
    /// The project's own update feed.
    public static let defaultFeedURL = URL(string: "https://tv.guihot.net/appcast.json")!

    /// Checks at most this often unless the user asks.
    public static let defaultInterval: TimeInterval = 24 * 60 * 60
    /// After a failure, retry sooner — but still not on every launch.
    public static let retryInterval: TimeInterval = 60 * 60

    public let currentVersion: UpdateVersion
    public let feedURL: URL

    private let fetcher: AppcastFetcher
    private let preferences: UpdatePreferences
    private let clock: any UpdateClock
    private let interval: TimeInterval
    private let retryInterval: TimeInterval
    private var inFlight: Task<UpdateCheckResult, Error>?

    public init(
        currentVersion: UpdateVersion,
        feedURL: URL = UpdateChecker.defaultFeedURL,
        origin: URL? = nil,
        keyring: AppcastKeyring,
        transport: any UpdateTransport = URLSessionUpdateTransport(),
        preferences: UpdatePreferences = UpdatePreferences(),
        clock: any UpdateClock = SystemUpdateClock(),
        interval: TimeInterval = UpdateChecker.defaultInterval,
        retryInterval: TimeInterval = UpdateChecker.retryInterval
    ) {
        self.currentVersion = currentVersion
        self.feedURL = feedURL
        self.fetcher = AppcastFetcher(
            transport: transport,
            keyring: keyring,
            origin: origin ?? URLComponents(url: feedURL, resolvingAgainstBaseURL: false).flatMap {
                var c = $0
                c.path = ""
                c.query = nil
                c.fragment = nil
                return c.url
            } ?? feedURL)
        self.preferences = preferences
        self.clock = clock
        self.interval = interval
        self.retryInterval = retryInterval
    }

    /// True when enough time has passed to justify another request. A failed attempt cools down faster
    /// than a successful one, so a transient blip costs an hour rather than a whole day, while a
    /// machine that is simply offline doesn't ask on every launch.
    public func isDue() -> Bool {
        guard let last = preferences.lastCheckAt else { return true }
        let succeededLastTime = preferences.lastSuccessAt.map { $0 >= last } ?? false
        let cooldown = succeededLastTime ? interval : retryInterval
        return clock.now().timeIntervalSince(last) >= cooldown
    }

    /// - Parameter force: set for an explicit "Check for Updates…"; skips the throttle but not the
    ///   signature verification, and still shares an in-flight request rather than starting a second.
    @discardableResult
    public func check(force: Bool = false) async throws -> UpdateCheckResult {
        // Several screens asking at once share one request rather than each hitting the feed.
        if let inFlight { return try await inFlight.value }
        guard force || isDue() else { return .upToDate(latest: preferences.lastKnownVersion) }
        let task = Task<UpdateCheckResult, Error> { [self] in try await runOnce() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Every attempt stamps the clock, successful or not.
    private func runOnce() async throws -> UpdateCheckResult {
        var succeeded = false
        defer { preferences.recordCheck(at: clock.now(), succeeded: succeeded) }
        let result = try await perform()
        succeeded = true
        return result
    }

    private func perform() async throws -> UpdateCheckResult {
        switch try await fetcher.fetch(manifestURL: feedURL, etag: preferences.etag) {
        case .notModified:
            return .upToDate(latest: preferences.lastKnownVersion)
        case .verified(let appcast, let etag):
            preferences.etag = etag
            let newest = appcast.sortedReleases.first?.version
            preferences.lastKnownVersion = newest
            let update = appcast.update(
                from: currentVersion,
                channel: preferences.channel,
                skipping: preferences.skippedVersion)
            return update.map(UpdateCheckResult.available) ?? .upToDate(latest: newest)
        }
    }

    /// Never offers this version again, even on an explicit check.
    public func skip(_ version: UpdateVersion) {
        preferences.skippedVersion = version
    }

    /// Forgets the skipped version and the cached validator.
    public func reset() {
        preferences.reset()
    }
}