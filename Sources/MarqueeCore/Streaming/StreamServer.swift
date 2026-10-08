import Foundation
import Network
import Synchronization

/// A registered stream: the unguessable token and the loopback URL to hand to the player.
public struct StreamEndpoint: Sendable, Equatable {
    public let token: String
    public let url: URL
}

public enum StreamServerError: Error, Equatable, Sendable {
    case failedToStart(String)
    case notRunning
}

/// Loopback-only HTTP/1.1 server that exposes `StreamByteSource`s to the player with Range support.
///
/// Security (SCOPE.md §8): binds 127.0.0.1 only; every source lives behind a random 128-bit token;
/// `Host` must be `127.0.0.1:<port>` or `localhost:<port>` and any `Origin` must be loopback
/// (anti DNS-rebinding); only GET and HEAD are served; request heads are size-bounded.
///
/// Performance: event driven (no timers); bodies are streamed in `chunkSize` pieces with the next
/// chunk read while the current one is being written, so memory per connection is ~2 chunks.
public actor StreamServer {
    public static let defaultChunkSize = 256 * 1024

    struct Entry {
        let source: any StreamByteSource
        let filename: String
    }

    private let chunkSize: Int
    private let maxConnections: Int
    private let queue = DispatchQueue(label: "marquee.stream.listener", qos: .userInitiated)

    private var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    public private(set) var port: UInt16?

    private var entries: [String: Entry] = [:]
    private var connections: [UUID: ServerConnection] = [:]
    private var activeByToken: [String: Set<UUID>] = [:]

    public init(chunkSize: Int = StreamServer.defaultChunkSize, maxConnections: Int = 256) {
        self.chunkSize = max(4 * 1024, chunkSize)
        self.maxConnections = maxConnections
    }

    // MARK: Lifecycle

    /// Binds 127.0.0.1 on an ephemeral port. Idempotent; returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port { return port }
        if startTask == nil { startTask = Task { try await self.bind() } }
        do {
            return try await startTask!.value
        } catch {
            startTask = nil
            throw error
        }
    }

    private func bind() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            throw StreamServerError.failedToStart("\(error)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = OnceResumer(cont)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue { once.resume(.success(p)) }
                    else { once.resume(.failure(StreamServerError.failedToStart("no port"))) }
                case .failed(let error):
                    once.resume(.failure(StreamServerError.failedToStart("\(error)")))
                    Task { await self?.listenerFailed() }
                case .cancelled:
                    once.resume(.failure(StreamServerError.failedToStart("cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.port = port
        return port
    }

    private func listenerFailed() {
        stop()
    }

    /// Closes the listener and every connection and forgets all registrations.
    public func stop() {
        listener?.cancel()
        listener = nil
        startTask?.cancel()
        startTask = nil
        port = nil
        entries.removeAll()
        activeByToken.removeAll()
        let open = connections.values
        connections.removeAll()
        for c in open { Task { await c.close() } }
    }

    // MARK: Registration

    /// Registers a source under a fresh random token (starting the server if needed).
    /// `filename` only decorates the URL (players sniff extensions); it plays no part in lookup.
    public func register(_ source: any StreamByteSource, filename: String) async throws -> StreamEndpoint {
        let port = try await start()
        var generator = SystemRandomNumberGenerator()
        let token = String(format: "%016llx%016llx", generator.next(), generator.next())
        entries[token] = Entry(source: source, filename: filename)
        let component = Self.urlSafeFilename(filename)
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(component)") else {
            entries[token] = nil
            throw StreamServerError.failedToStart("bad url")
        }
        return StreamEndpoint(token: token, url: url)
    }

    /// Invalidates the token and closes every connection currently serving it.
    public func revoke(token: String) {
        entries[token] = nil
        guard let ids = activeByToken.removeValue(forKey: token) else { return }
        for id in ids {
            if let c = connections[id] { Task { await c.close() } }
        }
    }

    public func revokeAll() {
        for token in Array(entries.keys) { revoke(token: token) }
    }

    public var registrationCount: Int { entries.count }
    public var connectionCount: Int { connections.count }

    static func urlSafeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "stream" : trimmed
        return base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "stream"
    }

    // MARK: Connection plumbing

    private func accept(_ nw: NWConnection) {
        guard let port, connections.count < maxConnections else {
            nw.cancel()
            return
        }
        let connection = ServerConnection(connection: nw, server: self, port: port, chunkSize: chunkSize)
        connections[connection.id] = connection
        Task { await connection.start() }
    }

    func lookup(token: String, connection id: UUID) -> (any StreamByteSource)? {
        guard let entry = entries[token] else { return nil }
        activeByToken[token, default: []].insert(id)
        return entry.source
    }

    func requestFinished(token: String, connection id: UUID) {
        activeByToken[token]?.remove(id)
        if activeByToken[token]?.isEmpty == true { activeByToken[token] = nil }
    }

    func connectionFinished(_ id: UUID) {
        connections[id] = nil
        for token in Array(activeByToken.keys) {
            activeByToken[token]?.remove(id)
            if activeByToken[token]?.isEmpty == true { activeByToken[token] = nil }
        }
    }
}

