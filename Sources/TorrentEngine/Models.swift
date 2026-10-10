import Foundation

/// Identifies a torrent inside a session: the info-hash as 40 lowercase hex characters (the v1
/// hash, or the truncated v2 hash for v2-only torrents).
public struct TorrentID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String
    public init(hex: String) { self.hex = hex }
    public var description: String { hex }
}

public enum TorrentState: Int32, Sendable {
    case checkingFiles = 1
    case downloadingMetadata
    case downloading
    /// All wanted pieces are downloaded but some files are skipped, so the torrent is not seeding.
    case finished
    case seeding
    case checkingResumeData
}

public struct TorrentStatus: Sendable {
    public var state: TorrentState
    public var isPaused: Bool
    public var hasMetadata: Bool
    public var hasError: Bool
    /// 0...1 over the wanted (non-skipped) data.
    public var progress: Double
    public var totalWanted: Int64
    public var totalWantedDone: Int64
    public var payloadDownloaded: Int64
    public var payloadUploaded: Int64
    /// Payload bytes per second.
    public var downloadRate: Int
    public var uploadRate: Int
    public var peerCount: Int
    public var seedCount: Int
    public var piecesHave: Int
    /// 0 until metadata is known.
    public var pieceCount: Int

    public init(
        state: TorrentState, isPaused: Bool, hasMetadata: Bool, hasError: Bool, progress: Double,
        totalWanted: Int64, totalWantedDone: Int64, payloadDownloaded: Int64, payloadUploaded: Int64,
        downloadRate: Int, uploadRate: Int, peerCount: Int, seedCount: Int, piecesHave: Int, pieceCount: Int
    ) {
        self.state = state
        self.isPaused = isPaused
        self.hasMetadata = hasMetadata
        self.hasError = hasError
        self.progress = progress
        self.totalWanted = totalWanted
        self.totalWantedDone = totalWantedDone
        self.payloadDownloaded = payloadDownloaded
        self.payloadUploaded = payloadUploaded
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.peerCount = peerCount
        self.seedCount = seedCount
        self.piecesHave = piecesHave
        self.pieceCount = pieceCount
    }
}

public struct TorrentFile: Sendable, Hashable {
    public var index: Int
    /// Path relative to the torrent's save path.
    public var path: String
    public var size: Int64
    /// Byte offset of the file within the torrent's contiguous piece space. The pieces covering the
    /// file are `offset / pieceLength ... (offset + size - 1) / pieceLength`.
    public var offset: Int64
    /// 0 = skip, 1...7 (libtorrent default 4).
    public var priority: Int

    public init(index: Int, path: String, size: Int64, offset: Int64, priority: Int) {
        self.index = index
        self.path = path
        self.size = size
        self.offset = offset
        self.priority = priority
    }
}

public struct TorrentMetadata: Sendable {
    public var name: String
    public var totalSize: Int64
    public var pieceLength: Int
    public var pieceCount: Int
    public var files: [TorrentFile]

    public init(name: String, totalSize: Int64, pieceLength: Int, pieceCount: Int, files: [TorrentFile]) {
        self.name = name
        self.totalSize = totalSize
        self.pieceLength = pieceLength
        self.pieceCount = pieceCount
        self.files = files
    }
}

/// Compact set of completed pieces.
public struct PieceBitfield: Sendable {
    public let pieceCount: Int
    private let bytes: [UInt8]

    init(pieceCount: Int, bytes: [UInt8]) {
        self.pieceCount = pieceCount
        self.bytes = bytes
    }

    public subscript(piece: Int) -> Bool {
        guard piece >= 0, piece < pieceCount else { return false }
        return bytes[piece >> 3] & (1 << UInt8(piece & 7)) != 0
    }

    /// Number of completed pieces.
    public var completedCount: Int { bytes.reduce(0) { $0 + $1.nonzeroBitCount } }
    public var isComplete: Bool { completedCount == pieceCount }
}

public struct AddOptions: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    /// Add the torrent paused.
    public static let paused = AddOptions(rawValue: 1 << 0)
    /// Fetch metadata and connect to peers but request no pieces until `startDownload` is called,
    /// so file priorities can be chosen first (e.g. only the files of one episode of a pack).
    public static let holdDownload = AddOptions(rawValue: 1 << 1)
    public static let sequential = AddOptions(rawValue: 1 << 2)
}

public enum EncryptionMode: Int32, Sendable {
    /// Prefer protocol encryption, fall back to plaintext peers.
    case preferred = 0
    /// Only talk to peers over encrypted connections.
    case required = 1
    case disabled = 2
}

