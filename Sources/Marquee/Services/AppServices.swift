import AppKit
import Foundation
import MarqueeCore
import MarqueeEngine
import MarqueePlayer
import Observation
import Synchronization
import TorrentEngine

/// Lazily creates the one torrent session and stream server. Nothing runs until the first Play.
final class EngineHost: Sendable {
    let server = StreamServer()
    private let state = Mutex<TorrentSession?>(nil)

    /// The session if one has been started.
    var current: TorrentSession? { state.withLock { $0 } }

    func session(loopbackOnly: Bool) throws -> TorrentSession {
        try state.withLock { current in
            if let current { return current }
            var configuration = loopbackOnly ? SessionConfiguration.loopbackOnly() : SessionConfiguration()
            configuration.userAgent = "Marquee/\(AppInfo.version)"
            let session = try TorrentSession(configuration: configuration)
            current = session
            return session
        }
    }

    func shutdown() async {
        let session = state.withLock { current -> TorrentSession? in
            defer { current = nil }
            return current
        }
        await server.stop()
        await session?.shutdown()
    }
}

/// Owns everything behind the UI: database, metadata, indexers, the torrent engine and the Play
/// pipeline. Heavy parts are created on first use, so an idle app costs nothing beyond the database.
@MainActor
@Observable
final class AppServices {
    // MARK: Storage

    nonisolated let isDemo: Bool
    nonisolated let usesTMDBFixtures: Bool
    nonisolated let database: AppDatabase
    nonisolated let secrets: any SecretStore
    nonisolated let library: GRDBLibraryRepository
    nonisolated let watchStates: GRDBWatchStateRepository
    nonisolated let history: GRDBHistoryRepository
    nonisolated let indexerRecords: GRDBIndexerRepository
    nonisolated let blocklist: GRDBBlocklistRepository
    nonisolated let grabs: GRDBGrabRepository
    nonisolated let torrents: GRDBTorrentRepository
    nonisolated let health: GRDBHealthIssueRepository
    nonisolated let importCoordinator: ImportCoordinator
    nonisolated let localMediaResolver: LocalMediaResolver

    // MARK: Engine

    @ObservationIgnored nonisolated let coordinator: IndexerSearchCoordinator
    @ObservationIgnored nonisolated let engineHost = EngineHost()
    @ObservationIgnored nonisolated let monitor: DownloadMonitor
    @ObservationIgnored private var downloads: DownloadManager?
    @ObservationIgnored private var automation: ReleaseAutomation?
    @ObservationIgnored private var pipeline: PlayPipeline?
    /// Plays in flight (kept alive until their last player window closes).
    @ObservationIgnored var activePlaybacks: [ActivePlayback] = []
    @ObservationIgnored private var tmdbClient: (key: String, client: TMDBClient)?
    @ObservationIgnored private(set) var demoSwarm: DemoSwarm?
    @ObservationIgnored var announce: @MainActor (_ title: String, _ detail: String?, _ systemImage: String) -> Void = { _, _, _ in }
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var importEventTask: Task<Void, Never>?

    // MARK: Observable status (first-run checklist, Settings)

    private(set) var indexerCount = 0
    private(set) var hasMetadataKey = false
    /// Bumped whenever the library changes, so screens reload.
    private(set) var libraryRevision = 0

    nonisolated static let tmdbAccount = "tmdb.credential"

    // MARK: Init

