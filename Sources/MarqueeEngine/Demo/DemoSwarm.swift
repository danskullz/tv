import Foundation
import MarqueeCore
import TorrentEngine

/// A self-contained, legal, deterministic content source for demos and end-to-end tests: a fake
/// Torznab indexer on loopback plus a loopback seeding torrent session, serving synthetic test-pattern
/// video generated at run time. One fake series ("Marquee Test Pattern", season 1, three short
/// episodes, offered both as a season pack and as single episodes) and one fake movie.
///
/// Nothing leaves the machine and no real content is involved. The app starts it only with the
/// `-demoSwarm YES` launch flag; tests drive it directly.
public final class DemoSwarm: Sendable {
    public struct Options: Sendable {
        public var episodeSeconds: Double
        public var movieSeconds: Double
        public var width: Int
        public var height: Int
        /// Also advertise a 1080p release nobody seeds (the highest ranked), to exercise automatic fallback.
        public var includeDeadRelease: Bool
        public var clipSource: ClipSource
        /// Delay added to every search, so the "Searching…" lines are visible in demos.
        public var searchLatency: TimeInterval
        public var framesPerSecond: Int

        public init(
            episodeSeconds: Double = 20, movieSeconds: Double = 25, width: Int = 1280, height: Int = 720,
            includeDeadRelease: Bool = false, clipSource: ClipSource = .generate(fallback: nil),
            searchLatency: TimeInterval = 0, framesPerSecond: Int = 24
        ) {
            self.framesPerSecond = framesPerSecond
            self.clipSource = clipSource
            self.searchLatency = searchLatency
            self.episodeSeconds = episodeSeconds
            self.movieSeconds = movieSeconds
            self.width = width
            self.height = height
            self.includeDeadRelease = includeDeadRelease
        }
    }

    /// Where the video comes from.
    public enum ClipSource: Sendable {
        /// Encode a test pattern with AVAssetWriter; if the machine has no encoder, use `fallback`.
        case generate(fallback: URL?)
        /// A ready-made MP4 (no encoding). Each episode gets a distinct `free` atom appended, which
        /// players ignore, so the three episodes differ byte for byte.
        case file(URL)
    }

    public static let apiKey = "marquee-demo-key"
    public static let seriesName = "Marquee Test Pattern"
    public static let movieName = "Marquee Demo Reel"
    public static let seriesTVDBID = 99_000_001
    public static let movieTMDBID = 99_000_002
    public static let indexerID = UUID(uuidString: "6D617271-D3AD-4000-8000-000000000001")!

    public let torznabURL: URL
    public let seederPort: Int
    /// Magnet-carrying releases the indexer advertises (title, info hash, seeders).
    public let releaseTitles: [String]
    /// Absolute paths of the generated episode files, in order, and the movie (for byte comparisons).
    public let episodeFiles: [URL]
    public let movieFile: URL

    private let seeder: TorrentSession
    private let indexer: TorznabFixtureServer

    /// Query strings the fake indexer has received.
    public var indexerRequests: [String] { indexer.requests }

    private init(
        torznabURL: URL, seederPort: Int, releaseTitles: [String], episodeFiles: [URL], movieFile: URL,
        seeder: TorrentSession, indexer: TorznabFixtureServer
    ) {
        self.torznabURL = torznabURL
        self.seederPort = seederPort
        self.releaseTitles = releaseTitles
        self.episodeFiles = episodeFiles
        self.movieFile = movieFile
        self.seeder = seeder
        self.indexer = indexer
    }

