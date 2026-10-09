import Foundation

// The contract between whatever finishes downloading (streaming sessions, the download manager, the
// RSS monitor) and the importer. Producers build a `CompletedDownload` and call
// `DownloadImporting.handle(_:)`; they never touch the library, naming or file transfers.

/// Where a completed file belongs in the library.
public enum ImportTarget: Sendable, Hashable {
    /// A movie in the library.
    case movie(titleID: UUID)
    /// Episodes of a series, by the series' own season/episode numbers (several for multi-episode files).
    case episodes(titleID: UUID, refs: [EpisodeRef])
    /// Library episode ids (what `PackFileMapping.episodeIds` holds); the title is read from the episodes.
    case episodeIDs([UUID])
    /// Extras, samples, files the mapper could not place. The importer skips them and never guesses.
    case unmapped
}

/// One finished file of a download.
public struct CompletedFile: Sendable, Hashable {
    /// Path of the file, relative to ``CompletedDownload/savePath`` (as the torrent lists it), or absolute.
    public var path: String
    /// Index in the torrent's file list, when known (diagnostics only).
    public var fileIndex: Int?
    /// Expected size in bytes. When set, the importer refuses a file whose size on disk differs.
    public var size: Int64?
    public var target: ImportTarget

    public init(path: String, fileIndex: Int? = nil, size: Int64? = nil, target: ImportTarget) {
        self.path = path
        self.fileIndex = fileIndex
        self.size = size
        self.target = target
    }
}

/// A download (or part of one) whose files are complete and verified on disk, ready to import.
///
/// Packs are imported per file: send one event as each file completes (`files` holding just that
/// file), and/or one when the torrent finishes (all files). The importer is idempotent per
/// `(infoHash, file path)`, so repeating a file is harmless.
public struct CompletedDownload: Sendable, Hashable {
    /// Torrent info hash (v1 hex, lowercase). Identifies the source for idempotency and history.
    public var infoHash: String
    /// Directory the torrent was saved into; relative file paths resolve against it.
    public var savePath: String
    /// Release name as grabbed (drives quality, release group and edition when the file name lacks them).
    public var releaseName: String
    /// The decision-log entry that produced this download, if any ("Why this release?").
    public var grabID: UUID?
    public var files: [CompletedFile]

    public init(
        infoHash: String, savePath: String, releaseName: String, grabID: UUID? = nil, files: [CompletedFile]
    ) {
        self.infoHash = infoHash.lowercased()
        self.savePath = savePath
        self.releaseName = releaseName
        self.grabID = grabID
        self.files = files
    }
}

/// Anything that takes completed downloads into the library (``ImportCoordinator``). Producers depend on
/// this protocol so they stay free of the importer's internals and are easy to test.
public protocol DownloadImporting: Sendable {
    /// Queues the download for import and returns immediately; files are processed one at a time in
    /// arrival order. Safe to call from any context and to repeat.
    func handle(_ event: CompletedDownload)
}
