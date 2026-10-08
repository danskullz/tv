import Foundation

/// libtorrent-style file priority, 0 (skip) through 7 (top).
public struct FilePriority: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ value: Int) { rawValue = min(7, max(0, value)) }

    public static let skip = FilePriority(0)
    public static let low = FilePriority(1)
    public static let normal = FilePriority(4)
    public static let high = FilePriority(6)
    public static let top = FilePriority(7)

    public static func < (l: FilePriority, r: FilePriority) -> Bool { l.rawValue < r.rawValue }
    public var description: String { String(rawValue) }
}

/// Ask the engine to have `piece` by `deadlineMs` milliseconds from now (libtorrent `set_piece_deadline`).
public struct PieceDeadline: Sendable, Hashable {
    public var piece: Int
    public var deadlineMs: Int

    public init(piece: Int, deadlineMs: Int) {
        self.piece = piece
        self.deadlineMs = deadlineMs
    }
}

public enum StreamMode: Sendable, Hashable {
    /// Play from the start episode; everything else downloads behind it in watch order.
    case streamFromStart
    /// Stream, but the user wants the whole season soon: the current and next episode are boosted and
    /// everything else downloads at normal priority.
    case downloadWholeSeason
    /// Only the chosen episodes download (the start episode is always included).
    case onlySelected(Set<EpisodeRef>)
    /// Keep nothing beyond the current episode and a short lookahead.
    case streamOnly
}

public struct StreamPlanOptions: Sendable, Hashable {
    /// How far ahead of the playhead deadlines are set.
    public var windowBytes: Int64
    /// Deadline of the first (most urgent) piece, in milliseconds.
    public var baseDeadlineMs: Int
    /// Added to the deadline for every piece of distance from the playhead.
    public var pieceStepMs: Int
    /// Bytes at the start / end of a file fetched first (container headers and indexes).
    public var headBytes: Int64
    public var tailBytes: Int64
    /// When the playhead is this close to the end of the current file, the next episode's head and tail join the plan.
    public var rolloverBytes: Int64
    /// Give files that would otherwise be skipped (extras, samples, duplicates, unselected episodes) priority 1.
    /// Executables are never downloaded.
    public var downloadWholeTorrent: Bool
    /// `.streamOnly` keeps this many episodes after the current one.
    public var streamOnlyLookahead: Int

    public init(
        windowBytes: Int64 = 32 << 20, baseDeadlineMs: Int = 200, pieceStepMs: Int = 100,
        headBytes: Int64 = 2 << 20, tailBytes: Int64 = 2 << 20, rolloverBytes: Int64 = 128 << 20,
        downloadWholeTorrent: Bool = false, streamOnlyLookahead: Int = 1
    ) {
        self.windowBytes = windowBytes
        self.baseDeadlineMs = baseDeadlineMs
        self.pieceStepMs = pieceStepMs
        self.headBytes = headBytes
        self.tailBytes = tailBytes
        self.rolloverBytes = rolloverBytes
        self.downloadWholeTorrent = downloadWholeTorrent
        self.streamOnlyLookahead = streamOnlyLookahead
    }
}

// MARK: - Units

/// A contiguous run of torrent bytes belonging to one playable thing, expressed in "logical" bytes
/// (the item's own byte space: a file, or the concatenation of archive volumes).
struct StreamSegment: Sendable, Hashable {
    var logicalStart: Int64
    var torrentOffset: Int64
    var length: Int64
}

/// One thing to play: a loose video file, or a multi-volume archive set. May cover several episodes.
struct StreamUnit: Sendable, Hashable {
    var refs: [EpisodeRef]
    var fileIndexes: [Int]
    var sidecars: [Int]
    var segments: [StreamSegment]
    var length: Int64
}

// MARK: - Planner

/// Turns a file→episode mapping into download priorities and piece deadlines. Build once per torrent;
/// ``makePlan(start:mode:)`` is cheap and ``StreamPlan/replan(playhead:have:includeContainer:)`` is cheaper still.
public struct PackStreamPlanner: Sendable {
    public let pieceLength: Int64
    public let torrentSize: Int64
    public let options: StreamPlanOptions

    let units: [StreamUnit]  // watch order
    let assignments: [PackFileAssignment]

