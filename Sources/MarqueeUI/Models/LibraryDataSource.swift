import Foundation

/// The seam between the UI and whatever supplies data (mock, MarqueeCore + GRDB, Connect mode).
/// Every method returns view models; implementations own mapping from their storage types.
public protocol LibraryDataSource: Sendable {
    func homeShelves() async throws -> [ShelfModel]
    func library() async throws -> [PosterItem]
    func detail(for id: PosterItem.ID) async throws -> TitleDetail?
    func activity() async throws -> [ActivityItem]

    /// Live download progress. Consumed only while something is on screen that shows progress (see
    /// `DownloadTracker`); implementations must stop producing and finish when the consumer cancels.
    func liveProgress() -> AsyncStream<[ProgressUpdate]>
}
