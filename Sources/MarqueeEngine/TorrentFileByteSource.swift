import Foundation
import MarqueeCore
import TorrentEngine

/// A ``StreamByteSource`` for one file of a torrent that may still be downloading.
///
/// Reads come from the file libtorrent writes under the save path (`GrowingFileByteSource` does the
/// positional reads and the waiting for pieces); `prioritize` reaches the engine through the
/// availability provider. The content type comes from the file extension.
public final class TorrentFileByteSource: StreamByteSource {
    public let fileIndex: Int
    public let pieceMap: PieceMap
    public let fileURL: URL
    private let inner: GrowingFileByteSource

    public var length: Int64 { inner.length }
    public var contentType: String { inner.contentType }

    /// - Parameters:
    ///   - savePath: The torrent's save path; the file lives at `savePath/file.path`.
    ///   - availability: Normally a ``TorrentPieceAvailability``.
    public init(
        savePath: URL, file: TorrentFile, pieceMap: PieceMap, availability: any PieceAvailabilityProvider
    ) {
        self.fileIndex = file.index
        self.pieceMap = pieceMap
        self.fileURL = savePath.appendingPathComponent(file.path)
        self.inner = GrowingFileByteSource(url: fileURL, pieceMap: pieceMap, availability: availability)
    }

    /// Convenience: wires a ``TorrentPieceAvailability`` for the file.
    public convenience init(
        session: TorrentSession, torrent: TorrentID, metadata: TorrentMetadata, fileIndex: Int,
        savePath: URL, observer: (any PlayheadObserver)? = nil
    ) throws {
        guard metadata.files.indices.contains(fileIndex) else { throw StreamControllerError.noPlayableFile }
        let file = metadata.files[fileIndex]
        guard let map = Self.pieceMap(for: file, in: metadata) else { throw StreamControllerError.noPlayableFile }
        let availability = TorrentPieceAvailability(
            session: session, torrent: torrent, fileIndex: fileIndex, pieceMap: map, observer: observer)
        self.init(savePath: savePath, file: file, pieceMap: map, availability: availability)
    }

    public static func pieceMap(for file: TorrentFile, in metadata: TorrentMetadata) -> PieceMap? {
        PieceMap(
            pieceLength: Int64(metadata.pieceLength), torrentSize: metadata.totalSize,
            fileOffset: file.offset, fileLength: file.size)
    }

    public func read(offset: Int64, length requested: Int) async throws -> Data {
        try await inner.read(offset: offset, length: requested)
    }

    public func prioritize(offset: Int64, length requested: Int) async {
        await inner.prioritize(offset: offset, length: requested)
    }
}
