import Foundation

/// One-shot import of credentials that builds predating `FileSecretStore` left in the Keychain.
///
/// Why one-shot rather than a read-through fallback: Keychain items are ACL-bound to the signing
/// identity, so every ad-hoc-signed rebuild hits a fresh ACL and the system raises an "allow
/// access?" prompt — on launch, before the user has asked for anything. Consulting the Keychain
/// exactly once, over an explicit list of accounts Marquee knows it needs, is what keeps an
/// existing user's TMDB key and indexer keys without the prompt ever coming back. The completion
/// flag is recorded even when the sweep fails, so a Keychain that refuses to answer costs one
/// launch rather than one prompt per launch.
public enum KeychainSecretMigration {
    /// `UserDefaults` key recording that the sweep already ran on this machine.
    public static let defaultsKey = "MarqueeMigratedKeychainSecrets"

    public enum Outcome: Equatable, Sendable {
        /// The sweep already ran; `legacy` was never consulted.
        case alreadyRun
        /// Copied `count` credentials into the store.
        case imported(count: Int)
        /// The Keychain held nothing for these accounts (the usual case on a fresh install).
        case nothingFound
        /// The Keychain would not answer without UI; `message` says why.
        case unreadable(message: String)
    }

    /// Copies every credential the Keychain still holds for `accounts` into `store`, then marks
    /// the migration complete.
    ///
    /// Accounts already answered by `store` are skipped, so a user who has re-entered a key is
    /// never prompted for it. `isComplete` / `markComplete` are injected rather than reading
    /// `UserDefaults` directly so the gate is testable. The Keychain store is the only place the
    /// app builds one, and only for the duration of this call.
    @discardableResult
    public static func migrateIfNeeded(
        accounts: [String],
        into store: any SecretStore,
        isComplete: () -> Bool,
        markComplete: () -> Void,
        legacy: any SecretStore = KeychainSecretStore()
    ) -> Outcome {
        guard !isComplete() else { return .alreadyRun }
        var imported = 0
        var failure: String?
        // Blank account names are real (a built-in provider with no credential) and must never
        // cost a Keychain probe.
        for raw in accounts {
            let account = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty else { continue }
            do {
                guard try store.get(account: account) == nil,
                    let secret = try legacy.get(account: account), !secret.isEmpty
                else { continue }
                try store.set(secret, account: account)
                imported += 1
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        // Recorded either way: a Keychain we can't read must not be asked again on every launch.
        markComplete()
        if let failure { return .unreadable(message: failure) }
        return imported > 0 ? .imported(count: imported) : .nothingFound
    }
}