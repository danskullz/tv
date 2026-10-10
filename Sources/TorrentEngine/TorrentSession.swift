import CTorrentShim
import Foundation
import Synchronization

/// A libtorrent session. All torrent operations go through this actor; libtorrent itself runs on
/// its own threads, so calls return quickly and never block on network I/O.
///
/// Events (`events()`) are delivered from a dedicated thread that sleeps until libtorrent signals
/// that alerts are pending: there are no polling timers anywhere in this module.
public actor TorrentSession {
    private let native: NativeSession
    private let hub: EventHub
    private var isShutDown = false

    /// The version of the bundled libtorrent, e.g. "2.0.15.0".
    public nonisolated static var libraryVersion: String { String(cString: mq_libtorrent_version()) }

    public init(configuration: SessionConfiguration = SessionConfiguration()) throws {
        let hub = EventHub()
        self.hub = hub
        let native = try NativeSession(configuration: configuration, hub: hub)
        self.native = native
        if configuration.orderedDiskIO {
            // Hash jobs go to the generic pool when there are no dedicated hashing threads, and a pool of
            // one runs jobs in submission order.
            try Self.check(mq_session_set_int(native.pointer, "aio_threads", 1), message: nil)
            try Self.check(mq_session_set_int(native.pointer, "hashing_threads", 0), message: nil)
        }
    }

    // MARK: Events

    /// A new stream of every event from now on. Subscribe *before* the operation whose events you
    /// care about. Streams are unbounded and end when the session shuts down.
    public nonisolated func events() -> AsyncStream<TorrentEvent> { hub.subscribe() }

    /// The TCP port the session listens on (useful with `"…:0"` listen interfaces).
    public nonisolated func tcpListenPort(timeout: Duration = .seconds(10)) async throws -> Int {
        let stream = hub.subscribe()
        if let port = hub.listenPort(.tcp) { return port }
        return try await Self.wait(on: stream, timeout: timeout) { event in
            switch event {
            case let .listening(port, _, .tcp): return port
            case let .listenFailed(_, message, .tcp): throw TorrentError.libtorrent(message)
            default: return nil
            }
        }
    }

    // MARK: Lifecycle

    /// Stops all activity and releases the session. Blocks (off the actor) until libtorrent has
    /// finished announcing and closing sockets, typically well under a second without trackers.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        let native = native
        await Task.detached { native.close() }.value
        hub.finishAll()
    }

    // MARK: Settings

    public func setBool(_ name: String, _ value: Bool) throws { try check(mq_session_set_bool(pointer(), name, value ? 1 : 0)) }
    public func setInt(_ name: String, _ value: Int) throws { try check(mq_session_set_int(pointer(), name, Int32(clamping: value))) }
    public func setString(_ name: String, _ value: String) throws { try check(mq_session_set_string(pointer(), name, value)) }

    // MARK: Adding torrents

    public func addMagnet(_ uri: String, savePath: String, options: AddOptions = []) throws -> TorrentID {
        let p = try pointer()
        return try Self.addCall { id, error in mq_session_add_magnet(p, uri, savePath, options.rawValue, id, error) }
    }

    /// Adds a `.torrent` file's contents. `filePriorities` (0 = skip ... 7) is applied before any
    /// piece is requested.
    public func addTorrent(
        data: Data, savePath: String, options: AddOptions = [], filePriorities: [UInt8] = []
    ) throws -> TorrentID {
        let p = try pointer()
        return try Self.addCall { id, error in
            data.withUnsafeBytes { raw in
                filePriorities.withUnsafeBufferPointer { prios in
                    mq_session_add_torrent_data(
                        p, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, savePath,
                        options.rawValue, prios.baseAddress, prios.count, id, error)
                }
            }
        }
    }

    /// Restores a torrent from data produced by `saveResumeData(_:)`.
    public func addResumeData(
        _ data: Data, savePath: String? = nil, options: AddOptions = []
    ) throws -> TorrentID {
        let p = try pointer()
        return try Self.addCall { id, error in
            data.withUnsafeBytes { raw in
                Self.withOptionalCString(savePath) { path in
                    mq_session_add_resume_data(
                        p, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, path,
                        options.rawValue, id, error)
                }
            }
        }
    }

    // MARK: Control

    public func pause(_ id: TorrentID) throws { try check(mq_torrent_pause(pointer(), id.hex)) }
    public func resume(_ id: TorrentID) throws { try check(mq_torrent_resume(pointer(), id.hex)) }
    /// Leaves `AddOptions.holdDownload`.
    public func startDownload(_ id: TorrentID) throws { try check(mq_torrent_start_download(pointer(), id.hex)) }

    /// Removes the torrent and does not return until the engine has confirmed it is gone.
    ///
    /// `remove_torrent` only posts a job: the torrent stays in the session until libtorrent's own
    /// thread runs it. Because a torrent is keyed by its info-hash, adding the same download inside
    /// that window does not create a torrent — libtorrent hands back the existing one. A caller that
    /// tore one attempt down and immediately started the next on the same download would silently
    /// adopt the dying torrent and watch it disappear a moment later. Waiting closes that window, so
    /// "removed" means removed by the time this returns.
    public func remove(_ id: TorrentID, deleteFiles: Bool = false) async throws {
        let stream = hub.subscribe()  // subscribe first, so the alert cannot land between call and wait
        try check(mq_torrent_remove(pointer(), id.hex, deleteFiles ? 1 : 0))
        await Self.awaitRemoval(of: id, on: stream, timeout: .seconds(2))
    }

    /// Per-torrent rate limits in bytes per second (0 = unlimited). These also apply to loopback and
    /// LAN peers, which the session-wide limits exempt; tests use them to throttle a local swarm.
    public func setUploadLimit(_ id: TorrentID, bytesPerSecond: Int) throws {
        try check(mq_torrent_set_upload_limit(pointer(), id.hex, Int32(clamping: bytesPerSecond)))
    }

    public func setDownloadLimit(_ id: TorrentID, bytesPerSecond: Int) throws {
        try check(mq_torrent_set_download_limit(pointer(), id.hex, Int32(clamping: bytesPerSecond)))
    }

    /// Connects to a peer directly (IP literal), bypassing trackers/DHT.
    public func connectPeer(_ id: TorrentID, host: String, port: Int) throws {
        try check(mq_torrent_connect_peer(pointer(), id.hex, host, UInt16(clamping: port)))
    }

    // MARK: Queries

    public func status(_ id: TorrentID) throws -> TorrentStatus {
        var raw = mq_torrent_status()
        try check(mq_torrent_get_status(pointer(), id.hex, &raw))
        return TorrentStatus(
            state: TorrentState(rawValue: raw.state) ?? .downloading,
            isPaused: raw.paused != 0,
            hasMetadata: raw.has_metadata != 0,
            hasError: raw.has_error != 0,
            progress: Double(raw.progress),
            totalWanted: raw.total_wanted,
            totalWantedDone: raw.total_wanted_done,
            payloadDownloaded: raw.total_payload_download,
            payloadUploaded: raw.total_payload_upload,
            downloadRate: Int(raw.download_rate),
            uploadRate: Int(raw.upload_rate),
            peerCount: Int(raw.num_peers),
            seedCount: Int(raw.num_seeds),
            piecesHave: Int(raw.num_pieces_have),
            pieceCount: Int(raw.num_pieces))
    }

    public func errorMessage(_ id: TorrentID) throws -> String? {
        let p = try pointer()
        guard let c = mq_torrent_error_message(p, id.hex) else { return nil }
        defer { mq_free(c) }
        return String(cString: c)
    }

    /// Name, sizes and the file list. Throws `.noMetadata` for a magnet whose metadata has not
    /// arrived yet; see `waitForMetadata(_:timeout:)`.
    public func metadata(_ id: TorrentID) throws -> TorrentMetadata {
        let p = try pointer()
        var info = mq_torrent_info()
        try check(mq_torrent_get_info(p, id.hex, &info))
        defer { mq_free(info.name) }

        var files: UnsafeMutablePointer<mq_file_entry>?
        var count = 0
        try check(mq_torrent_get_files(p, id.hex, &files, &count))
        defer { mq_files_free(files, count) }
        let entries = (0..<count).map { i -> TorrentFile in
            let f = files![i]
            return TorrentFile(
                index: i, path: String(cString: f.path), size: f.size, offset: f.offset,
                priority: Int(f.priority))
        }
        return TorrentMetadata(
            name: String(cString: info.name), totalSize: info.total_size,
            pieceLength: Int(info.piece_length), pieceCount: Int(info.num_pieces), files: entries)
    }

    /// Returns once the info dictionary is available (immediately if it already is).
    public func waitForMetadata(_ id: TorrentID, timeout: Duration = .seconds(60)) async throws -> TorrentMetadata {
        let stream = hub.subscribe()  // subscribe first so the event cannot slip between check and wait
        do { return try metadata(id) } catch TorrentError.noMetadata {}
        _ = try await Self.wait(on: stream, timeout: timeout) { event -> Bool? in
            switch event {
            case .metadataReceived(id): return true
            case let .metadataFailed(id2, message) where id2 == id: throw TorrentError.libtorrent(message)
            default: return nil
            }
        }
        return try metadata(id)
    }

    /// Bytes downloaded per file, in file order.
    public func fileProgress(_ id: TorrentID, fileCount: Int) throws -> [Int64] {
        var out = [Int64](repeating: 0, count: fileCount)
        try check(mq_torrent_get_file_progress(pointer(), id.hex, &out, fileCount))
        return out
    }

    /// Which pieces are complete right now.
    public func havePieces(_ id: TorrentID) throws -> PieceBitfield {
        var bits: UnsafeMutablePointer<UInt8>?
        var byteCount = 0
        var pieces: Int32 = 0
        try check(mq_torrent_get_have_pieces(pointer(), id.hex, &bits, &byteCount, &pieces))
        defer { mq_free(bits) }
        return PieceBitfield(
            pieceCount: Int(pieces),
            bytes: bits.map { Array(UnsafeBufferPointer(start: $0, count: byteCount)) } ?? [])
    }

    // MARK: Priorities and streaming

    /// One entry per file: 0 = do not download, 1...7 = priority (7 highest).
    public func setFilePriorities(_ id: TorrentID, _ priorities: [UInt8]) throws {
        try check(mq_torrent_set_file_priorities(pointer(), id.hex, priorities, priorities.count))
    }

    public func setPiecePriority(_ id: TorrentID, piece: Int, priority: Int) throws {
        try check(mq_torrent_set_piece_priority(pointer(), id.hex, Int32(piece), Int32(priority)))
    }

    /// Asks libtorrent to have `piece` within `deadline` (time-critical, streaming mode). Deadlines
    /// take precedence over normal rarest-first selection; piece completion still arrives as
    /// `.pieceFinished`.
    public func setPieceDeadline(_ id: TorrentID, piece: Int, deadline: Duration) throws {
        let ms = deadline.components.seconds * 1000 + deadline.components.attoseconds / 1_000_000_000_000_000
        try check(mq_torrent_set_piece_deadline(pointer(), id.hex, Int32(piece), Int32(clamping: ms)))
    }

    public func clearPieceDeadline(_ id: TorrentID, piece: Int) throws {
        try check(mq_torrent_clear_piece_deadline(pointer(), id.hex, Int32(piece)))
    }

    /// Sets many deadlines with one engine lookup: `deadlines[i].piece` within `deadlines[i].deadline`.
    /// Prefer this over a loop of `setPieceDeadline` when replacing a whole window (a seek).
    public func setPieceDeadlines(_ id: TorrentID, _ deadlines: [(piece: Int, deadline: Duration)]) throws {
        guard !deadlines.isEmpty else { return }
        let pieces = deadlines.map { Int32(clamping: $0.piece) }
        let millis = deadlines.map { d -> Int32 in
            let c = d.deadline.components
            return Int32(clamping: c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
        }
        try check(mq_torrent_set_piece_deadlines(pointer(), id.hex, pieces, millis, pieces.count))
    }

    public func clearPieceDeadlines(_ id: TorrentID, pieces: [Int]) throws {
        guard !pieces.isEmpty else { return }
        let raw = pieces.map { Int32(clamping: $0) }
        try check(mq_torrent_clear_piece_deadlines(pointer(), id.hex, raw, raw.count))
    }

    public func clearAllPieceDeadlines(_ id: TorrentID) throws {
        try check(mq_torrent_clear_all_piece_deadlines(pointer(), id.hex))
    }

    /// Reads a complete piece back from disk (it must already be downloaded).
    public func readPiece(_ id: TorrentID, piece: Int, timeout: Duration = .seconds(30)) async throws -> Data {
        let stream = hub.subscribe()
        try check(mq_torrent_read_piece(pointer(), id.hex, Int32(piece)))
        return try await Self.wait(on: stream, timeout: timeout) { event -> Data? in
            switch event {
            case let .pieceRead(id2, p, data) where id2 == id && p == piece: return data
            case let .pieceReadFailed(id2, p, message) where id2 == id && p == piece:
                throw TorrentError.libtorrent(message)
            default: return nil
            }
        }
    }

    // MARK: Resume data

    /// Serialises the torrent's state (including its metadata) for `addResumeData`.
    public func saveResumeData(_ id: TorrentID, timeout: Duration = .seconds(30)) async throws -> Data {
        let stream = hub.subscribe()
        try check(mq_torrent_request_resume_data(pointer(), id.hex))
        return try await Self.wait(on: stream, timeout: timeout) { event -> Data? in
            switch event {
            case let .resumeData(id2, data) where id2 == id: return data
            case let .resumeDataFailed(id2, message) where id2 == id: throw TorrentError.libtorrent(message)
            default: return nil
            }
        }
    }

    // MARK: Internals

    private func pointer() throws -> OpaquePointer {
        guard !isShutDown else { throw TorrentError.sessionClosed }
        return native.pointer
    }

    private func check(_ code: Int32) throws { try Self.check(code, message: nil) }

    private static func check(_ code: Int32, message: String?) throws {
        switch Int(code) {
        case MQ_OK: return
        case MQ_ERR_NOT_FOUND: throw TorrentError.notFound
        case MQ_ERR_NO_METADATA: throw TorrentError.noMetadata
        case MQ_ERR_INVALID: throw message.map { TorrentError.libtorrent($0) } ?? TorrentError.invalidArgument
        case MQ_ERR_DUPLICATE: throw TorrentError.duplicateTorrent
        default: throw TorrentError.libtorrent(message ?? "libtorrent error \(code)")
        }
    }

    private static func addCall(
        _ body: (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) throws -> TorrentID {
        var idBuffer = [CChar](repeating: 0, count: 41)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = idBuffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, &errorPointer) }
        var message: String?
        if let e = errorPointer {
            message = String(cString: e)
            mq_free(e)
        }
        try check(code, message: message)
        return TorrentID(hex: idBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        if let string { return string.withCString(body) }
        return body(nil)
    }

    /// Waits for the first event `match` maps to a value (or throws), racing a timeout.
    private static func wait<T: Sendable>(
        on stream: AsyncStream<TorrentEvent>, timeout: Duration,
        _ match: @escaping @Sendable (TorrentEvent) throws -> T?
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                for await event in stream {
                    if let value = try match(event) { return value }
                }
                throw TorrentError.sessionClosed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TorrentError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Like `wait`, but a timeout or a closed session is not an error: the removal was requested
    /// either way, and the caller is on its way out.
    private static func awaitRemoval(
        of id: TorrentID, on stream: AsyncStream<TorrentEvent>, timeout: Duration
    ) async {
        _ = try? await wait(on: stream, timeout: timeout) { event -> Bool? in
            if case .removed(id, _) = event { return true }
            return nil
        }
    }
}

/// Owns the C session and the retained `EventHub` the C callback points at.
private final class NativeSession: @unchecked Sendable {
    let pointer: OpaquePointer
    private let hubContext: UnsafeMutableRawPointer
    private let closed = Mutex(false)

    init(configuration c: SessionConfiguration, hub: EventHub) throws {
        let context = Unmanaged.passRetained(hub).toOpaque()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let created: OpaquePointer? = TorrentSession.withOptionalCString(c.listenInterfaces) { listen in
            TorrentSession.withOptionalCString(c.bindInterface) { bind in
                TorrentSession.withOptionalCString(c.userAgent) { agent in
                    var config = mq_session_config(
                        listen_interfaces: listen, outgoing_interfaces: bind, user_agent: agent,
                        enable_dht: c.enableDHT ? 1 : 0, enable_lsd: c.enableLocalServiceDiscovery ? 1 : 0,
                        enable_upnp: c.enableUPnP ? 1 : 0, enable_natpmp: c.enableNATPMP ? 1 : 0,
                        encryption_mode: c.encryption.rawValue)
                    return mq_session_create(&config, eventTrampoline, context, &errorPointer)
                }
            }
        }
        guard let created else {
            Unmanaged<EventHub>.fromOpaque(context).release()
            let message = errorPointer.map { p -> String in
                defer { mq_free(p) }
                return String(cString: p)
            }
            throw TorrentError.libtorrent(message ?? "could not create session")
        }
        pointer = created
        hubContext = context
    }

    /// Idempotent. After this returns the callback thread is gone and the hub can be released.
    func close() {
        let shouldClose = closed.withLock { state -> Bool in
            defer { state = true }
            return !state
        }
        guard shouldClose else { return }
        mq_session_destroy(pointer)
        Unmanaged<EventHub>.fromOpaque(hubContext).release()
    }

    deinit { close() }
}

/// Runs on the shim's alert thread.
private func eventTrampoline(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<mq_event>?) {
    guard let context, let event, let translated = TorrentEvent(event) else { return }
    Unmanaged<EventHub>.fromOpaque(context).takeUnretainedValue().publish(translated)
}
