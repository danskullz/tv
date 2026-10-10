import Foundation
import Synchronization

/// File-backed secrets for ad-hoc and local builds.
///
/// Keychain items are ACL-bound to the signing identity, so every rebuild or reinstall with a
/// fresh ad-hoc signature silently loses them and the user has to sign in again. This store
/// keeps the same `SecretStore` interface in one JSON file under Application Support with
/// owner-only permissions, so keys survive rebuilds. File-protection-wise it is weaker than the
/// Keychain (anything running as the user can read it); the file holds nothing but opaque
/// credential strings, and secrets still never appear in logs or settings (see
/// `SecretRedactor`).
public final class FileSecretStore: SecretStore, Sendable {
    /// `~/Library/Application Support/Marquee/secrets.json`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Marquee", directoryHint: .isDirectory)
            .appending(path: "secrets.json", directoryHint: .notDirectory)
    }

    private let file: URL
    private let storage: Mutex<[String: String]>
    /// Read-through source consulted on a miss, with hits written back to the file. The app does
    /// not use this for the Keychain — a miss here must never cost the user a Keychain prompt, so
    /// the one-shot `KeychainSecretMigration` imports legacy credentials up front instead.
    /// Internal rather than private so tests can assert the launch path carries no read-through
    /// source.
    let fallback: (any SecretStore)?

    public init(file: URL = FileSecretStore.defaultURL, fallback: (any SecretStore)? = nil) {
        self.file = file
        self.fallback = fallback
        self.storage = Mutex(Self.load(from: file))
    }

    public func get(account: String) throws -> String? {
        if let hit = storage.withLock({ $0[account] }) { return hit }
        guard let migrated = try fallback?.get(account: account), !migrated.isEmpty else { return nil }
        storage.withLock { $0[account] = migrated }
        try? persist()
        return migrated
    }

    public func set(_ secret: String, account: String) throws {
        storage.withLock { $0[account] = secret }
        try persist()
    }

    public func delete(account: String) throws {
        storage.withLock { _ = $0.removeValue(forKey: account) }
        try persist()
    }

    // MARK: - Private

    private static func load(from file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist() throws {
        let data = try storage.withLock { try JSONEncoder().encode($0) }
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw SecretStoreError.fileError
        }
    }
}
