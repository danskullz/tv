import Foundation
import Synchronization
import Testing

@testable import MarqueeCore

/// A legacy store that records every read, so a test can assert the Keychain is left alone.
private final class SpyLegacyStore: SecretStore, Sendable {
    private let storage: Mutex<[String: String]>
    private let reads: Mutex<[String]>
    private let failure: SecretStoreError?

    var readAccounts: [String] { reads.withLock { $0 } }

    init(_ initial: [String: String] = [:], failingWith error: SecretStoreError? = nil) {
        storage = Mutex(initial)
        reads = Mutex([])
        failure = error
    }

    func get(account: String) throws -> String? {
        reads.withLock { $0.append(account) }
        if let failure { throw failure }
        return storage.withLock { $0[account] }
    }

    func set(_ secret: String, account: String) throws { storage.withLock { $0[account] = secret } }
    func delete(account: String) throws { storage.withLock { _ = $0.removeValue(forKey: account) } }
}

/// Stands in for the `UserDefaults` flag: `false` until the first sweep completes.
private final class SpyMigrationMarker {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}

private func migrationTempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("marquee-migration-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("secrets.json")
}

private func runMigration(
    _ marker: SpyMigrationMarker, _ accounts: [String], into store: any SecretStore, legacy: any SecretStore
) -> KeychainSecretMigration.Outcome {
    KeychainSecretMigration.migrateIfNeeded(
        accounts: accounts, into: store,
        isComplete: { marker.isComplete }, markComplete: { marker.markComplete() }, legacy: legacy)
}

@Suite struct KeychainSecretMigrationTests {
    @Test func importsEveryLegacyCredentialIntoTheFile() throws {
        let file = migrationTempFile()
        let store = FileSecretStore(file: file)
        let legacy = SpyLegacyStore(["tmdb.credential": "tmdb-key", "indexer.abc.apikey": "prowlarr-key"])

        let outcome = runMigration(
            SpyMigrationMarker(),
            ["tmdb.credential", "indexer.abc.apikey", "indexer.gone.apikey"], into: store, legacy: legacy)

        #expect(outcome == .imported(count: 2))
        // Written back, so a later launch needs no Keychain at all.
        #expect(try FileSecretStore(file: file).get(account: "tmdb.credential") == "tmdb-key")
        #expect(try FileSecretStore(file: file).get(account: "indexer.abc.apikey") == "prowlarr-key")
    }

    @Test func runsOnceAndNeverReadsTheKeychainAgain() throws {
        let store = FileSecretStore(file: migrationTempFile())
        let legacy = SpyLegacyStore(["tmdb.credential": "old"])
        let marker = SpyMigrationMarker()
        let accounts = ["tmdb.credential"]

        #expect(runMigration(marker, accounts, into: store, legacy: legacy) == .imported(count: 1))
        #expect(legacy.readAccounts == ["tmdb.credential"])

        // Steady state: every later launch short-circuits before touching the Keychain.
        #expect(runMigration(marker, accounts, into: store, legacy: legacy) == .alreadyRun)
        #expect(legacy.readAccounts == ["tmdb.credential"])
    }

    @Test func neverOverwritesAKeyTheUserAlreadyReEntered() throws {
        let file = migrationTempFile()
        let store = FileSecretStore(file: file)
        try store.set("typed-by-hand", account: "tmdb.credential")
        let legacy = SpyLegacyStore(["tmdb.credential": "stale-keychain-key"])

        let outcome = runMigration(SpyMigrationMarker(), ["tmdb.credential"], into: store, legacy: legacy)

        // The file already had it, so the Keychain was never even asked.
        #expect(outcome == .nothingFound)
        #expect(legacy.readAccounts.isEmpty)
        #expect(try FileSecretStore(file: file).get(account: "tmdb.credential") == "typed-by-hand")
    }

    @Test func aFreshInstallAsksTheKeychainOnceAndFindsNothing() throws {
        let store = FileSecretStore(file: migrationTempFile())
        let legacy = SpyLegacyStore()
        let accounts = ["tmdb.credential", "indexer.abc.apikey"]

        #expect(runMigration(SpyMigrationMarker(), accounts, into: store, legacy: legacy) == .nothingFound)
        #expect(legacy.readAccounts == accounts)
    }

    @Test func anUnreadableKeychainIsReportedButStillRetiresTheSweep() throws {
        let store = FileSecretStore(file: migrationTempFile())
        let legacy = SpyLegacyStore(failingWith: .keychain(status: -25308))
        let marker = SpyMigrationMarker()

        let outcome = runMigration(marker, ["tmdb.credential"], into: store, legacy: legacy)

        guard case .unreadable(let message) = outcome else {
            Issue.record("expected .unreadable, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        // Marked complete anyway: a Keychain we can't read must not prompt on every launch.
        #expect(runMigration(marker, ["tmdb.credential"], into: store, legacy: legacy) == .alreadyRun)
        #expect(legacy.readAccounts == ["tmdb.credential"])
    }

    @Test func blankAccountNamesAreSkipped() throws {
        let store = FileSecretStore(file: migrationTempFile())
        let legacy = SpyLegacyStore()

        #expect(runMigration(SpyMigrationMarker(), ["", "   "], into: store, legacy: legacy) == .nothingFound)
        #expect(legacy.readAccounts.isEmpty)
    }

    /// The app's steady state: the default file store carries no read-through source at all, so
    /// there is no code path on which an ordinary launch can reach the Keychain.
    @Test func theDefaultFileStoreAnswersFromDiskAlone() throws {
        let file = migrationTempFile()
        try FileSecretStore(file: file).set("on-disk", account: "tmdb.credential")
        let store = FileSecretStore(file: file)
        #expect(store.fallback == nil)
        #expect(try store.get(account: "tmdb.credential") == "on-disk")
        #expect(try store.get(account: "indexer.absent.apikey") == nil)
    }
}