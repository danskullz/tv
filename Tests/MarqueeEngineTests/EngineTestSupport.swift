import Foundation
import MarqueeCore
import Synchronization
import Testing
import TorrentEngine

// Shared helpers carry the `engine` prefix so they cannot collide with helpers in other test files.

/// Deterministic, incompressible-looking bytes (splitmix64), so a wrong piece cannot match by luck.
func enginePayload(count: Int, seed: UInt64) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        var state = seed
        var offset = 0
        while offset < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let n = min(8, count - offset)
            withUnsafeBytes(of: z.littleEndian) { word in
                raw.baseAddress!.advanced(by: offset).copyMemory(from: word.baseAddress!, byteCount: n)
            }
            offset += 8
        }
    }
    return data
}

final class EngineScratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func directory(_ name: String) throws -> URL {
        let d = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// Polls until `condition` holds. Tests only; the engine itself never polls.
func engineEventually(
    _ timeout: Duration = .seconds(20), _ what: String = "condition", _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("\(what) not met within \(timeout)")
    throw TorrentError.timedOut
}

/// A seeding session holding `torrent`'s payload (already on disk under `saveDirectory`).
func engineMakeSeeder(
    torrent: Data, saveDirectory: URL, uploadLimit: Int? = nil
) async throws -> (session: TorrentSession, id: TorrentID, port: Int) {
    let session = try TorrentSession(configuration: .loopbackOnly())
    try await session.setBool("allow_multiple_connections_per_ip", true)
    let id = try await session.addTorrent(data: torrent, savePath: saveDirectory.path)
    // Per-torrent: the session-wide limit does not apply to loopback peers.
    if let uploadLimit { try await session.setUploadLimit(id, bytesPerSecond: uploadLimit) }
    try await engineEventually { try await session.status(id).state == .seeding }
    return (session, id, try await session.tcpListenPort())
}

func engineMakeLeecher() async throws -> TorrentSession {
    let session = try TorrentSession(configuration: .loopbackOnly())
    try await session.setBool("allow_multiple_connections_per_ip", true)
    return session
}

/// A fake season pack on disk.
struct EnginePack {
    let root: URL  // the torrent root folder
    let torrent: Data
    let episodeNames: [String]
    let episodes: [Data]
    let sampleName = "Sample/Show.Name.S01E01.sample.mkv"
    let nfoName: String

    static let folder = "Show.Name.S01.1080p.WEB-DL-GRP"

    static func series(episodes: Int = 3) -> PackSeriesContext {
        PackSeriesContext(
            title: "Show Name",
            episodes: (1...episodes).map { PackEpisode(ref: EpisodeRef(season: 1, episode: $0)) },
            targetSeasons: [1])
    }

    /// Three episodes of `sizes` bytes (random, deterministic), a sample and an nfo.
    static func make(
        in seedDir: URL, sizes: [Int] = [12 * 1_048_576 + 777, 9 * 1_048_576 + 12_345, 10 * 1_048_576 + 3],
        pieceLength: Int = 64 * 1024
    ) throws -> EnginePack {
        let root = seedDir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sample"), withIntermediateDirectories: true)
        var names: [String] = []
        var contents: [Data] = []
        for (i, size) in sizes.enumerated() {
            let name = "Show.Name.S01E0\(i + 1).1080p.WEB-DL-GRP.mkv"
            let data = enginePayload(count: size, seed: UInt64(100 + i))
            try data.write(to: root.appendingPathComponent(name))
            names.append(name)
            contents.append(data)
        }
        let sample = enginePayload(count: 1_048_576, seed: 7)
        try sample.write(to: root.appendingPathComponent("Sample/Show.Name.S01E01.sample.mkv"))
        let nfoName = "\(folder).nfo"
        try Data("release notes\n".utf8).write(to: root.appendingPathComponent(nfoName))
        let torrent = try TorrentCreator.createTorrent(at: root, pieceLength: pieceLength)
        return EnginePack(root: root, torrent: torrent, episodeNames: names, episodes: contents, nfoName: nfoName)
    }
}

// MARK: - HTTP

func engineSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpMaximumConnectionsPerHost = 8
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = 60
    return URLSession(configuration: cfg)
}

struct EngineFetchResult {
    var status: Int
    var data: Data
    /// Request start to first body byte.
    var firstByte: Duration
    /// Request start to last byte.
    var total: Duration
}

/// GET with optional byte range, timing the first body byte.
func engineFetch(_ url: URL, range: Range<Int64>? = nil, session: URLSession) async throws -> EngineFetchResult {
    var request = URLRequest(url: url)
    if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
    let start = ContinuousClock.now
    let (bytes, response) = try await session.bytes(for: request)
    var data = Data()
    if let range { data.reserveCapacity(Int(range.count)) }
    var first: Duration?
    var buffer: [UInt8] = []
    buffer.reserveCapacity(64 * 1024)
    for try await byte in bytes {
        if first == nil { first = ContinuousClock.now - start }
        buffer.append(byte)
        if buffer.count == 64 * 1024 {
            data.append(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
    data.append(contentsOf: buffer)
    let end = ContinuousClock.now
    return EngineFetchResult(
        status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data,
        firstByte: first ?? (end - start), total: end - start)
}

extension Duration {
    var engineMilliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// Collects values pushed from other tasks.
final class EngineCollector<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func add(_ item: T) { items.withLock { $0.append(item) } }
    var all: [T] { items.withLock { $0 } }
}
