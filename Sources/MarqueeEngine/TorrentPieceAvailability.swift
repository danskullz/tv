import Foundation
import MarqueeCore
import TorrentEngine

/// ``PieceAvailabilityProvider`` backed by one torrent in a ``TorrentSession``.
///
/// - `snapshot()` is the engine's have-bitfield right now.
/// - `completedPieces()` is the session's piece-finished events for this torrent: a push stream built
///   on the engine's alert thread, no polling. It subscribes synchronously, so the "subscribe, then
///   snapshot" contract of ``GrowingFileByteSource`` holds. It ends when the torrent is removed or the
///   session shuts down, which fails any read still waiting.
/// - `prioritize(pieces:)` turns the reader's position into a playhead for the file this provider
///   serves and forwards it to the ``PlayheadObserver`` (normally the ``TorrentDeadlineScheduler``,
///   which re-runs `StreamPlan.replan` and sends the changed deadlines to the engine).
public final class TorrentPieceAvailability: PieceAvailabilityProvider {
    private let session: TorrentSession
    private let torrent: TorrentID
    private let fileIndex: Int
    private let pieceMap: PieceMap
    private let observer: (any PlayheadObserver)?

    public init(
        session: TorrentSession, torrent: TorrentID, fileIndex: Int, pieceMap: PieceMap,
        observer: (any PlayheadObserver)? = nil
    ) {
        self.session = session
        self.torrent = torrent
        self.fileIndex = fileIndex
        self.pieceMap = pieceMap
        self.observer = observer
    }

    public func snapshot() async -> PieceAvailability {
        let count = pieceMap.pieceCount
        guard let bits = try? await session.havePieces(torrent) else { return PieceAvailability(pieceCount: count) }
        var availability = PieceAvailability(pieceCount: count)
        for piece in 0..<min(count, bits.pieceCount) where bits[piece] { availability.insert(piece) }
        return availability
    }

    public func completedPieces() -> AsyncStream<Int> {
        let events = session.events()  // subscribed now, before the caller takes its snapshot
        let id = torrent
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            loop: for await event in events {
                switch event {
                case .pieceFinished(let t, let piece) where t == id: continuation.yield(piece)
                case .removed(let t, _) where t == id: break loop
                default: break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func prioritize(pieces: Range<Int>) async {
        guard let observer, !pieces.isEmpty else { return }
        // File coordinates of the first byte of the first requested piece. Piece granularity is all
        // the deadline window needs.
        let offset = pieceMap.fileByteRange(ofPiece: pieces.lowerBound).lowerBound
        await observer.playheadMoved(fileIndex: fileIndex, offset: offset)
    }
}