    init(demo: Bool = false, tmdbFixtures: Bool = false, database: AppDatabase? = nil, secrets: (any SecretStore)? = nil) throws {
        isDemo = demo
        usesTMDBFixtures = tmdbFixtures
        let db: AppDatabase
        if let database {
            db = database
        } else if demo {
            // Demo mode never touches the user's real library or Keychain.
            let url = Self.demoDirectory.appendingPathComponent("marquee-demo.sqlite")
            // Fresh library and downloads every launch; the generated clips are kept.
            let fm = FileManager.default
            for name in ["marquee-demo.sqlite", "marquee-demo.sqlite-wal", "marquee-demo.sqlite-shm", "downloads", "Library"] {
                try? fm.removeItem(at: Self.demoDirectory.appendingPathComponent(name))
            }
            db = try AppDatabase.onDisk(at: url)
        } else {
            db = try AppDatabase.openDefault()
        }
        self.database = db
        self.secrets = secrets ?? (demo ? InMemorySecretStore() : KeychainSecretStore())
        library = GRDBLibraryRepository(db)
        watchStates = GRDBWatchStateRepository(db)
        history = GRDBHistoryRepository(db)
        indexerRecords = GRDBIndexerRepository(db)
        blocklist = GRDBBlocklistRepository(db)
        grabs = GRDBGrabRepository(db)
        torrents = GRDBTorrentRepository(db)
        health = GRDBHealthIssueRepository(db)
        localMediaResolver = LocalMediaResolver(database: db)
        importCoordinator = ImportCoordinator(
            database: db, probe: AppMediaProbe(), rootDirectory: {
                (demo ? Self.demoDirectory : AppSettings.downloadFolder)
                    .appendingPathComponent("Library", isDirectory: true)
            })
        coordinator = IndexerSearchCoordinator(secrets: self.secrets)
        let host = engineHost
        monitor = DownloadMonitor(session: { host.current }, torrents: GRDBTorrentRepository(db))
        let importEvents = importCoordinator.events()
        importEventTask = Task { @MainActor [weak self] in
            for await event in importEvents {
                guard case .imported = event else { continue }
                self?.libraryChanged()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownBlocking() }
        }
    }

    nonisolated static var demoDirectory: URL {
        URL.cachesDirectory.appending(path: "Marquee/DemoSwarm", directoryHint: .isDirectory)
    }

    /// Where torrents are written: the user's folder, or a scratch folder in demo mode.
    nonisolated var downloadFolder: URL {
        isDemo ? Self.demoDirectory.appendingPathComponent("downloads", isDirectory: true) : AppSettings.downloadFolder
    }

    /// Cheap start-up work: reads status for the first-run checklist, and brings the demo swarm up.
    func prepare() async {
        if !isDemo {
            do {
                _ = try await DefaultIndexerProviderSeeder.installIfNeeded(into: indexerRecords)
            } catch {
                announce("Couldn't install default providers", error.localizedDescription, "exclamationmark.triangle")
            }
        }
        if isDemo, demoSwarm == nil {
            do {
                let swarm = try await DemoSwarm.start(
                    directory: Self.demoDirectory.appendingPathComponent("swarm", isDirectory: true),
                    options: Self.demoOptions)
                try await swarm.install(into: database, secrets: secrets)
                demoSwarm = swarm
                libraryRevision += 1
            } catch {
                announce("Couldn't start the demo content", error.localizedDescription, "exclamationmark.triangle")
            }
        }
        await reloadIndexers()
        if let managed = try? await torrents.managedDownloads(), !managed.isEmpty {
            _ = try? await downloadManager()
        }
        await refreshStatus()
        try? await startAutomaticReleaseAutomation()
    }

    /// `-demoEpisodeSeconds 150` makes the clips long enough for the player's Up Next card (it needs > 2 min).
    private static var demoOptions: DemoSwarm.Options {
        let seconds = UserDefaults.standard.double(forKey: "demoEpisodeSeconds")
        var options = DemoSwarm.Options(
            clipSource: .generate(fallback: bundledFallbackClip), searchLatency: 1.5)
        if seconds > 0 {
            options.episodeSeconds = seconds
            options.width = 640
            options.height = 360
            options.framesPerSecond = 10
        }
        return options
    }

    /// `Contents/Resources/demo-clip.mp4` (a tiny pre-encoded clip), for Macs with no video encoder.
    private static var bundledFallbackClip: URL? {
        Bundle.main.url(forResource: "demo-clip", withExtension: "mp4")
    }

    func refreshStatus() async {
        indexerCount = ((try? await indexerRecords.all()) ?? []).filter(\.enabled).count
        hasMetadataKey = usesTMDBFixtures || (try? secrets.get(account: Self.tmdbAccount)) != nil
    }

    @ObservationIgnored var libraryDidChange: @MainActor () -> Void = {}

