import Foundation
import Synchronization

public enum StreamSourceError: Error, Equatable, Sendable {
    case invalidRange
    /// The availability provider finished (torrent removed / stopped) before the range became readable.
    case unavailable
    /// The file on disk is shorter than the piece map claims.
    case shortRead
    case fileUnavailable(errno: Int32)
}

/// One playable file. The streaming server reads it in bounded chunks and never buffers a whole range.
public protocol StreamByteSource: Sendable {
    /// Total size in bytes of the file being served.
    var length: Int64 { get }
    var contentType: String { get }

    /// Returns exactly `min(length, self.length - offset)` bytes starting at `offset` (empty at/after EOF),
    /// suspending until they are available if still downloading. Must honor task cancellation by
    /// throwing `CancellationError` promptly.
    func read(offset: Int64, length: Int) async throws -> Data

    /// Hint that the consumer is about to read (or has jumped to) `offset ..< offset+length`.
    /// The torrent engine uses this to set piece deadlines. Default: no-op.
    func prioritize(offset: Int64, length: Int) async
}

public extension StreamByteSource {
    func prioritize(offset: Int64, length: Int) async {}
}

// MARK: - Blocking pread helper

/// Lazily-opened read-only file descriptor with positional reads, performed off the cooperative
/// thread pool so a slow disk (external drive, network share) cannot starve Swift concurrency.
final class PReadFile: Sendable {
    private static let ioQueue = DispatchQueue(label: "marquee.stream.io", qos: .userInitiated, attributes: .concurrent)

    private let url: URL
    private let fd = Mutex<Int32>(-1)

    init(url: URL) { self.url = url }

    deinit {
        let descriptor = fd.withLock { $0 }
        if descriptor >= 0 { close(descriptor) }
    }

    /// Opens if necessary; returns the descriptor or throws.
    @discardableResult
    func open() throws -> Int32 {
        try fd.withLock { fd in
            if fd >= 0 { return fd }
            let opened = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
            guard opened >= 0 else { throw StreamSourceError.fileUnavailable(errno: errno) }
            fd = opened
            return opened
        }
    }

    func size() throws -> Int64 {
        let descriptor = try open()
        var st = stat()
        guard fstat(descriptor, &st) == 0 else { throw StreamSourceError.fileUnavailable(errno: errno) }
        return Int64(st.st_size)
    }

