import Foundation
import Testing

@testable import MarqueeCore

private func secretTempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("marquee-secrets-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("secrets.json")
}

private func secretFilePermissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

@Suite struct FileSecretStoreTests {
    @Test func roundTripsSecretsToDisk() async throws {
        let file = secretTempFile()
        let store = FileSecretStore(file: file)
        try store.set("key-1", account: "tmdb.credential")
        #expect(try store.get(account: "tmdb.credential") == "key-1")

        // A new instance over the same file sees the same secrets: keys survive restarts.
        let reopened = FileSecretStore(file: file)
        #expect(try reopened.get(account: "tmdb.credential") == "key-1")

        try reopened.delete(account: "tmdb.credential")
        #expect(try reopened.get(account: "tmdb.credential") == nil)
        #expect(try FileSecretStore(file: file).get(account: "tmdb.credential") == nil)
    }

    @Test func restrictsFilePermissions() async throws {
        let file = secretTempFile()
        let store = FileSecretStore(file: file)
        try store.set("key-1", account: "a")
        #expect(secretFilePermissions(file) == 0o600)
        #expect(secretFilePermissions(file.deletingLastPathComponent()) == 0o700)
    }

    @Test func missingOrCorruptFileReadsAsEmpty() async throws {
        #expect(try FileSecretStore(file: secretTempFile()).get(account: "a") == nil)
        let file = secretTempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json{".utf8).write(to: file)
        #expect(try FileSecretStore(file: file).get(account: "a") == nil)
    }

    @Test func migratesFallbackHitsIntoTheFile() async throws {
        let file = secretTempFile()
        let legacy = InMemorySecretStore(["indexer.abc.apikey": "old-key"])
        let store = FileSecretStore(file: file, fallback: legacy)
        #expect(try store.get(account: "indexer.abc.apikey") == "old-key")
        // Migrated: a store without the fallback still finds it.
        #expect(try FileSecretStore(file: file).get(account: "indexer.abc.apikey") == "old-key")
        #expect(try store.get(account: "missing") == nil)
    }
}
