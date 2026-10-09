import Foundation
import MarqueeCore
import TorrentEngine

/// Converts a finished managed torrent into importer inputs, mapping episode files by their paths.
public struct ManagedDownloadImportSink: DownloadCompletionSink {
    public typealias MetadataProvider = @Sendable (TorrentID) async throws -> TorrentMetadata

    private let metadataProvider: MetadataProvider
    private let importer: ImportCoordinator
    private let library: any LibraryRepository

    public init(
        session: TorrentSession, importer: ImportCoordinator, library: any LibraryRepository
    ) {
        metadataProvider = { try await session.metadata($0) }
        self.importer = importer
        self.library = library
    }

    public init(
        metadataProvider: @escaping MetadataProvider, importer: ImportCoordinator,
        library: any LibraryRepository
    ) {
        self.metadataProvider = metadataProvider
        self.importer = importer
        self.library = library
    }

    public func completed(_ download: DownloadCompletion) async throws -> Bool {
        guard let titleID = download.titleId, let title = try await library.title(id: titleID), title.deletedAt == nil else {
            return false
        }
        let metadata = try await metadataProvider(TorrentID(hex: download.infoHash))
        let episodes = title.kind == .series ? try await library.episodes(titleId: titleID) : []
        let selectedFiles = metadata.files.filter { $0.priority > 0 }
        let mediaCount = selectedFiles.filter { Self.isVideo($0.path) }.count
        let files = selectedFiles.map { file in
            CompletedFile(
                path: file.path, fileIndex: file.index, size: file.size,
                target: Self.target(
                    path: file.path, title: title, episodes: episodes, mediaFileCount: mediaCount,
                    requestedEpisodeIDs: download.episodeIds))
        }
        let event = CompletedDownload(
            infoHash: download.infoHash, savePath: download.savePath, releaseName: download.releaseName,
            grabID: download.grabId, files: files)
        let results = try await importer.process(event)
        let accepted = results.contains { if case .imported = $0 { true } else { false } }
        let retryOfImport = results.contains {
            if case .skipped(_, let reason) = $0 { reason.contains("already imported") } else { false }
        }
        let failed = results.contains { if case .failed = $0 { true } else { false } }
        return accepted || (retryOfImport && !failed)
    }

    static func target(
        path: String, title: Title, episodes: [Episode], mediaFileCount: Int,
        requestedEpisodeIDs: [UUID]
    ) -> ImportTarget {
        guard title.kind == .series else { return .movie(titleID: title.id) }
        let parsed = ReleaseParser.parseFileName(path)
        var matched: [UUID] = []
        if parsed.seasons.count == 1, let season = parsed.seasons.first, !parsed.episodes.isEmpty {
            let numbers = Set(parsed.episodes)
            matched = episodes.filter { $0.seasonNumber == season && numbers.contains($0.episodeNumber) }.map(\.id)
        } else if !parsed.absoluteEpisodes.isEmpty {
            let numbers = Set(parsed.absoluteEpisodes)
            matched = episodes.compactMap { episode in
                episode.absoluteNumber.flatMap { numbers.contains($0) ? episode.id : nil }
            }
        } else if let airDate = parsed.airDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            matched = episodes.filter { episode in
                guard let date = episode.airDate else { return false }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return parts.year == airDate.year && parts.month == airDate.month && parts.day == airDate.day
            }.map(\.id)
        }
        if !matched.isEmpty { return .episodeIDs(matched) }
        if mediaFileCount == 1, !requestedEpisodeIDs.isEmpty { return .episodeIDs(requestedEpisodeIDs) }
        return .unmapped
    }

    private static func isVideo(_ path: String) -> Bool {
        FileSafety.videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
