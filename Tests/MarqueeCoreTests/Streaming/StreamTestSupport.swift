import Darwin
import Foundation
import Synchronization
@testable import MarqueeCore

// MARK: - Data helpers

/// One period (65536 bytes) of the pattern: byte(o) = 7*(o & 0xFF) + ((o >> 8) & 0xFF), so any misplaced chunk is detectable.
private let patternPeriod: [UInt8] = (0..<65536).map { UInt8(truncatingIfNeeded: 7 &* ($0 & 0xFF) &+ ($0 >> 8)) }

/// Deterministic, position-dependent bytes (fast even in debug builds: copies from `patternPeriod`).
func patternBytes(offset: Int64, count: Int) -> Data {
    var out = Data(count: count)
    out.withUnsafeMutableBytes { raw in
        patternPeriod.withUnsafeBytes { table in
            var done = 0
            var phase = Int(offset & 0xFFFF)
            while done < count {
                let n = min(count - done, 65536 - phase)
                memcpy(raw.baseAddress! + done, table.baseAddress! + phase, n)
                done += n
                phase = 0
            }
        }
    }
    return out
}

final class TempDir: Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-stream-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes `size` bytes of `patternBytes` in 1 MiB blocks.
    func makePatternFile(name: String = "video.mkv", size: Int64) -> URL {
        let file = url.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let h = try! FileHandle(forWritingTo: file)
        defer { try? h.close() }
        var off: Int64 = 0
        while off < size {
            let n = Int(min(1 << 20, size - off))
            try! h.write(contentsOf: patternBytes(offset: off, count: n))
            off += Int64(n)
        }
        return file
    }
}

// MARK: - Sources for tests

/// Blocks in `read` until cancelled, recording what happened.
final class ProbeSource: StreamByteSource {
    let length: Int64
    let contentType = "video/mp4"
    private let state = Mutex((started: 0, cancelled: 0))
    private let prioritized = Mutex<[(Int64, Int)]>([])

    init(length: Int64 = 10_000_000) { self.length = length }

    var readsStarted: Int { state.withLock { $0.started } }
    var readsCancelled: Int { state.withLock { $0.cancelled } }
    var prioritizeCalls: [(Int64, Int)] { prioritized.withLock { $0 } }

    func read(offset: Int64, length: Int) async throws -> Data {
        state.withLock { $0.started += 1 }
        do {
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(3600))
            } onCancel: {}
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
        return Data()
    }

    func prioritize(offset: Int64, length: Int) async {
        prioritized.withLock { $0.append((offset, length)) }
    }
}

/// Source that records prioritize calls and serves pattern bytes from memory.
final class RecordingPatternSource: StreamByteSource {
    let length: Int64
    let contentType = "video/mp4"
    private let calls = Mutex<[(Int64, Int)]>([])
    init(length: Int64) { self.length = length }
    var prioritizeCalls: [(Int64, Int)] { calls.withLock { $0 } }
    func read(offset: Int64, length requested: Int) async throws -> Data {
        let n = Int(min(Int64(requested), max(0, length - offset)))
        return patternBytes(offset: offset, count: n)
    }
    func prioritize(offset: Int64, length: Int) async { calls.withLock { $0.append((offset, length)) } }
}

/// Hand-driven stand-in for the torrent engine.
final class ManualAvailability: PieceAvailabilityProvider {
    private struct State {
        var availability: PieceAvailability
        var continuations: [AsyncStream<Int>.Continuation] = []
        var prioritized: [Range<Int>] = []
        var finished = false
    }
    private let state: Mutex<State>

    init(pieceCount: Int, completed: [Int] = []) {
        state = Mutex(State(availability: PieceAvailability(pieceCount: pieceCount, completed: completed)))
    }

    func snapshot() async -> PieceAvailability { state.withLock { $0.availability } }

    func completedPieces() -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let alreadyFinished = state.withLock { s -> Bool in
            s.continuations.append(continuation)
            return s.finished
        }
        if alreadyFinished { continuation.finish() }
        return stream
    }

    func prioritize(pieces: Range<Int>) async { state.withLock { $0.prioritized.append(pieces) } }

    var prioritized: [Range<Int>] { state.withLock { $0.prioritized } }

    func complete(_ pieces: some Sequence<Int>) {
        let conts = state.withLock { s -> [AsyncStream<Int>.Continuation] in
            for p in pieces { s.availability.insert(p) }
            return s.continuations
        }
        for p in pieces { for c in conts { c.yield(p) } }
    }

    func finish() {
        let conts = state.withLock { s -> [AsyncStream<Int>.Continuation] in
            s.finished = true
            return s.continuations
        }
        for c in conts { c.finish() }
    }
}

// MARK: - Raw socket client (for malformed / header-forging / keep-alive tests)

struct RawResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Minimal blocking HTTP/1.1 client over BSD sockets. Always used through `offload`.
final class RawClient: @unchecked Sendable {
    private var fd: Int32 = -1
    private var pending = Data()

    init(port: UInt16, receiveTimeout: TimeInterval = 10) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 { return false }
        pending.append(contentsOf: tmp[0..<n])
        return true
    }

    /// Reads one response (head + Content-Length body; no body for HEAD). nil on EOF/timeout before a head.
    func readResponse(expectBody: Bool = true) -> RawResponse? {
        let sep = Data("\r\n\r\n".utf8)
        while pending.range(of: sep) == nil { if !fill() { return nil } }
        let r = pending.range(of: sep)!
        let headText = String(decoding: pending[pending.startIndex..<r.lowerBound], as: UTF8.self)
        pending = Data(pending[r.upperBound...])
        let lines = headText.components(separatedBy: "\r\n")
        let status = Int(lines[0].split(separator: " ")[1])!
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let c = l.firstIndex(of: ":") {
                headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data()
        if expectBody, let cl = headers["content-length"], let n = Int(cl) {
            while pending.count < n { if !fill() { break } }
            body = Data(pending.prefix(n))
            pending = Data(pending.dropFirst(min(n, pending.count)))
        }
        return RawResponse(status: status, headers: headers, body: body)
    }

    /// True if the peer has closed (EOF) with nothing more to read.
    func isClosedByPeer() -> Bool {
        if !pending.isEmpty { return false }
        return !fill()
    }
}

/// Runs blocking work off the cooperative pool.
func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
    }
}

func offloadTry<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try work() }) }
    }
}

/// Polls until `condition` holds or the timeout passes.
func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - URLSession helpers

func makeSession(maxConnections: Int = 32) -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpMaximumConnectionsPerHost = maxConnections
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = 60
    return URLSession(configuration: cfg)
}

func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:], session: URLSession) async throws -> (Data, HTTPURLResponse) {
    var req = URLRequest(url: url)
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await session.data(for: req)
    return (data, resp as! HTTPURLResponse)
}

/// Downloads discarding bytes, reporting count and elapsed time.
final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let total = Mutex<Int64>(0)
    private let done = Mutex<CheckedContinuation<Void, Error>?>(nil)
    private let start = Mutex<ContinuousClock.Instant?>(nil)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        start.withLock { if $0 == nil { $0 = .now } }
        total.withLock { $0 += Int64(data.count) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = done.withLock { s -> CheckedContinuation<Void, Error>? in defer { s = nil }; return s }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func run(url: URL) async throws -> (bytes: Int64, seconds: Double) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            done.withLock { $0 = c }
            session.dataTask(with: url).resume()
        }
        let begin = start.withLock { $0 } ?? .now
        let elapsed = begin.duration(to: .now)
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (total.withLock { $0 }, max(secs, 1e-6))
    }
}