public struct SessionConfiguration: Sendable {
    /// libtorrent `listen_interfaces` syntax, e.g. `"0.0.0.0:6881,[::]:6881"`; `nil` = default.
    public var listenInterfaces: String?
    /// Interface names or addresses outgoing connections are bound to (VPN binding), comma
    /// separated. `nil` = unbound.
    public var bindInterface: String?
    public var userAgent: String?
    public var enableDHT = true
    public var enableLocalServiceDiscovery = true
    public var enableUPnP = true
    public var enableNATPMP = true
    public var encryption: EncryptionMode = .preferred
    /// Run all disk jobs (writes, hashing, reads) on one thread, in submission order. Default `true`.
    ///
    /// libtorrent 2.0's mmap disk I/O hashes a piece from its in-memory store buffer and reports
    /// `piece_finished` while the write jobs for its blocks may still be queued on another disk thread.
    /// Anything that reads the file on the strength of that event (the streaming byte source does)
    /// can then see zeros. One FIFO disk thread makes the event mean "on disk". Turning this off
    /// restores libtorrent's parallel disk pool, which is only safe if nothing reads files that are
    /// still downloading.
    public var orderedDiskIO = true

    public init() {}

    /// A session that never leaves the machine: loopback only, no discovery, no port mapping.
    public static func loopbackOnly(encryption: EncryptionMode = .preferred) -> SessionConfiguration {
        var c = SessionConfiguration()
        c.listenInterfaces = "127.0.0.1:0"
        c.enableDHT = false
        c.enableLocalServiceDiscovery = false
        c.enableUPnP = false
        c.enableNATPMP = false
        c.encryption = encryption
        return c
    }
}

public enum ListenKind: Int32, Sendable {
    case tcp = 0
    case udp = 1
    case tls = 2
    case other = 3
}

/// Why a torrent left the engine.
///
/// libtorrent 2.0 does not say: `torrent_removed_alert` carried a reason enum (`explicit_remove`,
/// `duplicate_torrent`, `ratio_limit_reached`, ...) up to 1.2, but 2.0 replaced it with the info
/// hashes and the client data set at add time. The distinction that still matters is available to
/// us instead, because every removal Marquee performs goes through the shim: did we ask for it?
public enum TorrentRemovalReason: Int32, Sendable {
    /// Nothing asked for it: libtorrent dropped the torrent on its own.
    case byEngine = 0
    /// `TorrentSession.remove(_:deleteFiles:)` asked for this removal.
    case requestedByApp = 1
    /// As above, and the download's files were deleted with it.
    case requestedByAppDeletingFiles = 2

    /// Raw engine wording for the diagnostics bundle. Never shown to the user.
    public var diagnosticsText: String {
        switch self {
        case .byEngine: "the torrent engine removed the download on its own"
        case .requestedByApp: "Marquee removed the download"
        case .requestedByAppDeletingFiles: "Marquee removed the download and deleted its files"
        }
    }
}

public enum TorrentEvent: Sendable {
    case listening(port: Int, address: String, kind: ListenKind)
    case listenFailed(port: Int, message: String, kind: ListenKind)
    case removed(TorrentID, reason: TorrentRemovalReason)
    case metadataReceived(TorrentID)
    case metadataFailed(TorrentID, message: String)
    /// The initial file check finished.
    case checked(TorrentID)
    case stateChanged(TorrentID, TorrentState)
    /// A piece was downloaded and verified. Not emitted for pieces already on disk at check time;
    /// use `TorrentSession.havePieces(_:)` for the full picture.
    case pieceFinished(TorrentID, piece: Int)
    case hashFailed(TorrentID, piece: Int)
    case fileCompleted(TorrentID, file: Int)
    /// Every wanted piece is done.
    case finished(TorrentID)
    case paused(TorrentID)
    case resumed(TorrentID)
    case error(TorrentID, message: String)
    case fileError(TorrentID, file: Int, message: String)
    case pieceRead(TorrentID, piece: Int, data: Data)
    case pieceReadFailed(TorrentID, piece: Int, message: String)
    case resumeData(TorrentID, Data)
    case resumeDataFailed(TorrentID, message: String)
}

public enum TorrentError: Error, Sendable, Equatable {
    case notFound
    case noMetadata
    case invalidArgument
    case libtorrent(String)
    case timedOut
    case sessionClosed
    /// The info-hash is already in the session. Only raised when that torrent is being removed, so
    /// it means "this download is on its way out; wait for it to go before adding it again".
    case duplicateTorrent
}