    /// - Parameters:
    ///   - mapping: Output of ``PackFileMapper``.
    ///   - pieceLength: Torrent piece length in bytes.
    ///   - order: Playback order. Defaults to season/episode order with specials last. Episodes missing
    ///     from `order` are appended in sorted order.
    public init(mapping: PackMappingResult, pieceLength: Int64, order: [EpisodeRef]? = nil, options: StreamPlanOptions = .init()) {
        precondition(pieceLength > 0)
        self.pieceLength = pieceLength
        self.options = options
        self.assignments = mapping.assignments
        self.torrentSize = mapping.assignments.map { $0.offset + $0.size }.max() ?? 0

        // Watch-order index of every episode.
        var all = Set<EpisodeRef>()
        for a in mapping.assignments where a.isPreferred && a.carriesEpisodes { all.formUnion(a.episodes) }
        var ordered = order ?? []
        let inOrder = Set(ordered)
        let rest = all.subtracting(inOrder).sorted { l, r in
            (l.season == 0 ? 1 : 0, l.season, l.episode) < (r.season == 0 ? 1 : 0, r.season, r.episode)
        }
        ordered += rest
        var rank: [EpisodeRef: Int] = [:]
        for (i, r) in ordered.enumerated() where rank[r] == nil { rank[r] = i }

        // Group files into units.
        var built: [StreamUnit] = []
        var byFile: [Int: Int] = [:]
        var setUnit: [String: Int] = [:]
        let sets = Dictionary(uniqueKeysWithValues: mapping.archiveSets.map { ($0.id, $0) })
        for a in mapping.assignments where a.isPreferred && a.carriesEpisodes && !a.episodes.isEmpty {
            if let sid = a.archiveSetID {
                if let u = setUnit[sid] { byFile[a.fileIndex] = u; continue }
                guard let s = sets[sid] else { continue }
                var segs: [StreamSegment] = []
                var logical: Int64 = 0
                for v in s.volumes where v.size > 0 {
                    segs.append(StreamSegment(logicalStart: logical, torrentOffset: v.offset, length: v.size))
                    logical += v.size
                }
                let idx = built.count
                built.append(StreamUnit(refs: a.episodes, fileIndexes: s.volumes.map(\.fileIndex), sidecars: [], segments: segs, length: logical))
                setUnit[sid] = idx
                for v in s.volumes { byFile[v.fileIndex] = idx }
            } else {
                let idx = built.count
                let segs = a.size > 0 ? [StreamSegment(logicalStart: 0, torrentOffset: a.offset, length: a.size)] : []
                built.append(StreamUnit(refs: a.episodes, fileIndexes: [a.fileIndex], sidecars: [], segments: segs, length: a.size))
                byFile[a.fileIndex] = idx
            }
        }
        for a in mapping.assignments where a.role == .subtitle && a.isPreferred {
            if let t = a.attachedTo, let u = byFile[t] { built[u].sidecars.append(a.fileIndex) }
        }
        func key(_ u: StreamUnit) -> Int { u.refs.compactMap { rank[$0] }.min() ?? Int.max }
        self.units = built.sorted { (key($0), $0.fileIndexes[0]) < (key($1), $1.fileIndexes[0]) }
    }

    /// Episodes that can be played, in watch order (multi-episode files appear once per episode).
    public var playableEpisodes: [EpisodeRef] { units.flatMap(\.refs) }

