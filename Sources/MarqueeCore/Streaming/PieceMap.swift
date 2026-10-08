import Foundation

/// Maps byte ranges of one file inside a torrent onto torrent piece indices.
///
/// Pure value type: all offsets are `Int64`, "file" coordinates start at 0 at the first byte of
/// the file, "torrent" coordinates start at 0 at the first byte of the torrent's concatenated
/// payload. The last piece of a torrent may be shorter than `pieceLength`.
public struct PieceMap: Sendable, Hashable {
    public let pieceLength: Int64
    /// Total payload size of the torrent (sum of all file sizes).
    public let torrentSize: Int64
    /// Offset of the file's first byte within the torrent payload.
    public let fileOffset: Int64
    public let fileLength: Int64

    /// Fails when the geometry is impossible (non-positive piece length, negative sizes, or a
    /// file that does not fit inside the torrent).
    public init?(pieceLength: Int64, torrentSize: Int64, fileOffset: Int64, fileLength: Int64) {
        guard pieceLength > 0, torrentSize >= 0, fileOffset >= 0, fileLength >= 0,
              fileOffset <= torrentSize, fileLength <= torrentSize - fileOffset
        else { return nil }
        self.pieceLength = pieceLength
        self.torrentSize = torrentSize
        self.fileOffset = fileOffset
        self.fileLength = fileLength
    }

    /// Number of pieces in the whole torrent.
    public var pieceCount: Int {
        Int((torrentSize + pieceLength - 1) / pieceLength)
    }

    /// Pieces that overlap the file at all. Empty for zero-length files.
    public var pieceRange: Range<Int> {
        guard fileLength > 0 else {
            let p = Int(min(fileOffset / pieceLength, Int64(pieceCount)))
            return p..<p
        }
        let first = Int(fileOffset / pieceLength)
        let last = Int((fileOffset + fileLength - 1) / pieceLength)
        return first..<(last + 1)
    }

    /// Size in bytes of piece `index` (the final piece may be short). 0 when out of range.
    public func pieceSize(_ index: Int) -> Int64 {
        guard index >= 0, index < pieceCount else { return 0 }
        let start = Int64(index) * pieceLength
        return min(pieceLength, torrentSize - start)
    }

    /// Torrent-coordinate byte range of a piece.
    public func torrentByteRange(ofPiece index: Int) -> Range<Int64> {
        guard index >= 0, index < pieceCount else { return 0..<0 }
        let start = Int64(index) * pieceLength
        return start..<(start + pieceSize(index))
    }

    /// The part of a piece that belongs to this file, in file coordinates. Empty when the piece
    /// does not overlap the file.
    public func fileByteRange(ofPiece index: Int) -> Range<Int64> {
        let t = torrentByteRange(ofPiece: index)
        let lo = max(t.lowerBound, fileOffset) - fileOffset
        let hi = min(t.upperBound, fileOffset + fileLength) - fileOffset
        return lo < hi ? lo..<hi : 0..<0
    }

    /// Piece containing the byte at `fileOffset` (clamped into the file).
    public func pieceIndex(forFileOffset offset: Int64) -> Int {
        let clamped = min(max(offset, 0), max(fileLength - 1, 0))
        return Int((fileOffset + clamped) / pieceLength)
    }

    /// Pieces needed to serve file bytes `range` (clamped to the file). An empty (or fully
    /// out-of-file) range yields an empty piece range.
    public func pieces(forFileRange range: Range<Int64>) -> Range<Int> {
        let lo = max(range.lowerBound, 0)
        let hi = min(range.upperBound, fileLength)
        guard lo < hi else {
            let p = pieceIndex(forFileOffset: lo)
            return p..<p
        }
        let first = Int((fileOffset + lo) / pieceLength)
        let last = Int((fileOffset + hi - 1) / pieceLength)
        return first..<(last + 1)
    }

    public func pieces(offset: Int64, length: Int64) -> Range<Int> {
        guard length > 0, offset <= Int64.max - length else { return pieces(forFileRange: offset..<offset) }
        return pieces(forFileRange: offset..<(offset + length))
    }
}

/// Bitfield of completed torrent pieces.
public struct PieceAvailability: Sendable, Equatable {
    public let pieceCount: Int
    private var words: [UInt64]
    /// Number of set bits.
    public private(set) var count: Int = 0

    public init(pieceCount: Int) {
        precondition(pieceCount >= 0)
        self.pieceCount = pieceCount
        self.words = Array(repeating: 0, count: (pieceCount + 63) / 64)
    }

    public init(pieceCount: Int, completed: some Sequence<Int>) {
        self.init(pieceCount: pieceCount)
        for p in completed { insert(p) }
    }

    /// Builds from a BitTorrent wire-format bitfield (MSB of byte 0 is piece 0). Spare bits and
    /// bytes beyond `pieceCount` are ignored.
    public init(wireBitfield: some Collection<UInt8>, pieceCount: Int) {
        self.init(pieceCount: pieceCount)
        for (byteIndex, byte) in wireBitfield.enumerated() {
            guard byte != 0 else { continue }
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                insert(byteIndex * 8 + bit)
            }
        }
    }

    public var isComplete: Bool { count == pieceCount }

    public func contains(_ piece: Int) -> Bool {
        guard piece >= 0, piece < pieceCount else { return false }
        return words[piece >> 6] & (1 << UInt64(piece & 63)) != 0
    }

    /// Marks a piece complete. Returns true if the bit changed (false when already set or out of range).
    @discardableResult
    public mutating func insert(_ piece: Int) -> Bool {
        guard piece >= 0, piece < pieceCount else { return false }
        let mask: UInt64 = 1 << UInt64(piece & 63)
        if words[piece >> 6] & mask != 0 { return false }
        words[piece >> 6] |= mask
        count += 1
        return true
    }

    /// True when every piece in `range` is complete. Empty ranges are trivially complete;
    /// ranges reaching outside the torrent are not.
    public func containsAll(_ range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return true }
        guard range.lowerBound >= 0, range.upperBound <= pieceCount else { return false }
        return firstMissing(in: range) == nil
    }

    /// Lowest incomplete piece in `range`, or nil if all are complete.
    public func firstMissing(in range: Range<Int>) -> Int? {
        let lo = max(range.lowerBound, 0)
        let hi = min(range.upperBound, pieceCount)
        guard lo < hi else { return nil }
        var p = lo
        while p < hi {
            let w = ~words[p >> 6] >> UInt64(p & 63)  // set bits = missing pieces, aligned at p
            if w != 0 {
                let candidate = p + w.trailingZeroBitCount
                return candidate < hi ? candidate : nil
            }
            p = ((p >> 6) + 1) << 6
        }
        return nil
    }

    /// Number of bytes, starting at `fileOffset` inside the file described by `map`, that are
    /// available without a gap. 0 if the piece holding `fileOffset` is missing or the offset is
    /// outside the file.
    public func contiguousBytes(from fileOffset: Int64, in map: PieceMap) -> Int64 {
        guard fileOffset >= 0, fileOffset < map.fileLength else { return 0 }
        let first = map.pieceIndex(forFileOffset: fileOffset)
        guard let missing = firstMissing(in: first..<map.pieceRange.upperBound) else {
            return map.fileLength - fileOffset
        }
        let boundary = map.fileByteRange(ofPiece: missing).lowerBound
        return max(0, boundary - fileOffset)
    }
}
