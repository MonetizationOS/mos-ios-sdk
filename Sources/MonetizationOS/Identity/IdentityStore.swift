import Foundation
import os
import Security

/// Persists the SDK's identity state as opaque string values under keys the SDK chooses. Store and return them
/// unchanged. Implementations swallow their own failures: identity persistence is best effort and never fatal.
/// `MOS` reads a new anonymous id back and keeps it in memory if the store does not return it.
public protocol IdentityStore: Sendable {
    func value(forKey key: String) -> String?
    /// nil removes the value.
    func setValue(_ value: String?, forKey key: String)
}

/// The keys `MOS` stores identity state under, which are also the default store's Keychain accounts.
enum IdentityStoreKey {
    /// The anonymous identifier.
    static let anonymousIdentifier = "anonymousIdentifier"
    /// The identity key of the last call, so an identity change across an app kill still purges.
    static let lastIdentityKey = "lastIdentityKey"
    /// The anonymous id still waiting to ride a decision as `previousAnonymousIdentifier`.
    static let pendingPreviousAnonymousIdentifier = "pendingPreviousAnonymousIdentifier"
}

/// Keeps the identity state in memory only, for tests and previews.
public final class InMemoryIdentityStore: IdentityStore {
    private let values: OSAllocatedUnfairLock<[String: String]>

    public init(_ values: [String: String] = [:]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    public func value(forKey key: String) -> String? { values.withLock { $0[key] } }
    public func setValue(_ value: String?, forKey key: String) { values.withLock { $0[key] = value } }
}

/// The default store: Keychain generic passwords, so the anonymous id survives a reinstall
/// and meters do not reset with it.
public struct KeychainIdentityStore: IdentityStore {
    let service: String

    /// The items for `publicKey`'s environment, as `MOS` uses by default: a staging and a production key never
    /// share an anonymous id. On macOS they are scoped by the bundle identifier too.
    public init(publicKey: String) {
        service = Self.service(environment: MOSStorage.environment(publicKey: publicKey), appScope: MOSStorage.appScope)
    }

    /// `com.monetizationos.sdk.<environment>`; on macOS `com.monetizationos.sdk.<bundle id>.<environment>`.
    static func service(environment: String, appScope: String?) -> String {
        [MOSStorage.name, appScope, MOSStorage.segment(environment)].compactMap { $0 }.joined(separator: ".")
    }

    /// Each key is a Keychain account.
    public func value(forKey key: String) -> String? { read(key) }

    public func setValue(_ value: String?, forKey key: String) {
        if let value { write(value, key) } else { delete(key) }
    }

    private func read(_ account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    private func write(_ value: String, _ account: String) {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    private func delete(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
