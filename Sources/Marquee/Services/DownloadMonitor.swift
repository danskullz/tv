import Foundation
import MarqueeCore
import MarqueeUI
import TorrentEngine

/// Tracks the torrents Marquee started (for the "Downloading now" shelf, episode rings and Activity)
/// and mirrors them into the `torrent` table. Costs nothing while no torrent is registered; samples the
/// engine only when something on screen asks for live progress.
actor DownloadMonitor {
    struct Entry: Sendable {
        var id: TorrentID
        var titleID: UUID
        var label: String
        var releaseName: String
        /// Progress-ring ids of the episodes this torrent is being played for (the title id for movies).
        var progressIDs: [String]
        var startedAt: Date
        var isStreamOnly: Bool
    }

    private let session: @Sendable () -> TorrentSession?
    private let torrents: any TorrentRepository
    private var entries: [String: Entry] = [:]
    private var lastWrite: [String: Date] = [:]

    init(session: @escaping @Sendable () -> TorrentSession?, torrents: any TorrentRepository) {
        self.session = session
        self.torrents = torrents
    }

    func register(_ entry: Entry, savePath: String) async {
        entries[entry.id.hex] = entry
        try? await torrents.upsert(Torrent(
            infoHash: entry.id.hex, name: entry.releaseName, state: .downloading, savePath: savePath,
            titleId: entry.titleID, isStreaming: true, keepAfterStream: !entry.isStreamOnly))
    }

    func unregister(_ id: TorrentID) {
        entries[id.hex] = nil
    }

    var active: [Entry] { Array(entries.values).sorted { $0.startedAt < $1.startedAt } }

    func isActive(titleID: UUID) -> Bool { entries.values.contains { $0.titleID == titleID } }

    struct Sample: Sendable {
        var entry: Entry
        var status: TorrentStatus
    }

    /// Current engine status of everything registered; finished torrents leave the active set.
    func sample() async -> [Sample] {
        guard let session = session() else { return [] }
        var out: [Sample] = []
        for entry in entries.values {
            guard let status = try? await session.status(entry.id) else { continue }
            out.append(Sample(entry: entry, status: status))
            let done = status.state == .seeding || status.state == .finished || status.progress >= 0.999
            let now = Date()
            if done || now.timeIntervalSince(lastWrite[entry.id.hex] ?? .distantPast) > 5 {
                lastWrite[entry.id.hex] = now
                try? await torrents.updateProgress(
                    infoHash: entry.id.hex, progress: status.progress, state: done ? .finished : .downloading,
                    lastError: nil)
            }
            if done { entries[entry.id.hex] = nil }
        }
        return out
    }

    /// Live progress for the UI: one update per title/episode id.
    func progressUpdates() async -> [ProgressUpdate] {
        var updates: [ProgressUpdate] = []
        for s in await sample() {
            let remaining = max(0, s.status.totalWanted - s.status.totalWantedDone)
            let rate = Double(s.status.downloadRate)
            let eta = rate > 1000 ? Double(remaining) / rate : nil
            for id in [s.entry.titleID.uuidString] + s.entry.progressIDs {
                updates.append(ProgressUpdate(id: id, fraction: s.status.progress, etaSeconds: eta, bytesPerSecond: rate))
            }
        }
        return updates
    }
}