    func libraryChanged() {
        libraryRevision += 1
        libraryDidChange()
    }

    func setEpisodeWatched(titleID: UUID, season: Int, episode: Int, _ watched: Bool) async {
        guard let episodes = try? await library.episodes(titleId: titleID),
            let row = episodes.first(where: { $0.seasonNumber == season && $0.episodeNumber == episode })
        else { return }
        try? await watchStates.setWatched(id: row.id, titleId: titleID, watched: watched)
        libraryChanged()
    }

    /// Marks a movie, or every episode of a series, watched or unwatched.
    func setWatched(titleID: UUID, _ watched: Bool) async {
        let ids: [UUID]
        if let episodes = try? await library.episodes(titleId: titleID), !episodes.isEmpty {
            ids = episodes.filter { $0.seasonNumber > 0 }.map(\.id)
        } else {
            ids = [titleID]
        }
        for id in ids { try? await watchStates.setWatched(id: id, titleId: titleID, watched: watched) }
    }

    // MARK: Metadata (TMDB)

    /// The credential saved in the Keychain. A long JWT-looking value is a v4 read token; anything else is a v3 key.
    nonisolated func tmdbCredential() -> TMDBCredential? {
        if usesTMDBFixtures { return .apiKey("fixture-mode") }
        guard let raw = try? secrets.get(account: Self.tmdbAccount), !raw.isEmpty else { return nil }
        return Self.credential(from: raw)
    }

    nonisolated static func credential(from raw: String) -> TMDBCredential {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count > 40 ? .readAccessToken(key) : .apiKey(key)
    }