/// Resumes a continuation at most once, from any thread.
private final class OnceResumer<T: Sendable>: Sendable {
    private let state: Mutex<CheckedContinuation<T, Error>?>
    init(_ continuation: CheckedContinuation<T, Error>) { state = Mutex(continuation) }
    func resume(_ result: Result<T, Error>) {
        let c = state.withLock { s -> CheckedContinuation<T, Error>? in
            defer { s = nil }
            return s
        }
        c?.resume(with: result)
    }
}

// MARK: - Connection

/// One accepted TCP connection: parses sequential requests (keep-alive) and streams responses.
actor ServerConnection {
    nonisolated let id = UUID()

    private static let maxBufferedInbound = 64 * 1024
    /// How far ahead of the playhead we tell the source what we are about to read.
    private static let prioritizeWindow = 8 * 1024 * 1024

    private let connection: NWConnection
    private let server: StreamServer
    private let port: UInt16
    private let chunkSize: Int
    private let queue = DispatchQueue(label: "marquee.stream.conn", qos: .userInitiated)

    private var buffer = Data()
    private var receiving = false
    private var ended = false
    private var closed = false
    private var serving = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var runTask: Task<Void, Never>?

    init(connection: NWConnection, server: StreamServer, port: UInt16, chunkSize: Int) {
        self.connection = connection
        self.server = server
        self.port = port
        self.chunkSize = chunkSize
    }

    func start() {
        guard runTask == nil, !closed else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.peerGone(hardError: true) }
            default: break
            }
        }
        connection.start(queue: queue)
        pump()
        runTask = Task { await self.run() }
    }

    /// Hard-closes the connection and cancels any in-flight response (and thereby its pending source read).
    func close() {
        guard !closed else { return }
        closed = true
        ended = true
        runTask?.cancel()
        connection.cancel()
        wake()
    }

    // MARK: Inbound

    /// Keeps one receive outstanding (while there is buffer room) so that a client disconnect is noticed
    /// even while we are parked waiting for pieces. Pipelined bytes land in `buffer`.
    private func pump() {
        guard !receiving, !ended, buffer.count < Self.maxBufferedInbound else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            Task { await self.didReceive(data, isComplete: isComplete, error: error) }
        }
    }

    private func didReceive(_ data: Data?, isComplete: Bool, error: NWError?) {
        receiving = false
        if let data, !data.isEmpty { buffer.append(data) }
        if error != nil {
            peerGone(hardError: true)
        } else if isComplete {
            peerGone(hardError: false)
        } else {
            pump()
        }
        wake()
    }

    /// EOF while idle only ends the read side (a request already buffered is still answered);
    /// EOF/reset while a response is in flight, or any error, means the client left: cancel everything.
    private func peerGone(hardError: Bool) {
        ended = true
        if hardError || serving { close() }
        wake()
    }

    private func wake() {
        let w = waiter
        waiter = nil
        w?.resume()
    }

    private func nextRequest() async throws -> HTTPRequestHead? {
        while true {
            if let n = try HTTPRequestParser.headLength(in: buffer) {
                let head = buffer.prefix(n)
                let parsed = try HTTPRequestParser.parse(Data(head))
                buffer = Data(buffer.dropFirst(n))
                pump()
                return parsed
            }
            if ended || closed { return nil }
            pump()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if ended || closed { c.resume() } else { waiter = c }
            }
        }
    }

    // MARK: Request loop

    private func run() async {
        defer { Task { await self.finish() } }
        while !Task.isCancelled && !closed {
            let request: HTTPRequestHead
            do {
                guard let r = try await nextRequest() else { break }
                request = r
            } catch let e as HTTPParseError {
                await sendParseError(e)
                break
            } catch {
                break
            }
            serving = true
            let keepAlive = await handle(request)
            serving = false
            if !keepAlive { break }
        }
    }

    private func finish() async {
        close()
        await server.connectionFinished(id)
    }

    private func sendParseError(_ error: HTTPParseError) async {
        let status: Int
        switch error {
        case .headerTooLarge: status = 431
        case .unsupportedVersion: status = 505
        case .bodyNotSupported: status = 501
        case .malformed: status = 400
        }
        try? await respond(status: status, body: HTTPResponse.reason(status), keepAlive: false, sendBody: true)
    }

    // MARK: Request handling

    /// Returns whether the connection may be reused.
    private func handle(_ request: HTTPRequestHead) async -> Bool {
        let keepAlive = request.wantsKeepAlive
        do {
            guard let host = request.header("host"), Self.hostAllowed(host, port: port) else {
                try await respond(status: 403, body: "Forbidden", keepAlive: false, sendBody: request.method != "HEAD")
                return false
            }
            if let origin = request.header("origin"), !Self.originAllowed(origin) {
                try await respond(status: 403, body: "Forbidden", keepAlive: false, sendBody: request.method != "HEAD")
                return false
            }
            let isHead = request.method == "HEAD"
            guard request.method == "GET" || isHead else {
                try await respond(status: 405, body: "Method Not Allowed", extra: [("Allow", "GET, HEAD")], keepAlive: keepAlive)
                return keepAlive
            }
            guard let token = Self.token(fromTarget: request.target),
                  let source = await server.lookup(token: token, connection: id)
            else {
                try await respond(status: 404, body: "Not Found", keepAlive: keepAlive, sendBody: !isHead)
                return keepAlive
            }
            defer { Task { await server.requestFinished(token: token, connection: id) } }
            try await serve(source: source, request: request, keepAlive: keepAlive)
            return keepAlive
        } catch {
            return false  // write failed, cancelled, or source failed mid-body: drop the connection
        }
    }

    private func serve(source: any StreamByteSource, request: HTTPRequestHead, keepAlive: Bool) async throws {
        let length = source.length
        var headers: [(String, String)] = [
            ("Accept-Ranges", "bytes"),
            ("Content-Type", source.contentType),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
        ]
        if !keepAlive { headers.append(("Connection", "close")) }

        let status: Int
        let range: Range<Int64>
        switch HTTPRange.resolve(request.header("range"), length: length) {
        case .full:
            status = 200
            range = 0..<length
        case .partial(let r):
            status = 206
            range = r
            headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(length)"))
        case .unsatisfiable:
            headers.removeAll { $0.0 == "Content-Type" }
            headers.append(("Content-Range", "bytes */\(length)"))
            headers.append(("Content-Length", "0"))
            try await send(HTTPResponse.head(status: 416, headers: headers))
            return
        }
        headers.append(("Content-Length", String(range.count)))
        try await send(HTTPResponse.head(status: status, headers: headers))
        guard request.method == "GET", !range.isEmpty else { return }
        try await streamBody(source: source, range: range)
    }

    /// Reads chunk N+1 from the source while chunk N is being written; memory stays at ~2 chunks and the
    /// source is only pulled as fast as the socket drains (backpressure).
    private func streamBody(source: any StreamByteSource, range: Range<Int64>) async throws {
        let end = range.upperBound
        var position = range.lowerBound
        var nextPrioritizeAt = position
        let chunk = chunkSize

        func read(at p: Int64) async throws -> Data {
            let data = try await source.read(offset: p, length: Int(min(Int64(chunk), end - p)))
            if data.isEmpty { throw StreamSourceError.shortRead }
            return data
        }

        await source.prioritize(offset: position, length: Int(min(Int64(Self.prioritizeWindow), end - position)))
        nextPrioritizeAt = position + Int64(Self.prioritizeWindow / 2)
        var current = try await read(at: position)
        while true {
            let after = position + Int64(current.count)
            async let upcoming: Data = after < end ? read(at: after) : Data()
            do {
                try await send(current)
            } catch {
                _ = try? await upcoming  // child is cancelled by scope exit; drain explicitly
                throw error
            }
            position = after
            if position >= end {
                _ = try await upcoming
                return
            }
            if position >= nextPrioritizeAt {
                await source.prioritize(offset: position, length: Int(min(Int64(Self.prioritizeWindow), end - position)))
                nextPrioritizeAt = position + Int64(Self.prioritizeWindow / 2)
            }
            current = try await upcoming
        }
    }

    // MARK: Output

    private func respond(
        status: Int,
        body: String,
        extra: [(String, String)] = [],
        keepAlive: Bool,
        sendBody: Bool = true
    ) async throws {
        let payload = Data(body.utf8)
        var headers: [(String, String)] = [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Length", String(payload.count)),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
        ] + extra
        if !keepAlive { headers.append(("Connection", "close")) }
        var out = HTTPResponse.head(status: status, headers: headers)
        if sendBody { out.append(payload) }
        try await send(out)
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    // MARK: Pure helpers (internal for tests)

    static func hostAllowed(_ host: String, port: UInt16) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1:\(port)" || h == "localhost:\(port)"
    }

    static func originAllowed(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Extracts the 32-hex-character token from `/<token>[/<filename>][?query]`.
    static func token(fromTarget target: String) -> String? {
        var path = Substring(target)
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<q] }
        guard path.hasPrefix("/") else { return nil }
        let first = path.dropFirst().prefix { $0 != "/" }
        guard first.count == 32, first.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return first.lowercased()
    }
}
