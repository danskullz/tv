import Foundation
import GRDB
import Testing

@testable import MarqueeCore

/// Normalized dump of the schema (tables, indexes, triggers, FTS shadow tables), excluding GRDB bookkeeping.
private func schemaSQL(_ db: Database) throws -> String {
    try String.fetchAll(
        db,
        sql: """
            SELECT sql FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            ORDER BY type, name
            """
    ).joined(separator: ";\n\n") + ";\n"
}

@Suite struct PersistenceSchemaTests {
    @Test func migratesFromEmpty() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            let tables = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            for expected in [
                "title", "season", "episode", "mediaFile", "mediaFileEpisode", "release", "grab",
                "torrent", "streamSession", "indexer", "qualityProfile", "customFormat",
                "delayProfile", "rootFolder", "subtitleTrack", "watchState", "historyEvent",
                "blocklistEntry", "healthIssue", "tag", "titleTag", "indexerTag", "packFileMapping",
                "titleSearch",
            ] {
                #expect(tables.contains(expected), "missing table \(expected)")
            }
            #expect(try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") == true)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func migrationIsIdempotent() throws {
        let database = try AppDatabase.inMemory()
        try Schema.makeMigrator().migrate(database.writer)
        try database.writer.read { db in
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(applied == Schema.migrationIdentifiers)
        }
    }

    @Test func qualityGroupsSurviveV2MigrationAndRoundTrip() throws {
        let queue = try DatabaseQueue()
        try Schema.makeMigrator().migrate(queue, upTo: "v1")
        let now = Date()
        let id = UUID()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO qualityProfile (id, name, items, upgradeAllowed, minFormatScore, cutoffFormatScore, formatScores, createdAt, updatedAt) VALUES (?, ?, ?, 1, 0, 0, '{}', ?, ?)",
                arguments: [id, "Balanced", #"[{"quality":"webDL1080p","allowed":true}]"#, now, now])
        }
        try Schema.makeMigrator().migrate(queue)

        let profile = try queue.read { try QualityProfile.fetchOne($0, key: id) }
        #expect(QualityProfileConfig(record: try #require(profile)).groups.count == 1)

        let original = QualityProfileConfig(
            name: "Grouped", groups: [
                QualityGroup(name: "WEB", tiers: [.webDL1080p, .webRip1080p]),
                QualityGroup(name: "Blu-ray", tiers: [.bluray1080p], allowed: false),
            ], cutoff: .webDL1080p, sizePreference: .larger)
        try queue.write { db in try original.record().save(db) }
        let loaded = try queue.read { try QualityProfile.fetchOne($0, key: original.id) }
        #expect(try #require(loaded).groups == original.groups)
        #expect(QualityProfileConfig(record: try #require(loaded)).groups == original.groups)
    }

    /// Released migrations must never change: append a new migration instead of editing v1.
    @Test func v1SchemaMatchesSnapshot() throws {
        let queue = try DatabaseQueue()
        try Schema.makeMigrator().migrate(queue, upTo: "v1")
        let actual = try queue.read(schemaSQL)

        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "v1.schema", withExtension: "sql", subdirectory: "Fixtures/Persistence"))
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        #expect(actual == expected, "v1 schema changed. Add a new migration instead of editing v1.")
    }

    @Test func v3SchemaMatchesSnapshot() throws {
        let queue = try DatabaseQueue()
        try Schema.makeMigrator().migrate(queue)
        let actual = try queue.read(schemaSQL)
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "v3.schema", withExtension: "sql", subdirectory: "Fixtures/Persistence"))
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        #expect(actual == expected, "v3 schema changed. Add a new migration instead of editing existing migrations.")
    }

    @Test func migrationIdentifiersAreAppendOnly() {
        let released = ["v1"]
        let current = Schema.makeMigrator().migrations
        #expect(Array(current.prefix(released.count)) == released)
        #expect(current == Schema.migrationIdentifiers)
    }

    @Test func onDiskUsesWALAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "marquee-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nested/marquee.sqlite")
        let id = UUID()
        do {
            let database = try AppDatabase.onDisk(at: url)
            try database.writer.write { db in
                #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
                #expect(try Int.fetchOne(db, sql: "PRAGMA synchronous") == 1)
                try Tag(id: id, label: "kept").insert(db)
            }
        }
        let reopened = try AppDatabase.onDisk(at: url)
        let tag = try reopened.writer.read { try Tag.fetchOne($0, key: id) }
        #expect(tag?.label == "kept")
    }

    @Test func defaultURLIsInApplicationSupport() {
        #expect(AppDatabase.defaultURL.path.hasSuffix("Application Support/Marquee/marquee.sqlite"))
    }
}

/// Regenerates schema snapshots: `MARQUEE_UPDATE_FIXTURES=1 swift test --filter persistenceRegenerateV1Snapshot`.
/// Only do this for a deliberate, unreleased migration; v1 remains frozen.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MARQUEE_UPDATE_FIXTURES"] != nil))
func persistenceRegenerateV1Snapshot() throws {
    let queue = try DatabaseQueue()
    try Schema.makeMigrator().migrate(queue, upTo: "v1")
    let sql = try queue.read(schemaSQL)
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/Persistence/v1.schema.sql")
    try sql.write(to: url, atomically: true, encoding: .utf8)

    let currentQueue = try DatabaseQueue()
    try Schema.makeMigrator().migrate(currentQueue)
    let currentSQL = try currentQueue.read(schemaSQL)
    let currentURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/Persistence/v3.schema.sql")
    try currentSQL.write(to: currentURL, atomically: true, encoding: .utf8)
}
