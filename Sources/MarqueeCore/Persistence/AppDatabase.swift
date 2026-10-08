import Foundation
import GRDB

/// The app's SQLite database: a WAL `DatabasePool` on disk, an in-memory `DatabaseQueue` in tests.
/// Shared between the app and (later) the helper process; repositories take an `AppDatabase`.
public final class AppDatabase: Sendable {
    /// The underlying GRDB writer (also usable as a reader).
    public let writer: any DatabaseWriter

    /// Wraps `writer` and runs all pending migrations.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.makeMigrator().migrate(writer)
    }

    /// Opens (creating if needed) a WAL database at `url`.
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path, configuration: makeConfiguration()))
    }

    /// A throwaway in-memory database (tests, previews).
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    /// `~/Library/Application Support/Marquee/marquee.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Marquee", directoryHint: .isDirectory)
            .appending(path: "marquee.sqlite", directoryHint: .notDirectory)
    }

    /// Opens the database at `defaultURL`.
    public static func openDefault() throws -> AppDatabase {
        try onDisk(at: defaultURL)
    }

    static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // The helper process shares the file; wait briefly instead of failing on a busy writer.
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        return config
    }

    /// Streams the result of `fetch`, re-delivering whenever the tables it reads change.
    /// Keeps only the newest undelivered value; the stream ends if the query fails.
    func observe<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncStream<T> {
        let writer = self.writer
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in ValueObservation.tracking(fetch).values(in: writer) {
                        continuation.yield(value)
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