    /// Builds the plan for playing from `start` (default: the first playable episode).
    public func makePlan(start: EpisodeRef? = nil, mode: StreamMode = .streamFromStart) -> StreamPlan {
        var priorities: [Int: FilePriority] = [:]
        priorities.reserveCapacity(assignments.count)
        for a in assignments { priorities[a.fileIndex] = options.downloadWholeTorrent && !a.isSuspicious ? .low : .skip }
        guard !units.isEmpty else {
            return StreamPlan(
                mode: mode, current: nil, next: nil, priorities: priorities, pieceLength: pieceLength,
                torrentSize: torrentSize, options: options)
        }

        var s = 0
        if let start {
            if let i = units.firstIndex(where: { $0.refs.contains(start) }) {
                s = i
            } else if let i = units.firstIndex(where: { $0.refs.contains { $0 >= start } }) {
                s = i
            }
        }

        func assign(_ u: StreamUnit, _ p: FilePriority) {
            for f in u.fileIndexes + u.sidecars { priorities[f] = p }
        }
        func gradient(_ rank: Int) -> FilePriority { FilePriority(max(1, 7 - rank)) }

        var selected: [Int] = []  // unit indexes in the order they download
        switch mode {
        case .streamFromStart:
            for (r, i) in (s..<units.count).enumerated() { assign(units[i], gradient(r)); selected.append(i) }
            for i in 0..<s { assign(units[i], .low); selected.append(i) }
        case .downloadWholeSeason:
            for (r, i) in (s..<units.count).enumerated() { assign(units[i], r == 0 ? .top : r == 1 ? .high : .normal); selected.append(i) }
            for i in 0..<s { assign(units[i], .normal); selected.append(i) }
        case .onlySelected(let chosen):
            let picked = (0..<units.count).filter { $0 == s || units[$0].refs.contains(where: chosen.contains) }
            var r = 0
            for i in picked where i >= s { assign(units[i], gradient(r)); r += 1; selected.append(i) }
            for i in picked where i < s { assign(units[i], .low); selected.append(i) }
        case .streamOnly:
            let end = min(units.count, s + 1 + max(0, options.streamOnlyLookahead))
            for (r, i) in (s..<end).enumerated() { assign(units[i], gradient(r)); selected.append(i) }
        }
        let nextIdx = selected.first { $0 > s }
        return StreamPlan(
            mode: mode, current: units[s], next: nextIdx.map { units[$0] }, priorities: priorities,
            pieceLength: pieceLength, torrentSize: torrentSize, options: options)
    }
}

// MARK: - Plan

public struct StreamPlan: Sendable {
    public let mode: StreamMode
    /// File priorities by torrent file index. Every file of the torrent has an entry.
    public let priorities: [Int: FilePriority]
    public let pieceLength: Int64
    public let torrentSize: Int64
    public let options: StreamPlanOptions

    let current: StreamUnit?
    let next: StreamUnit?

    init(
        mode: StreamMode, current: StreamUnit?, next: StreamUnit?, priorities: [Int: FilePriority],
        pieceLength: Int64, torrentSize: Int64, options: StreamPlanOptions
    ) {
        self.mode = mode
        self.current = current
        self.next = next
        self.priorities = priorities
        self.pieceLength = pieceLength
        self.torrentSize = torrentSize
        self.options = options
    }

    public var currentEpisodes: [EpisodeRef] { current?.refs ?? [] }
    public var nextEpisodes: [EpisodeRef] { next?.refs ?? [] }
    /// Files (video or archive volumes, in read order) of the episode being played.
    public var currentFiles: [Int] { current?.fileIndexes ?? [] }
    public var nextFiles: [Int] { next?.fileIndexes ?? [] }
    /// Length in bytes of the playable item (one file, or all archive volumes together).
    public var currentLength: Int64 { current?.length ?? 0 }
    public var pieceCount: Int { Int((torrentSize + pieceLength - 1) / pieceLength) }

    /// Deadlines for playing from the start of the current item.
    public var deadlines: [PieceDeadline] { replan(playhead: 0) }

    /// Deadlines for a playhead at `playhead` bytes into the current item (for archives: into the
    /// concatenated volumes). Cheap enough to call on every seek.
    ///
    /// - Parameters:
    ///   - have: Completed pieces; those are left out of the result.
    ///   - includeContainer: Include the head and tail (container indexes) of the current item and, near
    ///     the end, of the next one. They come first, ahead of the window.
    public func replan(playhead: Int64, have: PieceAvailability? = nil, includeContainer: Bool = true) -> [PieceDeadline] {
        guard let cur = current, cur.length > 0 else { return [] }
        var b = DeadlineBuilder(plan: self, have: have)
        let p = min(max(playhead, 0), cur.length)

        if includeContainer {
            b.sequential(cur, 0..<min(options.headBytes, cur.length))
            b.sequential(cur, max(0, cur.length - options.tailBytes)..<cur.length)
        }
        let windowEnd = min(cur.length, p &+ options.windowBytes)
        b.window(cur, p..<windowEnd, anchor: p, shift: 0)

        if let nxt = next, nxt.length > 0 {
            let remaining = cur.length - p
            if remaining <= options.rolloverBytes {
                let spill = max(0, options.windowBytes - remaining)
                if spill > 0 {
                    b.window(nxt, 0..<min(nxt.length, max(spill, options.headBytes)), anchor: 0, shift: remaining)
                } else {
                    b.sequentialAfter(nxt, 0..<min(options.headBytes, nxt.length))
                }
                b.sequentialAfter(nxt, max(0, nxt.length - options.tailBytes)..<nxt.length)
            }
        }
        return b.result
    }
}

