import Foundation
import Testing
@testable import MarqueeCore

private func files(_ names: [String], size: Int64 = 1 << 20) -> [PackFile] {
    PackFile.layout(names.map { ($0, size) })
}

@Suite("ArchiveGrouper")
struct ArchiveSetTests {
    @Test func oldStyleRarOrdersRarThenR00ThroughS00() {
        var names = ["d/x.r01", "d/x.s00", "d/x.rar", "d/x.r00", "d/x.r99", "d/x.r02"]
        names.shuffle()
        let sets = ArchiveGrouper.group(files(names))
        #expect(sets.count == 1)
        let order = sets[0].volumes.map { ($0.path as NSString).lastPathComponent }
        #expect(order == ["x.rar", "x.r00", "x.r01", "x.r02", "x.r99", "x.s00"])
        #expect(sets[0].format == .rar)
        // 3..98 are absent between .r02 and .r99
        #expect(!sets[0].isComplete)
    }

    @Test func partNumbersSortNumericallyNotLexically() {
        let names = (1...12).reversed().map { "p/show.part\($0).rar" }
        let sets = ArchiveGrouper.group(files(names))
        #expect(sets.count == 1)
        #expect(sets[0].volumes.map(\.number) == Array(1...12))
        #expect(sets[0].isComplete)
        #expect(sets[0].baseName == "show")
    }

    @Test func partNumbersDetectGaps() {
        let sets = ArchiveGrouper.group(files(["a.part01.rar", "a.part02.rar", "a.part04.rar"]))
        #expect(sets[0].missingVolumes == [3])
        let late = ArchiveGrouper.group(files(["a.part2.rar", "a.part3.rar"]))
        #expect(late[0].missingVolumes == [1], "part1 is absent")
    }

    @Test func zipVolumesPutTheZipLast() {
        let sets = ArchiveGrouper.group(files(["z/a.zip", "z/a.z02", "z/a.z01", "z/a.z03"]))
        #expect(sets.count == 1)
        #expect(sets[0].volumes.map { ($0.path as NSString).lastPathComponent } == ["a.z01", "a.z02", "a.z03", "a.zip"])
        #expect(sets[0].isComplete)
        let broken = ArchiveGrouper.group(files(["z/a.z01", "z/a.z02"]))
        #expect(broken[0].missingVolumes == [3], "closing .zip is absent")
    }

    @Test func sevenZipSplitVolumes() {
        let sets = ArchiveGrouper.group(files(["s/a.7z.003", "s/a.7z.001", "s/a.7z.002"]))
        #expect(sets.count == 1 && sets[0].format == .sevenZip)
        #expect(sets[0].volumes.map(\.number) == [1, 2, 3])
        #expect(sets[0].isComplete)
    }

    @Test func separateBasenamesAndDirectoriesMakeSeparateSets() {
        let sets = ArchiveGrouper.group(files([
            "ep1/grp-show-s01e01.rar", "ep1/grp-show-s01e01.r00",
            "ep2/grp-show-s01e02.rar", "ep2/grp-show-s01e02.r00",
            "flat-s01e03.rar", "flat-s01e03.r00", "flat-s01e04.rar", "flat-s01e04.r00",
            "readme.nfo", "movie.mkv",
        ]))
        #expect(sets.count == 4)
        #expect(sets.allSatisfy { $0.volumes.count == 2 && $0.isComplete })
        #expect(sets.map { $0.volumes[0].fileIndex } == [0, 2, 4, 6], "sets are ordered by first file")
    }

    @Test func sameBaseDifferentFormatsDoNotMerge() {
        let sets = ArchiveGrouper.group(files(["a.rar", "a.zip"]))
        #expect(sets.count == 2)
    }

    @Test func volumeOffsetsAndSizesAreKept() {
        let f = [PackFile(index: 0, path: "a.rar", size: 10, offset: 100), PackFile(index: 1, path: "a.r00", size: 20, offset: 110)]
        let s = ArchiveGrouper.group(f)[0]
        #expect(s.totalSize == 30)
        #expect(s.volumes.map(\.offset) == [100, 110])
        #expect(s.fileIndexes == [0, 1])
    }

    @Test func nonArchivesAreIgnored() {
        #expect(ArchiveGrouper.group(files(["a.mkv", "a.nfo", "a.srt", "r00", ".hidden"])).isEmpty)
        #expect(ArchiveGrouper.isArchiveName("x.part03.rar"))
        #expect(!ArchiveGrouper.isArchiveName("x.mkv"))
    }

    @Test func caseInsensitiveExtensionsAndBases() {
        let sets = ArchiveGrouper.group(files(["D/Show.S01E01.RAR", "D/Show.S01E01.R00", "d/show.s01e01.r01"]))
        #expect(sets.count == 1)
        #expect(sets[0].volumes.count == 3)
    }
}
