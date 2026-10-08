import Testing
@testable import MarqueeCore

@Suite struct StreamingPieceMapTests {
    // Torrent of 10 pieces x 100 bytes = 1000 bytes. File spans bytes 250..<720 (pieces 2...7).
    let map = PieceMap(pieceLength: 100, torrentSize: 1000, fileOffset: 250, fileLength: 470)!

    @Test func rejectsImpossibleGeometry() {
        #expect(PieceMap(pieceLength: 0, torrentSize: 10, fileOffset: 0, fileLength: 1) == nil)
        #expect(PieceMap(pieceLength: 10, torrentSize: 10, fileOffset: 5, fileLength: 6) == nil)
        #expect(PieceMap(pieceLength: 10, torrentSize: 10, fileOffset: -1, fileLength: 1) == nil)
        #expect(PieceMap(pieceLength: 10, torrentSize: 10, fileOffset: 11, fileLength: 0) == nil)
    }

    @Test func pieceCountAndSizes() {
        #expect(map.pieceCount == 10)
        #expect(map.pieceSize(0) == 100)
        #expect(map.pieceSize(10) == 0)
        let short = PieceMap(pieceLength: 100, torrentSize: 1050, fileOffset: 0, fileLength: 1050)!
        #expect(short.pieceCount == 11)
        #expect(short.pieceSize(10) == 50)  // last piece is short
        #expect(short.torrentByteRange(ofPiece: 10) == 1000..<1050)
    }

    @Test func filePieceRange() {
        #expect(map.pieceRange == 2..<8)
    }

    @Test func rangeWithinSinglePiece() {
        // file bytes 10..<20 = torrent 260..<270, inside piece 2
        #expect(map.pieces(forFileRange: 10..<20) == 2..<3)
        #expect(map.pieces(offset: 10, length: 10) == 2..<3)
    }

    @Test func rangeSpanningBoundaries() {
        // file offset 49 -> torrent 299 (piece 2); 51 -> torrent 301 (piece 3)
        #expect(map.pieces(forFileRange: 49..<51) == 2..<4)
        // exact piece edges: torrent 300..<400 is exactly piece 3
        #expect(map.pieces(forFileRange: 50..<150) == 3..<4)
        // one byte past the edge pulls in the next piece
        #expect(map.pieces(forFileRange: 50..<151) == 3..<5)
        #expect(map.pieces(forFileRange: 0..<470) == 2..<8)
    }

    @Test func rangeIsClampedToFile() {
        #expect(map.pieces(forFileRange: -50..<10) == 2..<3)
        #expect(map.pieces(forFileRange: 460..<10_000) == 7..<8)
        #expect(map.pieces(forFileRange: 470..<500).isEmpty)
        #expect(map.pieces(forFileRange: 5..<5).isEmpty)
        #expect(map.pieces(offset: 0, length: 0).isEmpty)
    }

    @Test func fileOffsetIsPieceAligned() {
        let m = PieceMap(pieceLength: 100, torrentSize: 1000, fileOffset: 300, fileLength: 200)!
        #expect(m.pieceRange == 3..<5)
        #expect(m.pieces(forFileRange: 0..<100) == 3..<4)
        #expect(m.pieces(forFileRange: 99..<101) == 3..<5)
    }

    @Test func lastShortPiece() {
        // 3 pieces of 100 + final 30-byte piece; file is the tail 130 bytes (270..<400)
        let m = PieceMap(pieceLength: 100, torrentSize: 330, fileOffset: 200, fileLength: 130)!
        #expect(m.pieceCount == 4)
        #expect(m.pieceRange == 2..<4)
        #expect(m.pieces(forFileRange: 100..<130) == 3..<4)
        #expect(m.fileByteRange(ofPiece: 3) == 100..<130)
        #expect(m.fileByteRange(ofPiece: 2) == 0..<100)
        #expect(m.fileByteRange(ofPiece: 1).isEmpty)
    }

    @Test func zeroLengthFile() {
        let m = PieceMap(pieceLength: 100, torrentSize: 1000, fileOffset: 450, fileLength: 0)!
        #expect(m.pieceRange.isEmpty)
        #expect(m.pieces(forFileRange: 0..<10).isEmpty)
        #expect(m.pieces(offset: 0, length: 10).isEmpty)
        // zero-length file at the very end of the torrent
        let end = PieceMap(pieceLength: 100, torrentSize: 1000, fileOffset: 1000, fileLength: 0)!
        #expect(end.pieceRange.isEmpty)
        // zero-length torrent
        let empty = PieceMap(pieceLength: 100, torrentSize: 0, fileOffset: 0, fileLength: 0)!
        #expect(empty.pieceCount == 0 && empty.pieceRange.isEmpty)
    }

    @Test func fileByteRangeOfPieces() {
        #expect(map.fileByteRange(ofPiece: 2) == 0..<50)       // torrent 250..<300
        #expect(map.fileByteRange(ofPiece: 3) == 50..<150)
        #expect(map.fileByteRange(ofPiece: 7) == 450..<470)    // torrent 700..<720
        #expect(map.fileByteRange(ofPiece: 1).isEmpty)
        #expect(map.fileByteRange(ofPiece: 8).isEmpty)
    }

