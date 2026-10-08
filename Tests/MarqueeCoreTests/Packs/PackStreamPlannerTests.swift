import Foundation
import Testing
@testable import MarqueeCore

private let mib: Int64 = 1 << 20

private func ref(_ s: String) -> EpisodeRef { EpisodeRef(s)! }

/// A season pack of `count` episodes of `size` bytes each, plus junk, mapped for real.
private func plannerPack(
    count: Int = 10, size: Int64 = 100 * mib, padding: Int64 = 0, extras: Bool = true
) -> (files: [PackFile], mapping: PackMappingResult) {
    var entries: [(String, Int64)] = []
    for e in 1...count {
        entries.append((String(format: "Show.Name.S01.1080p/Show.Name.S01E%02d.1080p.mkv", e), size + Int64(e) * padding))
        entries.append((String(format: "Show.Name.S01.1080p/Show.Name.S01E%02d.1080p.en.srt", e), 50_000))
    }
    if extras {
        entries.append(("Show.Name.S01.1080p/Extras/Making Of.mkv", 40 * mib))
        entries.append(("Show.Name.S01.1080p/Sample/sample.mkv", 20 * mib))
        entries.append(("Show.Name.S01.1080p/info.nfo", 3_000))
        entries.append(("Show.Name.S01.1080p/codec.exe", 1 * mib))
    }
    let files = PackFile.layout(entries.map { ($0.0, $0.1) })
    let eps = (1...count).map { PackEpisode(ref: EpisodeRef(season: 1, episode: $0)) }
    let mapping = PackFileMapper.map(files: files, series: PackSeriesContext(title: "Show Name", episodes: eps, targetSeasons: [1]))
    return (files, mapping)
}

private func episodeFile(_ files: [PackFile], _ e: Int) -> Int {
    files.first { $0.path.hasSuffix(String(format: "S01E%02d.1080p.mkv", e)) }!.index
}

private func subFile(_ files: [PackFile], _ e: Int) -> Int {
    files.first { $0.path.hasSuffix(String(format: "S01E%02d.1080p.en.srt", e)) }!.index
}

