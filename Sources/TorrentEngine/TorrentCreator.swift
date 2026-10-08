import CTorrentShim
import Foundation

/// Builds `.torrent` files with libtorrent's `create_torrent`.
public enum TorrentCreator {
    /// Hashes `url` (a file or a directory) and returns the bencoded `.torrent`. Synchronous and
    /// I/O bound: call it off the main actor. `pieceLength` 0 lets libtorrent choose.
    public static func createTorrent(at url: URL, pieceLength: Int = 0) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = mq_create_torrent(url.path, Int32(pieceLength), &bytes, &count, &errorPointer)
        defer {
            mq_free(bytes)
            mq_free(errorPointer)
        }
        guard code == 0, let bytes else {
            throw TorrentError.libtorrent(errorPointer.map { String(cString: $0) } ?? "could not create torrent")
        }
        return Data(bytes: bytes, count: count)
    }
}
