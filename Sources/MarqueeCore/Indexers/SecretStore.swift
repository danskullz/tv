import Foundation
import Security
import Synchronization

/// Storage for secrets (indexer API keys, passkeys). Secrets never live in model structs,
/// settings files or logs; they are looked up by an account string at request time.
public protocol SecretStore: Sendable {
    func get(account: String) throws -> String?
    func set(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(status: Int32)
    case invalidData
}

extension SecretStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let text = SecCopyErrorMessageString(OSStatus(status), nil) as String?
            return "Marquee couldn't access the Keychain (\(text ?? "error \(status)"))."
        case .invalidData:
            return "A saved secret in the Keychain couldn't be read."
        }
    }
}

/// Keychain-backed store using generic passwords scoped to a service name.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "com.danskullz.marquee"

    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status: status)
        }
    }

    public func set(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        default:
            throw SecretStoreError.keychain(status: update)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: status)
        }
    }
}

/// Volatile store for tests and previews.
public final class InMemorySecretStore: SecretStore, Sendable {
    private let storage: Mutex<[String: String]>

    public init(_ initial: [String: String] = [:]) {
        storage = Mutex(initial)
    }

    public func get(account: String) throws -> String? {
        storage.withLock { $0[account] }
    }

    public func set(_ secret: String, account: String) throws {
        storage.withLock { $0[account] = secret }
    }

    public func delete(account: String) throws {
        storage.withLock { _ = $0.removeValue(forKey: account) }
    }
}