    /// Generates (or reuses) the clips under `directory`, starts seeding and the fake indexer.
    public static func start(directory: URL, options: Options = Options()) async throws -> DemoSwarm {
        let fm = FileManager.default
        let clips = directory.appendingPathComponent("clips", isDirectory: true)
        try fm.createDirectory(at: clips, withIntermediateDirectories: true)

        // 1. Clips (cached by their parameters).
        let tag = "\(options.width)x\(options.height)@\(options.framesPerSecond)"
        let hues = [0.58, 0.08, 0.35]
        var specs: [(URL, SampleVideoGenerator.Spec)] = []
        for n in 1...3 {
            specs.append((
                clips.appendingPathComponent("e\(n)-\(tag)-\(Int(options.episodeSeconds))s.mp4"),
                SampleVideoGenerator.Spec(
                    title: seriesName, subtitle: "S01E0\(n) · Episode \(n)", duration: options.episodeSeconds,
                    width: options.width, height: options.height, framesPerSecond: options.framesPerSecond, hue: hues[n - 1])))
        }
        specs.append((
            clips.appendingPathComponent("reel-\(tag)-\(Int(options.movieSeconds))s.mp4"),
            SampleVideoGenerator.Spec(
                title: movieName, subtitle: "2026 · Feature presentation", duration: options.movieSeconds,
                width: options.width, height: options.height, framesPerSecond: options.framesPerSecond, hue: 0.78)))
        switch options.clipSource {
        case .file(let source):
            try writeVariants(of: source, to: specs.map(\.0))
        case .generate(let fallback):
            do {
                try await generateMissing(specs)
            } catch {
                guard let fallback else { throw error }
                try writeVariants(of: fallback, to: specs.map(\.0))
            }
        }

        // 2. Seed layout: a season-pack folder, single-episode files, the movie.
        let seed = directory.appendingPathComponent("seed", isDirectory: true)
        try? fm.removeItem(at: seed)
        let packName = "Marquee.Test.Pattern.S01.720p.WEB-DL.H264-DEMO"
        let packDir = seed.appendingPathComponent("pack/\(packName)", isDirectory: true)
        let singleDir = seed.appendingPathComponent("single", isDirectory: true)
        let movieDir = seed.appendingPathComponent("movie", isDirectory: true)
        for d in [packDir, singleDir, movieDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        var episodeNames: [String] = []
        for n in 1...3 {
            let name = "Marquee.Test.Pattern.S01E0\(n).720p.WEB-DL.H264-DEMO"
            episodeNames.append(name)
            try fm.copyItem(at: specs[n - 1].0, to: packDir.appendingPathComponent("\(name).mp4"))
            try fm.copyItem(at: specs[n - 1].0, to: singleDir.appendingPathComponent("\(name).mp4"))
        }
        let movieRelease = "Marquee.Demo.Reel.2026.720p.WEB-DL.H264-DEMO"
        try fm.copyItem(at: specs[3].0, to: movieDir.appendingPathComponent("\(movieRelease).mp4"))

        // 3. Torrents and the seeding session.
        let session = try TorrentSession(configuration: .loopbackOnly())
        try await session.setBool("allow_multiple_connections_per_ip", true)
        func seedTorrent(_ path: URL, saveDirectory: URL) async throws -> (TorrentID, Int64) {
            let torrent = try await Task.detached { try TorrentCreator.createTorrent(at: path, pieceLength: 64 * 1024) }.value
            let id = try await session.addTorrent(data: torrent, savePath: saveDirectory.path)
            return (id, try Self.byteCount(at: path))
        }
        var seeded: [(title: String, id: TorrentID, size: Int64, season: Int?, episode: Int?, kind: DemoRelease.Kind, seeders: Int)] = []
        let (packID, packSize) = try await seedTorrent(packDir, saveDirectory: packDir.deletingLastPathComponent())
        seeded.append((packName, packID, packSize, 1, nil, .tv, 40))
        for n in 1...3 {
            let file = singleDir.appendingPathComponent("\(episodeNames[n - 1]).mp4")
            let (id, size) = try await seedTorrent(file, saveDirectory: singleDir)
            seeded.append((episodeNames[n - 1], id, size, 1, n, .tv, 25))
        }
        let (movieID, movieSize) = try await seedTorrent(
            movieDir.appendingPathComponent("\(movieRelease).mp4"), saveDirectory: movieDir)
        seeded.append((movieRelease, movieID, movieSize, nil, nil, .movie, 30))
        let port = try await session.tcpListenPort()

        // 4. The fake indexer advertises magnets that point back at the seeder.
        func magnet(_ hash: String, _ name: String) -> String {
            "magnet:?xt=urn:btih:\(hash)&dn=\(name)&x.pe=127.0.0.1:\(port)"
        }
        var releases = seeded.map { s in
            DemoRelease(
                kind: s.kind, title: s.title, guid: "demo-\(s.id.hex.prefix(12))", infoHash: s.id.hex, size: s.size,
                seeders: s.seeders, magnet: magnet(s.id.hex, s.title), season: s.season, episode: s.episode)
        }
        if options.includeDeadRelease {
            let name = "Marquee.Test.Pattern.S01E01.1080p.WEB-DL.H264-DEAD"
            let hash = String(repeating: "d3ad", count: 10)
            releases.append(DemoRelease(
                kind: .tv, title: name, guid: "demo-dead", infoHash: hash, size: 900_000_000, seeders: 300,
                magnet: "magnet:?xt=urn:btih:\(hash)&dn=\(name)", season: 1, episode: 1))
        }
        let catalogue = releases
        let indexer = TorznabFixtureServer(
            apiKey: apiKey, tvdbID: seriesTVDBID, movieTMDBID: movieTMDBID, searchLatency: options.searchLatency,
            releases: { catalogue })
        let indexerPort = try await indexer.start()

        return DemoSwarm(
            torznabURL: URL(string: "http://127.0.0.1:\(indexerPort)/api")!, seederPort: port,
            releaseTitles: releases.map(\.title), episodeFiles: (1...3).map { n in
                singleDir.appendingPathComponent("\(episodeNames[n - 1]).mp4")
            },
            movieFile: movieDir.appendingPathComponent("\(movieRelease).mp4"), seeder: session, indexer: indexer)
    }

    public func stop() async {
        indexer.stop()
        await seeder.shutdown()
    }

    // MARK: Library seeding

    /// Adds the demo series and movie to the library and registers the fake indexer (key in `secrets`).
    /// Safe to call on every launch: existing rows are kept, the indexer's address is refreshed.
    @discardableResult
    public func install(into database: AppDatabase, secrets: SecretStore) async throws -> (series: Title, movie: Title) {
        try await database.ensurePresetProfiles()
        let library = GRDBLibraryRepository(database)
        let existing = try await library.titles(matching: LibraryFilter())

        let series: Title
        if let found = existing.first(where: { $0.kind == .series && $0.tvdbId == Self.seriesTVDBID }) {
            series = found
        } else {
            let calendar = Calendar(identifier: .gregorian)
            let aired = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))
            let title = Title(
                kind: .series, tvdbId: Self.seriesTVDBID, title: Self.seriesName, year: 2026,
                overview: "A synthetic test pattern in three short episodes. Generated on your Mac for demos: no real content, nothing downloaded from the internet.",
                status: "ended", monitorMode: .all, qualityProfileId: QualityProfileConfig.balanced.id)
            series = try await library.add(
                title,
                seasons: [
                    SeasonDraft(
                        seasonNumber: 1,
                        episodes: (1...3).map { n in
                            EpisodeDraft(
                                episodeNumber: n, airDate: aired.map { calendar.date(byAdding: .day, value: 7 * (n - 1), to: $0)! },
                                title: ["Colour Bars", "Sweep", "Signal Lock"][n - 1])
                        })
                ])
        }
        let movie: Title
        if let found = existing.first(where: { $0.kind == .movie && $0.tmdbId == Self.movieTMDBID }) {
            movie = found
        } else {
            movie = try await library.add(
                Title(
                    kind: .movie, tmdbId: Self.movieTMDBID, title: Self.movieName, year: 2026,
                    overview: "A short synthetic feature, generated on your Mac for demos.", status: "released",
                    qualityProfileId: QualityProfileConfig.balanced.id),
                seasons: [])
        }

        let record = Indexer(name: "Demo indexer (local)", torznabURL: torznabURL, id: Self.indexerID)
        try await GRDBIndexerRepository(database).upsert(record)
        try secrets.set(Self.apiKey, account: record.credentialRef ?? "")
        return (series, movie)
    }

    // MARK: Helpers

    private static func writeVariants(of source: URL, to destinations: [URL]) throws {
        let base = try Data(contentsOf: source)
        for (index, url) in destinations.enumerated() {
            var data = base
            // An MP4 `free` atom: 8-byte header (size, 'free') + filler unique to this clip.
            let filler = 4096 * (index + 1)
            var size = UInt32(8 + filler).bigEndian
            data.append(Data(bytes: &size, count: 4))
            data.append(Data("free".utf8))
            data.append(Data((0..<filler).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ index &* 7) }))
            try data.write(to: url)
        }
    }

    private static func byteCount(at url: URL) throws -> Int64 {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])! {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func generateMissing(_ specs: [(URL, SampleVideoGenerator.Spec)]) async throws {
        let missing = specs.filter { url, _ in
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) == 0
        }
        guard !missing.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (url, spec) in missing {
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try SampleVideoGenerator.generate(spec, to: url)
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