    @Test func fileSpanningEntireTorrentWithOneHugePiece() {
        let m = PieceMap(pieceLength: 1 << 40, torrentSize: 5_000_000_000, fileOffset: 0, fileLength: 5_000_000_000)!
        #expect(m.pieceCount == 1)
        #expect(m.pieces(forFileRange: 0..<5_000_000_000) == 0..<1)
    }
}

@Suite struct StreamingPieceAvailabilityTests {
    @Test func insertContainsCount() {
        var a = PieceAvailability(pieceCount: 130)
        let firstInsert = a.insert(0), repeatInsert = a.insert(0)
        let ins64 = a.insert(64), ins129 = a.insert(129)
        let outOfRange = a.insert(130), negative = a.insert(-1)
        #expect(firstInsert && !repeatInsert && ins64 && ins129)
        #expect(!outOfRange && !negative)
        #expect(a.count == 3)
        #expect(a.contains(64) && !a.contains(65) && !a.contains(500))
        #expect(!a.isComplete)
    }

    @Test func containsAllAndFirstMissing() {
        var a = PieceAvailability(pieceCount: 200, completed: 0..<200)
        #expect(a.isComplete)
        #expect(a.containsAll(0..<200))
        #expect(!a.containsAll(0..<201))
        #expect(a.containsAll(5..<5))
        let b = PieceAvailability(pieceCount: 200, completed: (0..<200).filter { $0 != 130 })
        #expect(b.firstMissing(in: 0..<200) == 130)
        #expect(b.firstMissing(in: 131..<200) == nil)
        #expect(b.firstMissing(in: 130..<131) == 130)
        #expect(!b.containsAll(100..<150))
        a.insert(3)  // no-op
        #expect(a.count == 200)
    }

    @Test func firstMissingAcrossWordBoundaries() {
        for gap in [0, 1, 62, 63, 64, 65, 127, 128, 190] {
            let a = PieceAvailability(pieceCount: 191, completed: (0..<191).filter { $0 != gap })
            #expect(a.firstMissing(in: 0..<191) == gap)
        }
        // bits beyond pieceCount in the last word must never read as "missing"
        let full = PieceAvailability(pieceCount: 70, completed: 0..<70)
        #expect(full.firstMissing(in: 0..<70) == nil)
    }

    @Test func wireBitfield() {
        let a = PieceAvailability(wireBitfield: [0b1010_0000, 0b0100_0001, 0xFF], pieceCount: 12)
        #expect(a.contains(0) && !a.contains(1) && a.contains(2))
        #expect(a.contains(9))        // byte 1, bit 1
        #expect(!a.contains(11))
        #expect(a.count == 3)         // pieces 15 and 16+ are beyond pieceCount and ignored
        #expect(!a.contains(12))
    }

    @Test func contiguousBytes() {
        // pieces of 100, file at torrent 250..<720 (pieces 2...7)
        let map = PieceMap(pieceLength: 100, torrentSize: 1000, fileOffset: 250, fileLength: 470)!
        var a = PieceAvailability(pieceCount: 10)
        #expect(a.contiguousBytes(from: 0, in: map) == 0)
        a.insert(2)  // file bytes 0..<50
        #expect(a.contiguousBytes(from: 0, in: map) == 50)
        #expect(a.contiguousBytes(from: 20, in: map) == 30)
        #expect(a.contiguousBytes(from: 50, in: map) == 0)
        a.insert(3); a.insert(4)  // through file byte 250
        #expect(a.contiguousBytes(from: 0, in: map) == 250)
        #expect(a.contiguousBytes(from: 120, in: map) == 130)
        a.insert(6)  // gap at 5
        #expect(a.contiguousBytes(from: 0, in: map) == 250)
        a.insert(5); a.insert(7)
        #expect(a.contiguousBytes(from: 0, in: map) == 470)
        #expect(a.contiguousBytes(from: 469, in: map) == 1)
        #expect(a.contiguousBytes(from: 470, in: map) == 0)
        #expect(a.contiguousBytes(from: -1, in: map) == 0)
    }

    @Test func contiguousBytesIgnoresPiecesOutsideFile() {
        let map = PieceMap(pieceLength: 100, torrentSize: 1000, fileOffset: 250, fileLength: 100)!  // pieces 2...3
        let a = PieceAvailability(pieceCount: 10, completed: [2, 3])  // piece 4 missing but not part of the file
        #expect(a.contiguousBytes(from: 0, in: map) == 100)
    }

    @Test func contiguousBytesWithShortLastPiece() {
        let map = PieceMap(pieceLength: 100, torrentSize: 330, fileOffset: 200, fileLength: 130)!
        let a = PieceAvailability(pieceCount: 4, completed: [2, 3])
        #expect(a.contiguousBytes(from: 0, in: map) == 130)
        let b = PieceAvailability(pieceCount: 4, completed: [2])
        #expect(b.contiguousBytes(from: 0, in: map) == 100)
    }
}