// MARK: - Deadline construction

private struct DeadlineBuilder {
    let pieceLength: Int64
    let base: Int
    let step: Int
    let pieceCount: Int
    let have: PieceAvailability?
    var result: [PieceDeadline] = []
    var visited: [Range<Int>] = []
    var seq = 0
    var last = 0

    init(plan: StreamPlan, have: PieceAvailability?) {
        pieceLength = plan.pieceLength
        base = plan.options.baseDeadlineMs
        step = plan.options.pieceStepMs
        pieceCount = plan.pieceCount
        self.have = have
        result.reserveCapacity(Int(min(8192, plan.options.windowBytes / plan.pieceLength + 16)))
        last = base - step
    }

    /// New pieces of `logical` (not yet considered in this call, not completed), each with the logical
    /// position where the piece starts inside the unit.
    private mutating func newPieces(_ u: StreamUnit, _ logical: Range<Int64>) -> [(piece: Int, logicalStart: Int64)] {
        var found: [(piece: Int, logicalStart: Int64)] = []
        guard logical.lowerBound < logical.upperBound else { return found }
        for seg in u.segments {
            let segEnd = seg.logicalStart + seg.length
            let lo = max(logical.lowerBound, seg.logicalStart)
            let hi = min(logical.upperBound, segEnd)
            guard lo < hi else { continue }
            let t0 = seg.torrentOffset + (lo - seg.logicalStart)
            let t1 = seg.torrentOffset + (hi - seg.logicalStart)
            let first = Int(t0 / pieceLength)
            let lastPiece = Int((t1 - 1) / pieceLength)
            let prior = visited
            visited.append(first..<(lastPiece + 1))
            var p = first
            while p <= lastPiece {
                if !prior.contains(where: { $0.contains(p) }), !(have?.contains(p) ?? false), p < pieceCount {
                    let pieceStart = max(Int64(p) * pieceLength, t0)
                    found.append((p, seg.logicalStart + (pieceStart - seg.torrentOffset)))
                }
                p += 1
            }
        }
        return found
    }

    /// Container pieces: one after another from the base deadline.
    mutating func sequential(_ u: StreamUnit, _ range: Range<Int64>) {
        let pieces = newPieces(u, range)
        for (i, x) in pieces.enumerated() {
            result.append(PieceDeadline(piece: x.piece, deadlineMs: base + (seq + i) * step))
        }
        seq += pieces.count
        if let l = result.last { last = max(last, l.deadlineMs) }
    }

    /// Pieces that continue after everything emitted so far.
    mutating func sequentialAfter(_ u: StreamUnit, _ range: Range<Int64>) {
        let pieces = newPieces(u, range)
        let start = last + step
        for (i, x) in pieces.enumerated() {
            result.append(PieceDeadline(piece: x.piece, deadlineMs: start + i * step))
        }
        if let l = result.last { last = max(last, l.deadlineMs) }
    }

    /// Sliding window: deadline grows with distance (in pieces) from `anchor`, plus `shift` bytes when
    /// the range sits in a later item.
    mutating func window(_ u: StreamUnit, _ range: Range<Int64>, anchor: Int64, shift: Int64) {
        let pieces = newPieces(u, range)
        for x in pieces {
            let bytes = max(0, x.logicalStart - anchor) + shift
            let dist = Int((bytes + pieceLength - 1) / pieceLength)
            result.append(PieceDeadline(piece: x.piece, deadlineMs: base + (seq + dist) * step))
        }
        if let l = result.last { last = max(last, l.deadlineMs) }
    }
}