    /// Reads exactly `count` bytes at `offset` or throws `.shortRead`.
    func read(offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        let descriptor = try open()
        return try await withCheckedThrowingContinuation { cont in
            Self.ioQueue.async {
                var data = Data(count: count)
                var done = 0
                var failure: Error?
                data.withUnsafeMutableBytes { raw in
                    while done < count {
                        let n = pread(descriptor, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                        if n > 0 { done += n }
                        else if n == 0 { failure = StreamSourceError.shortRead; break }
                        else if errno == EINTR { continue }
                        else { failure = StreamSourceError.fileUnavailable(errno: errno); break }
                    }
                }
                if let failure { cont.resume(throwing: failure) } else { cont.resume(returning: data) }
            }
        }
    }
}

enum MediaTypes {
    static func contentType(forFilename name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mkv": "video/x-matroska"
        case "mka": "audio/x-matroska"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "ts", "m2ts": "video/mp2t"
        case "mpg", "mpeg": "video/mpeg"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "flac": "audio/flac"
        case "ogg", "opus": "audio/ogg"
        case "wav": "audio/wav"
        case "srt": "application/x-subrip"
        case "vtt": "text/vtt"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Complete local file

/// A complete file on disk.
public final class FileByteSource: StreamByteSource {
    public let length: Int64
    public let contentType: String
    private let file: PReadFile

    /// Opens the file immediately (throws if it cannot be read). `contentType` defaults from the extension.
    public init(url: URL, contentType: String? = nil) throws {
        let file = PReadFile(url: url)
        self.length = try file.size()
        self.file = file
        self.contentType = contentType ?? MediaTypes.contentType(forFilename: url.lastPathComponent)
    }

    public func read(offset: Int64, length requested: Int) async throws -> Data {
        guard offset >= 0, requested >= 0 else { throw StreamSourceError.invalidRange }
        let count = Int(min(Int64(requested), max(0, length - offset)))
        guard count > 0 else { return Data() }
        return try await file.read(offset: offset, count: count)
    }
}

// MARK: - Growing (still downloading) file

/// What the torrent engine plugs in for a file that is still downloading.
public protocol PieceAvailabilityProvider: Sendable {
    /// Pieces completed so far.
    func snapshot() async -> PieceAvailability
    /// Newly completed piece indices. Sources subscribe *before* calling `snapshot()`, so the stream must
    /// buffer from the moment it is created; duplicates and replays are harmless. Finishing the stream
    /// means no more pieces will ever arrive, which fails reads that are still waiting.
    func completedPieces() -> AsyncStream<Int>
    /// Ask the engine to fetch these (torrent-coordinate) pieces first. Default: no-op.
    func prioritize(pieces: Range<Int>) async
}

public extension PieceAvailabilityProvider {
    func prioritize(pieces: Range<Int>) async {}
}

/// Tracks availability and parks readers until the pieces they need have arrived.
actor PieceAvailabilityTracker {
    private struct Waiter {
        let pieces: Range<Int>
        let continuation: CheckedContinuation<Void, Error>
    }

    private let provider: any PieceAvailabilityProvider
    private var availability: PieceAvailability
    private var waiters: [UInt64: Waiter] = [:]
    private var nextID: UInt64 = 0
    private var finished = false
    private var bootstrap: Task<Void, Never>?
    private var consumer: Task<Void, Never>?

    init(provider: any PieceAvailabilityProvider, pieceCount: Int) {
        self.provider = provider
        self.availability = PieceAvailability(pieceCount: pieceCount)
    }

    deinit { consumer?.cancel() }

    private func start() async {
        if bootstrap == nil {
            bootstrap = Task { await self.subscribe() }
        }
        await bootstrap?.value
    }

    private func subscribe() async {
        let stream = provider.completedPieces()  // subscribe first so nothing is missed between snapshot and updates
        let snapshot = await provider.snapshot()
        for p in 0..<min(snapshot.pieceCount, availability.pieceCount) where snapshot.contains(p) {
            availability.insert(p)
        }
        resumeSatisfied()
        consumer = Task { [weak self] in
            for await piece in stream {
                guard let self else { return }
                await self.mark(piece)
            }
            await self?.streamEnded()
        }
    }

    private func mark(_ piece: Int) {
        if availability.insert(piece) { resumeSatisfied() }
    }

    private func streamEnded() {
        finished = true
        let pending = waiters
        waiters.removeAll()
        for (_, w) in pending { w.continuation.resume(throwing: StreamSourceError.unavailable) }
    }

    private func resumeSatisfied() {
        guard !waiters.isEmpty else { return }
        for (id, w) in waiters where availability.containsAll(w.pieces) {
            waiters[id] = nil
            w.continuation.resume()
        }
    }

    func waitFor(_ pieces: Range<Int>) async throws {
        await start()
        try Task.checkCancellation()
        if availability.containsAll(pieces) { return }
        if finished { throw StreamSourceError.unavailable }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // The handler may have fired before we got here; the flag is already set in that case.
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                waiters[id] = Waiter(pieces: pieces, continuation: cont)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

/// Reads a partially-written (typically preallocated) file, suspending until the pieces covering the
/// requested range have been reported complete by the injected provider.
public final class GrowingFileByteSource: StreamByteSource {
    public let length: Int64
    public let contentType: String
    public let pieceMap: PieceMap
    private let file: PReadFile
    private let provider: any PieceAvailabilityProvider
    private let tracker: PieceAvailabilityTracker

    /// - Parameter url: file in the incomplete-downloads folder; opened lazily on first read, so it
    ///   may not exist yet at construction time.
    public init(url: URL, contentType: String? = nil, pieceMap: PieceMap, availability: any PieceAvailabilityProvider) {
        self.length = pieceMap.fileLength
        self.pieceMap = pieceMap
        self.contentType = contentType ?? MediaTypes.contentType(forFilename: url.lastPathComponent)
        self.file = PReadFile(url: url)
        self.provider = availability
        self.tracker = PieceAvailabilityTracker(provider: availability, pieceCount: pieceMap.pieceCount)
    }

    public func read(offset: Int64, length requested: Int) async throws -> Data {
        guard offset >= 0, requested >= 0 else { throw StreamSourceError.invalidRange }
        let count = Int(min(Int64(requested), max(0, length - offset)))
        guard count > 0 else { return Data() }
        try await tracker.waitFor(pieceMap.pieces(offset: offset, length: Int64(count)))
        return try await file.read(offset: offset, count: count)
    }

    public func prioritize(offset: Int64, length requested: Int) async {
        guard offset >= 0, requested > 0 else { return }
        let pieces = pieceMap.pieces(offset: offset, length: Int64(requested))
        guard !pieces.isEmpty else { return }
        await provider.prioritize(pieces: pieces)
    }
}