    func saveTMDBKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.delete(account: Self.tmdbAccount)
        } else {
            try secrets.set(trimmed, account: Self.tmdbAccount)
        }
        tmdbClient = nil
        hasMetadataKey = !trimmed.isEmpty
    }

    /// The shared client, or nil until a key is saved.
    func tmdb() -> TMDBClient? {
        if usesTMDBFixtures {
            if let tmdbClient, tmdbClient.key == "__fixtures__" { return tmdbClient.client }
            let client = TMDBClient(credential: .apiKey("fixture-mode"), transport: FixtureMetadataTransport())
            tmdbClient = ("__fixtures__", client)
            return client
        }
        guard let raw = try? secrets.get(account: Self.tmdbAccount), !raw.isEmpty else { return nil }
        if let tmdbClient, tmdbClient.key == raw { return tmdbClient.client }
        let client = TMDBClient(
            credential: Self.credential(from: raw), cacheDirectory: URL.cachesDirectory.appending(path: "Marquee/TMDB", directoryHint: .isDirectory))
        tmdbClient = (raw, client)
        return client
    }

    /// Checks a key against TMDB without saving it. Plain-language result.
    nonisolated func testTMDBKey(_ key: String) async -> ConnectionResult {
        let client = TMDBClient(credential: Self.credential(from: key))
        do {
            _ = try await client.configuration()
            return ConnectionResult(ok: true, message: "Connected to TMDB. Your key works.")
        } catch let error as MetadataError {
            return ConnectionResult(ok: false, message: error.errorDescription ?? "TMDB couldn't be reached.")
        } catch {
            return ConnectionResult(ok: false, message: "TMDB couldn't be reached. Check your connection and try again.")
        }
    }

    struct ConnectionResult: Sendable {
        var ok: Bool
        var message: String
    }

    // MARK: Indexers

    func indexers() async -> [Indexer] { (try? await indexerRecords.all()) ?? [] }

    /// Pushes the saved indexers to the search coordinator.
    func reloadIndexers() async {
        let records = await indexers()
        await coordinator.setIndexers(records.compactMap(\.definition))
        indexerCount = records.filter(\.enabled).count
    }

    /// Tries an address and key without saving anything.
    nonisolated func testIndexer(url: URL, apiKey: String, flareSolverrURL: URL? = nil) async -> ConnectionResult {
        var definition = IndexerDefinition(name: "Test", baseURL: url)
        if let parsed = Indexer(name: "Test", torznabURL: url, flareSolverrURL: flareSolverrURL).definition {
            definition = parsed
        }
        definition.rateLimit = .unlimited
        let store = InMemorySecretStore([definition.apiKeyAccount: apiKey])
        var configuration = IndexerClientConfiguration()
        configuration.maxAttempts = 1
        let client = IndexerClient(definition: definition, secrets: store, configuration: configuration)
        do {
            let result = try await client.test()
            let kinds = [
                result.capabilities.supports(.tvSearch) ? "TV" : nil,
                result.capabilities.supports(.movieSearch) ? "movie" : nil,
            ].compactMap { $0 }
            let supports = kinds.isEmpty ? "plain text search" : kinds.joined(separator: " and ") + " search"
            let ms = Int((result.latency * 1000).rounded())
            return ConnectionResult(ok: true, message: "Connected in \(ms) ms. Supports \(supports).")
        } catch let error as IndexerError {
            return ConnectionResult(ok: false, message: "\(error.userMessage) Details: \(error.technicalDetail)")
        } catch {
            return ConnectionResult(ok: false, message: "The indexer couldn't be reached.")
        }
    }

    /// Checks a Prowlarr server and key without saving either.
    nonisolated func testProwlarr(url: URL, apiKey: String) async -> ConnectionResult {
        let definition = IndexerDefinition(name: "Prowlarr", baseURL: url, implementation: "prowlarr")
        let store = InMemorySecretStore([definition.apiKeyAccount: apiKey])
        var configuration = IndexerClientConfiguration()
        configuration.maxAttempts = 1
        configuration.prowlarrConcurrency = 1
        let client = IndexerClient(definition: definition, secrets: store, configuration: configuration)
        do {
            let result = try await client.test()
            let ms = Int((result.latency * 1000).rounded())
            return ConnectionResult(
                ok: true, message: "Connected to Prowlarr in \(ms) ms. Found \(result.sampleReleaseCount) sample releases.")
        } catch let error as IndexerError {
            return ConnectionResult(ok: false, message: "\(error.userMessage) Details: \(error.technicalDetail)")
        } catch {
            return ConnectionResult(ok: false, message: "Prowlarr couldn't be reached. Check the address and API key.")
        }
    }

    /// Tests one of Marquee's bundled direct-site adapters without saving the result.
    nonisolated func testBuiltInProvider(_ indexer: Indexer, apiKey: String = "") async -> ConnectionResult {
        guard let definition = indexer.definition,
            BuiltInProvider(rawValue: definition.implementation) != nil
        else {
            return ConnectionResult(ok: false, message: "This isn't a built-in provider Marquee recognizes.")
        }
        let store = InMemorySecretStore(apiKey.isEmpty ? [:] : [definition.apiKeyAccount: apiKey])
        var configuration = IndexerClientConfiguration()
        configuration.maxAttempts = 1
        let client = IndexerClient(definition: definition, secrets: store, configuration: configuration)
        do {
            let result = try await client.test()
            let ms = Int((result.latency * 1000).rounded())
            return ConnectionResult(
                ok: true, message: "Connected in \(ms) ms. Found \(result.sampleReleaseCount) sample releases.")
        } catch let error as IndexerError {
            return ConnectionResult(ok: false, message: "\(error.userMessage) Details: \(error.technicalDetail)")
        } catch {
            return ConnectionResult(ok: false, message: "Marquee couldn't reach this provider.")
        }
    }

    /// Saves the address and API key for a local Prowlarr or Jackett connection.
    func configureRemoteIndexer(_ indexer: Indexer, url: URL, apiKey: String) async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndexerError.invalidConfiguration("Enter the service's API key.")
        }
        var updated = indexer
        updated.baseURL = url.absoluteString
        updated.enabled = true
        guard let account = updated.credentialRef, !account.isEmpty else {
            throw IndexerError.invalidConfiguration("This source has no Keychain credential account.")
        }
        try secrets.set(apiKey, account: account)
        try await indexerRecords.upsert(updated)
        await reloadIndexers()
        try? await startAutomaticReleaseAutomation()
    }

    @discardableResult
    func addIndexer(name: String, url: URL, apiKey: String, flareSolverrURL: URL? = nil) async throws -> Indexer {
        let record = Indexer(name: name, torznabURL: url, flareSolverrURL: flareSolverrURL)
        try secrets.set(apiKey, account: record.credentialRef ?? "")
        try await indexerRecords.upsert(record)
        await reloadIndexers()
        try? await startAutomaticReleaseAutomation()
        return record
    }

    @discardableResult
    func addProwlarr(name: String, url: URL, apiKey: String) async throws -> Indexer {
        let record = Indexer(name: name, prowlarrURL: url)
        try secrets.set(apiKey, account: record.credentialRef ?? "")
        try await indexerRecords.upsert(record)
        await reloadIndexers()
        try? await startAutomaticReleaseAutomation()
        return record
    }

    func setIndexerEnabled(_ indexer: Indexer, _ enabled: Bool) async {
        try? await indexerRecords.setEnabled(id: indexer.id, enabled)
        await reloadIndexers()
        if enabled { try? await startAutomaticReleaseAutomation() }
    }

    func setIndexerFlareSolverrURL(_ indexer: Indexer, _ url: URL?) async {
        var updated = indexer
        updated.flareSolverrURL = url?.absoluteString
        try? await indexerRecords.upsert(updated)
        await reloadIndexers()
    }

    func deleteIndexer(_ indexer: Indexer) async {
        try? await indexerRecords.delete(id: indexer.id)
        if let ref = indexer.credentialRef { try? secrets.delete(account: ref) }
        await reloadIndexers()
    }

    // MARK: Engine

    /// Lazily starts the managed-download engine, distinct from stream-specific tuning.
    func downloadManager() async throws -> DownloadManager {
        if let downloads { return downloads }
        let session = try engineHost.session(loopbackOnly: isDemo)
        let folder = downloadFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = DownloadManager(
            engine: SessionDownloadEngine(session), torrents: torrents, health: health,
            blocklist: blocklist,
            completionSink: ManagedDownloadImportSink(session: session, importer: importCoordinator, library: library),
            sleepAssertion: IOPMSleepAssertion(),
            powerSource: IOKitPowerSourceMonitor())
        try await manager.start()
        downloads = manager
        return manager
    }

    /// Starts coalesced RSS checks when an indexer exists. Empty target sets do not make network requests.
    func startReleaseAutomation(targets: @escaping ReleaseAutomation.TargetProvider) async throws {
        guard automation == nil else { return }
        await reloadIndexers()
        guard await CoordinatorSearcher(coordinator).enabledIndexerCount() > 0 else { return }
        let manager = try await downloadManager()
        let service = ReleaseAutomation(
            search: CoordinatorSearcher(coordinator), targets: targets, grabber: manager,
            grabs: grabs, blocklist: blocklist, history: history, health: health,
            indexers: indexerRecords, refreshIndexers: { [weak self] in await self?.reloadIndexers() })
        automation = service
        await service.start()
    }

    func searchNow(_ target: AutomationTarget) async -> AutomationRunResult? {
        guard let automation else { return nil }
        return await automation.searchNow(target: target)
    }

    /// Creates the torrent session and the Play pipeline on first use.
    func playPipeline() async throws -> PlayPipeline {
        if let pipeline { return pipeline }
        await reloadIndexers()
        let session = try engineHost.session(loopbackOnly: isDemo)
        let folder = downloadFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let factory = SessionControllerFactory(session: session, server: engineHost.server) { [weak self] in
            StreamControllerConfiguration(savePath: self?.downloadFolder ?? folder)
        }
        let pipeline = PlayPipeline(
            search: CoordinatorSearcher(coordinator), controllers: factory, grabs: grabs, blocklist: blocklist,
            history: history)
        self.pipeline = pipeline
        return pipeline
    }

    // MARK: Shutdown

    /// Stops the stream server and torrent session. Called when the app quits; waits briefly so
    /// libtorrent can close its sockets and flush.
    func shutdownBlocking() {
        let host = engineHost
        let swarm = demoSwarm
        let downloads = downloads
        let automation = automation
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await automation?.stop()
            await downloads?.stop()
            await host.shutdown()
            await swarm?.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}

extension AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