@Suite("PackStreamPlanner")
struct PackStreamPlannerTests {
    @Test func gradientFromEpisodeOne() {
        let (files, mapping) = plannerPack()
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: mib)
        let plan = planner.makePlan(start: ref("S01E01"))
        let p = (1...10).map { plan.priorities[episodeFile(files, $0)]!.rawValue }
        #expect(p == [7, 6, 5, 4, 3, 2, 1, 1, 1, 1])
        #expect(plan.currentEpisodes == [ref("S01E01")] && plan.nextEpisodes == [ref("S01E02")])
        // Subtitles follow their episode; junk is skipped; every file has an entry.
        #expect(plan.priorities[subFile(files, 1)] == .top && plan.priorities[subFile(files, 3)]!.rawValue == 5)
        for f in files where f.path.contains("Extras") || f.path.contains("Sample") || f.path.hasSuffix(".nfo") || f.path.hasSuffix(".exe") {
            #expect(plan.priorities[f.index] == .skip, "\(f.path)")
        }
        #expect(plan.priorities.count == files.count)
    }

    @Test func startingMidSeasonDownloadsEarlierEpisodesLast() {
        let (files, mapping) = plannerPack()
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan(start: ref("S01E04"))
        let p = (1...10).map { plan.priorities[episodeFile(files, $0)]!.rawValue }
        #expect(p == [1, 1, 1, 7, 6, 5, 4, 3, 2, 1])
    }

    @Test func wholeTorrentOptionIncludesJunkButNeverExecutables() {
        let (files, mapping) = plannerPack()
        var o = StreamPlanOptions()
        o.downloadWholeTorrent = true
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o).makePlan()
        for f in files {
            let isExe = f.path.hasSuffix(".exe")
            #expect(plan.priorities[f.index]! == (isExe ? .skip : plan.priorities[f.index]!))
            if isExe { #expect(plan.priorities[f.index] == .skip) } else { #expect(plan.priorities[f.index]!.rawValue >= 1, "\(f.path)") }
        }
    }

    @Test func downloadWholeSeasonBoostsOnlyCurrentAndNext() {
        let (files, mapping) = plannerPack()
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan(start: ref("S01E02"), mode: .downloadWholeSeason)
        let p = (1...10).map { plan.priorities[episodeFile(files, $0)]!.rawValue }
        #expect(p == [4, 7, 6, 4, 4, 4, 4, 4, 4, 4])
    }

    @Test func onlySelectedSkipsEverythingElse() {
        let (files, mapping) = plannerPack()
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib)
            .makePlan(start: ref("S01E01"), mode: .onlySelected([ref("S01E05"), ref("S01E02")]))
        let p = (1...10).map { plan.priorities[episodeFile(files, $0)]!.rawValue }
        #expect(p == [7, 6, 0, 0, 5, 0, 0, 0, 0, 0])
        #expect(plan.priorities[subFile(files, 3)] == .skip && plan.priorities[subFile(files, 5)] == FilePriority(5))
        #expect(plan.nextEpisodes == [ref("S01E02")])
    }

    @Test func onlySelectedAlwaysIncludesTheStartEpisode() {
        let (files, mapping) = plannerPack()
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan(start: ref("S01E03"), mode: .onlySelected([ref("S01E06")]))
        #expect(plan.priorities[episodeFile(files, 3)] == .top)
        #expect(plan.priorities[episodeFile(files, 6)]!.rawValue == 6)
        #expect(plan.priorities[episodeFile(files, 4)] == .skip)
    }

    @Test func streamOnlyKeepsCurrentPlusLookahead() {
        let (files, mapping) = plannerPack()
        var o = StreamPlanOptions()
        o.streamOnlyLookahead = 2
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o).makePlan(start: ref("S01E05"), mode: .streamOnly)
        let p = (1...10).map { plan.priorities[episodeFile(files, $0)]!.rawValue }
        #expect(p == [0, 0, 0, 0, 7, 6, 5, 0, 0, 0])
    }

    @Test func customOrderAndUnknownStart() {
        let (files, mapping) = plannerPack(count: 4)
        let order = [ref("S01E04"), ref("S01E03"), ref("S01E02"), ref("S01E01")]
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: mib, order: order)
        #expect(planner.playableEpisodes == order)
        let plan = planner.makePlan()
        #expect(plan.priorities[episodeFile(files, 4)] == .top && plan.priorities[episodeFile(files, 3)]!.rawValue == 6)
        // Start episode not in the pack: snaps to the next playable one.
        let gappy = PackFileMapper.map(
            files: PackFile.layout([("Show.Name.S01E01.mkv", 100 * mib), ("Show.Name.S01E03.mkv", 100 * mib)]),
            series: PackSeriesContext(title: "Show Name"))
        let p2 = PackStreamPlanner(mapping: gappy, pieceLength: mib).makePlan(start: ref("S01E02"))
        #expect(p2.currentEpisodes == [ref("S01E03")])
    }

    @Test func specialsPlayLastByDefault() {
        let files = PackFile.layout([
            ("Show.Name.S00E01.mkv", 50 * mib), ("Show.Name.S01E01.mkv", 50 * mib), ("Show.Name.S01E02.mkv", 50 * mib),
        ])
        let m = PackFileMapper.map(files: files, series: PackSeriesContext(title: "Show Name"))
        let planner = PackStreamPlanner(mapping: m, pieceLength: mib)
        #expect(planner.playableEpisodes == [ref("S01E01"), ref("S01E02"), ref("S00E01")])
    }

    // MARK: deadlines

    @Test func initialDeadlinesStartWithHeadThenTailThenWindow() {
        let (files, mapping) = plannerPack(extras: false)
        var o = StreamPlanOptions()
        o.headBytes = 2 * mib
        o.tailBytes = 1 * mib
        o.windowBytes = 8 * mib
        o.rolloverBytes = mib
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o)
        let plan = planner.makePlan(start: ref("S01E01"))
        let f = files[episodeFile(files, 1)]
        let first = Int(f.offset / mib)
        let last = Int((f.offset + f.size - 1) / mib)
        let d = plan.deadlines
        // head = first two pieces, tail = last piece, then the window continues from piece 2.
        #expect(Array(d.prefix(3).map(\.piece)) == [first, first + 1, last])
        #expect(Array(d[3...].prefix(6).map(\.piece)) == Array((first + 2)...(first + 7)))
        #expect(Set(d.map(\.piece)).count == d.count, "no duplicate pieces")
        #expect(d.map(\.deadlineMs) == d.map(\.deadlineMs).sorted(), "deadlines never decrease in list order")
        #expect(d.allSatisfy { $0.piece >= first && $0.piece <= last })
        #expect(d[0].deadlineMs == o.baseDeadlineMs)
    }

    @Test func windowDeadlinesIncreaseWithDistance() {
        let (_, mapping) = plannerPack(extras: false)
        var o = StreamPlanOptions()
        o.rolloverBytes = mib
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o).makePlan(start: ref("S01E01"))
        let d = plan.replan(playhead: 40 * mib + 123, includeContainer: false)
        #expect(d.count == 32 + 1 || d.count == 32, "32 MiB window straddling a piece boundary")
        for (a, b) in zip(d, d.dropFirst()) {
            #expect(b.piece == a.piece + 1)
            #expect(b.deadlineMs > a.deadlineMs)
        }
        #expect(d[0].deadlineMs == StreamPlanOptions().baseDeadlineMs)
        #expect(d[1].deadlineMs - d[0].deadlineMs == StreamPlanOptions().pieceStepMs)
    }

    @Test func seekReplanPutsTheNewPlayheadFirst() {
        let (files, mapping) = plannerPack(extras: false)
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan(start: ref("S01E03"))
        let f = files[episodeFile(files, 3)]
        let playhead: Int64 = 70 * mib + 5
        let d = plan.replan(playhead: playhead, includeContainer: false)
        #expect(d[0].piece == Int((f.offset + playhead) / mib))
        #expect(d[0].deadlineMs == StreamPlanOptions().baseDeadlineMs)
        // Seeking back and forth is stateless: same playhead, same answer.
        #expect(plan.replan(playhead: playhead, includeContainer: false) == d)
    }

    @Test func haveSkipsCompletedPiecesButKeepsDistanceBasedDeadlines() {
        let (files, mapping) = plannerPack(extras: false)
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan(start: ref("S01E01"))
        let total = Int((files.last!.offset + files.last!.size + mib - 1) / mib)
        var have = PieceAvailability(pieceCount: total)
        let all = plan.replan(playhead: 10 * mib, includeContainer: false)
        have.insert(all[0].piece)
        have.insert(all[1].piece)
        let some = plan.replan(playhead: 10 * mib, have: have, includeContainer: false)
        #expect(some.count == all.count - 2)
        #expect(some[0].piece == all[2].piece && some[0].deadlineMs == all[2].deadlineMs)
    }

    @Test func nearEndIncludesNextEpisodeHeadAndTail() {
        let (files, mapping) = plannerPack(extras: false)
        var o = StreamPlanOptions()
        o.windowBytes = 8 * mib
        o.rolloverBytes = 20 * mib
        o.headBytes = 2 * mib
        o.tailBytes = 1 * mib
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o).makePlan(start: ref("S01E01"))
        let cur = files[episodeFile(files, 1)], nxt = files[episodeFile(files, 2)]
        let nxtFirst = Int(nxt.offset / mib), nxtLast = Int((nxt.offset + nxt.size - 1) / mib)

        // Far from the end: nothing from episode 2.
        let early = plan.replan(playhead: 10 * mib, includeContainer: false)
        #expect(early.allSatisfy { $0.piece < nxtFirst })

        // 30 MiB from the end: still beyond the rollover threshold.
        #expect(plan.replan(playhead: cur.size - 30 * mib, includeContainer: false).allSatisfy { $0.piece < nxtFirst })

        // 15 MiB from the end (inside rollover, window not yet spilling): next head and tail are queued after the window.
        let near = plan.replan(playhead: cur.size - 15 * mib, includeContainer: false)
        let nextPieces = near.filter { $0.piece >= nxtFirst }
        let nm = PieceMap(pieceLength: mib, torrentSize: mapping.assignments.map { $0.offset + $0.size }.max()!, fileOffset: nxt.offset, fileLength: nxt.size)!
        let expectedNext = Array(nm.pieces(forFileRange: 0..<(2 * mib))) + Array(nm.pieces(forFileRange: (nxt.size - mib)..<nxt.size))
        #expect(nextPieces.map(\.piece) == expectedNext.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } })
        #expect(nextPieces.first?.piece == nxtFirst && nextPieces.last?.piece == nxtLast)
        let lastCurrent = near.filter { $0.piece < nxtFirst }.map(\.deadlineMs).max()!
        #expect(nextPieces.allSatisfy { $0.deadlineMs > lastCurrent })
        #expect(nextPieces.map(\.deadlineMs) == nextPieces.map(\.deadlineMs).sorted())
    }

    @Test func deadlinesSlideAcrossTheFileBoundary() {
        let (files, mapping) = plannerPack(extras: false)
        var o = StreamPlanOptions()
        o.windowBytes = 16 * mib
        o.headBytes = 1 * mib
        o.tailBytes = 1 * mib
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o).makePlan(start: ref("S01E01"))
        let cur = files[episodeFile(files, 1)], nxt = files[episodeFile(files, 2)]
        let d = plan.replan(playhead: cur.size - 4 * mib, includeContainer: false)
        let nxtFirst = Int(nxt.offset / mib)
        let pieces = d.map(\.piece)
        // Contiguous run from the playhead through the boundary into episode 2 (episodes are adjacent in the torrent here).
        let run = Array(pieces.prefix { _ in true })
        #expect(run.first == Int((cur.offset + cur.size - 4 * mib) / mib))
        let crossing = d.filter { $0.piece >= nxtFirst }
        #expect(crossing.count >= 12, "the 16 MiB window spills ~12 MiB into the next episode")
        // Strictly increasing deadlines along the contiguous part of the window.
        let window = d.prefix { $0.piece <= nxtFirst + 11 }
        for (a, b) in zip(window, window.dropFirst()) { #expect(b.deadlineMs > a.deadlineMs) }
    }

    @Test func sharedBoundaryPieceIsEmittedOnce() {
        // Unaligned file sizes so consecutive episodes share a piece.
        let (files, mapping) = plannerPack(count: 3, size: 100 * mib + 1234, extras: false)
        var o = StreamPlanOptions()
        o.windowBytes = 8 * mib
        o.rolloverBytes = 64 * mib
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib, options: o).makePlan(start: ref("S01E01"))
        let cur = files[episodeFile(files, 1)]
        let d = plan.replan(playhead: cur.size - 2 * mib, includeContainer: true)
        #expect(Set(d.map(\.piece)).count == d.count)
    }

    @Test func lastEpisodeHasNoRollover() {
        let (files, mapping) = plannerPack(extras: false)
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan(start: ref("S01E10"))
        #expect(plan.next == nil)
        let f = files[episodeFile(files, 10)]
        let d = plan.replan(playhead: f.size - mib)
        #expect(d.allSatisfy { Int64($0.piece) * mib < f.offset + f.size })
    }

    @Test func playheadClampsToTheFile() {
        let (_, mapping) = plannerPack(extras: false)
        let plan = PackStreamPlanner(mapping: mapping, pieceLength: mib).makePlan()
        _ = plan.replan(playhead: -50)
        _ = plan.replan(playhead: Int64.max / 2)
        #expect(plan.replan(playhead: 1 << 50, includeContainer: false).count <= 40)
    }

    @Test func archiveSetStreamsAcrossVolumes() {
        let names = ["pack/x.rar", "pack/x.r00", "pack/x.r01", "pack/x2.rar", "pack/x2.r00"]
        let files = PackFile.layout(names.map { ($0, 10 * mib) })
        // Volumes are not in watch order in the torrent: episode 2's set comes first by name? use names to force it.
        let c = PackSeriesContext(
            title: "Show", episodes: [PackEpisode(ref: ref("S01E01")), PackEpisode(ref: ref("S01E02"))])
        var f2 = files
        f2[0].path = "pack/show.s01e01.rar"; f2[1].path = "pack/show.s01e01.r00"; f2[2].path = "pack/show.s01e01.r01"
        f2[3].path = "pack/show.s01e02.rar"; f2[4].path = "pack/show.s01e02.r00"
        let m = PackFileMapper.map(files: f2, series: c)
        #expect(m.archiveSets.count == 2)
        var o = StreamPlanOptions()
        o.windowBytes = 64 * mib
        o.headBytes = 1 * mib
        o.tailBytes = 1 * mib
        let plan = PackStreamPlanner(mapping: m, pieceLength: mib, options: o).makePlan(start: ref("S01E01"))
        #expect(plan.currentFiles == [0, 1, 2] && plan.currentLength == 30 * mib)
        #expect(plan.priorities[0] == .top && plan.priorities[2] == .top && plan.priorities[3]!.rawValue == 6)
        let d = plan.replan(playhead: 15 * mib)
        #expect(d.contains { $0.piece == 29 } && d.contains { $0.piece == 15 })
        #expect(Set(d.map(\.piece)).count == d.count)
    }

    @Test func emptyMappingGivesEmptyPlan() {
        let m = PackFileMapper.map(files: PackFile.layout([("readme.txt", 10)]), series: PackSeriesContext(title: "X"))
        let plan = PackStreamPlanner(mapping: m, pieceLength: mib).makePlan()
        #expect(plan.current == nil && plan.deadlines.isEmpty)
        #expect(plan.priorities[0] == .skip)
    }

    @Test func filePriorityClamps() {
        #expect(FilePriority(99).rawValue == 7 && FilePriority(-3).rawValue == 0)
        #expect(FilePriority.low < FilePriority.top)
    }

    // MARK: performance

    @Test func replanIsFastOnLargeTorrents() {
        // 200 files x 150 MiB, 1 MiB pieces = 30,000 pieces.
        var entries: [(String, Int64)] = []
        for s in 1...10 {
            for e in 1...20 { entries.append((String(format: "Show.Name.S%02d.1080p/Show.Name.S%02dE%02d.1080p.mkv", s, s, e), 150 * mib)) }
        }
        let files = PackFile.layout(entries.map { ($0.0, $0.1) })
        let eps = (1...10).flatMap { s in (1...20).map { PackEpisode(ref: EpisodeRef(season: s, episode: $0)) } }
        let mapping = PackFileMapper.map(files: files, series: PackSeriesContext(title: "Show Name", episodes: eps))
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: mib)
        #expect(planner.torrentSize / mib == 30_000)
        let plan = planner.makePlan(start: EpisodeRef(season: 3, episode: 7))

        let clock = ContinuousClock()
        var sink = 0
        let n = 200
        let t = clock.measure {
            for i in 0..<n {
                let d = plan.replan(playhead: Int64(i % 140) * mib + 17, includeContainer: i % 2 == 0)
                sink &+= d.count
            }
        }
        let perCall = t / n
        let micros = Double(perCall.components.attoseconds) / 1e12 + Double(perCall.components.seconds) * 1e6
        print("PACK PLANNER replan: \(micros) us/call (200 files, 30k pieces, \(sink / n) deadlines)")
        #if DEBUG
        #expect(micros < 20_000, "debug build; the release budget is 1 ms")
        #else
        #expect(micros < 1_000)
        #endif

        let t2 = clock.measure { _ = planner.makePlan(start: EpisodeRef(season: 3, episode: 7)) }
        print("PACK PLANNER makePlan: \(Double(t2.components.attoseconds) / 1e12) us")
    }

    @Test func replanStaysFastWithTinyPieces() {
        // 10 files x 48 MiB with 16 KiB pieces = 30,720 pieces; the default 32 MiB window is ~2,000 deadlines.
        let files = PackFile.layout((1...10).map { (String(format: "Show.Name.S01E%02d.mkv", $0), 48 * mib) })
        let eps = (1...10).map { PackEpisode(ref: EpisodeRef(season: 1, episode: $0)) }
        let mapping = PackFileMapper.map(files: files, series: PackSeriesContext(title: "Show Name", episodes: eps))
        let o = StreamPlanOptions()
        let planner = PackStreamPlanner(mapping: mapping, pieceLength: 16 * 1024, options: o)
        let plan = planner.makePlan()
        let clock = ContinuousClock()
        var count = 0
        let t = clock.measure { for i in 0..<100 { count += plan.replan(playhead: Int64(i) * 100_000).count } }
        let micros = Double(t.components.attoseconds) / 1e12 / 100
        print("PACK PLANNER tiny pieces replan: \(micros) us/call (\(count / 100) deadlines)")
        #if DEBUG
        #expect(micros < 60_000)
        #else
        #expect(micros < 1_000)
        #endif
    }
}
