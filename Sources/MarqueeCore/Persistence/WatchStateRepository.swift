import Foundation
import GRDB

public protocol WatchStateRepository: Sendable {
    /// State of one playable entity (movie title id or episode id).
    func state(for id: UUID) async throws -> WatchState?
    /// All states of a title's episodes (or its movie entry).
    func states(titleId: UUID) async throws -> [WatchState]
    /// Records playback progress; marks watched once `position / duration >= watchedThreshold`.
    func recordProgress(
        id: UUID, titleId: UUID, position: Double, duration: Double?, watchedThreshold: Double
    ) async throws
    func setWatched(id: UUID, titleId: UUID, watched: Bool) async throws
    /// Unwatched entries with progress, most recently played first.
    func continueWatching(limit: Int) async throws -> [WatchState]
    func observeStates(titleId: UUID) -> AsyncStream<[WatchState]>
}

public struct GRDBWatchStateRepository: WatchStateRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func state(for id: UUID) async throws -> WatchState? {
        try await database.writer.read { try WatchState.fetchOne($0, key: id) }
    }

    public func states(titleId: UUID) async throws -> [WatchState] {
        try await database.writer.read {
            try WatchState.filter(Column("titleId") == titleId).fetchAll($0)
        }
    }

    public func recordProgress(
        id: UUID, titleId: UUID, position: Double, duration: Double?, watchedThreshold: Double = 0.9
    ) async throws {
        try await database.writer.write { db in
            var state = try WatchState.fetchOne(db, key: id)
                ?? WatchState(id: id, titleId: titleId)
            state.positionSeconds = position
            state.durationSeconds = duration ?? state.durationSeconds
            if let d = state.durationSeconds, d > 0, position / d >= watchedThreshold {
                state.watched = true
            }
            state.updatedAt = Date()
            try state.save(db)
        }
    }

    public func setWatched(id: UUID, titleId: UUID, watched: Bool) async throws {
        try await database.writer.write { db in
            var state = try WatchState.fetchOne(db, key: id) ?? WatchState(id: id, titleId: titleId)
            state.watched = watched
            if !watched { state.positionSeconds = 0 }
            state.updatedAt = Date()
            try state.save(db)
        }
    }

    public func continueWatching(limit: Int) async throws -> [WatchState] {
        try await database.writer.read {
            try WatchState
                .filter(Column("watched") == false && Column("positionSeconds") > 0)
                .order(Column("updatedAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func observeStates(titleId: UUID) -> AsyncStream<[WatchState]> {
        database.observe { db in
            try WatchState.filter(Column("titleId") == titleId).fetchAll(db)
        }
    }
}
