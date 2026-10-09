import Foundation
import MarqueeCore
import TorrentEngine

/// Told where the viewer is reading. The playhead is a byte offset inside the file being played.
public protocol PlayheadObserver: Sendable {
    func playheadMoved(fileIndex: Int, offset: Int64) async
}

/// Keeps libtorrent's piece deadlines in step with the playhead.
///
/// On every playhead move it asks the active ``StreamPlan`` for the deadlines (`replan`, a pure and
/// cheap computation), diffs them against what libtorrent was last told and sends only the
/// difference: new or changed pieces get `set_piece_deadline`, pieces that dropped out of the plan
/// (the playhead jumped past them, or the episode changed) get their deadline cleared. Nothing runs
/// between playhead moves.
///
/// Concurrent requests coalesce: while one apply pass is talking to the engine, further requests mark
/// the state dirty and wait for a follow-up pass that sees the newest playhead.
public actor TorrentDeadlineScheduler: PlayheadObserver {
    private let session: TorrentSession
    private let torrent: TorrentID
    private var plan: StreamPlan
    private var have: PieceAvailability

    /// Piece -> relative deadline (ms) most recently sent to libtorrent and not yet completed.
    public private(set) var appliedDeadlines: [Int: Int] = [:]
    public private(set) var playhead: Int64 = 0
    /// Engine calls made so far; tests and diagnostics use these to check the diffing.
    public private(set) var deadlineSetCount = 0
    public private(set) var deadlineClearCount = 0
    public private(set) var replanCount = 0

    private var applying = false
    private var dirty = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(session: TorrentSession, torrent: TorrentID, plan: StreamPlan, have: PieceAvailability) {
        self.session = session
        self.torrent = torrent
        self.plan = plan
        self.have = have
    }

    /// Sends the initial deadlines (head and tail first, then the window at the playhead).
    public func start(playhead: Int64 = 0) async {
        self.playhead = playhead
        await requestApply()
    }

    /// Switches to a new plan (the next episode became current) and moves the playhead. Only the
    /// difference to the old deadlines reaches the engine, so a rollover that already prefetched the
    /// next head and tail costs nothing.
    public func setPlan(_ plan: StreamPlan, playhead: Int64 = 0) async {
        self.plan = plan
        self.playhead = playhead
        await requestApply()
    }

    /// A piece completed (libtorrent drops its deadline by itself).
    public func markHave(_ piece: Int) {
        have.insert(piece)
        appliedDeadlines.removeValue(forKey: piece)
    }

    public func movePlayhead(to offset: Int64) async {
        playhead = max(0, offset)
        await requestApply()
    }

    public func playheadMoved(fileIndex: Int, offset: Int64) async {
        guard plan.currentFiles.contains(fileIndex) else { return }  // a stale source (previous episode)
        await movePlayhead(to: offset)
    }

    /// Forgets all deadlines on the engine side too (stop / teardown).
    public func clearAll() async {
        appliedDeadlines.removeAll()
        try? await session.clearAllPieceDeadlines(torrent)
    }

    // MARK: Apply

    private func requestApply() async {
        if applying {
            dirty = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        applying = true
        repeat {
            dirty = false
            await applyOnce()
        } while dirty
        applying = false
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }

    private func applyOnce() async {
        replanCount += 1
        var wanted: [Int: Int] = [:]
        for d in plan.replan(playhead: playhead, have: have) {
            wanted[d.piece] = min(wanted[d.piece] ?? .max, d.deadlineMs)
        }
        var toSet: [(piece: Int, ms: Int)] = []
        for (piece, ms) in wanted where appliedDeadlines[piece] != ms { toSet.append((piece, ms)) }
        toSet.sort { $0.ms < $1.ms }  // most urgent first
        let toClear = appliedDeadlines.keys.filter { wanted[$0] == nil && !have.contains($0) }

        // Record intent before the first suspension so a concurrent markHave sees a consistent map.
        appliedDeadlines = wanted
        deadlineClearCount += toClear.count
        try? await session.clearPieceDeadlines(torrent, pieces: toClear)
        deadlineSetCount += toSet.count
        try? await session.setPieceDeadlines(torrent, toSet.map { ($0.piece, .milliseconds($0.ms)) })
    }
}
