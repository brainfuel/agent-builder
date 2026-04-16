import Foundation
import Security

struct KeychainStore {
    let service: String

    private struct CacheKey: Hashable {
        let service: String
        let account: String
    }

    private enum CacheEntry {
        case value(String)
        case missing
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: CacheEntry] = [:]

    init(service: String) {
        self.service = service
    }

    func string(for account: String) throws -> String? {
        let cacheKey = CacheKey(service: service, account: account)
        if let cached = Self.cachedEntry(for: cacheKey) {
            switch cached {
            case .value(let value):
                return value
            case .missing:
                return nil
            }
        }

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.unexpectedData
            }
            Self.storeCache(entry: .value(value), for: cacheKey)
            return value
        case errSecItemNotFound:
            Self.storeCache(entry: .missing, for: cacheKey)
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status, operation: "read")
        }
    }

    func setString(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let cacheKey = CacheKey(service: service, account: account)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let attributesToUpdate = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(updateStatus, operation: "update")
            }
            Self.storeCache(entry: .value(value), for: cacheKey)
            return
        }

        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus, operation: "add")
        }
        Self.storeCache(entry: .value(value), for: cacheKey)
    }

    func removeValue(for account: String) throws {
        let cacheKey = CacheKey(service: service, account: account)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status, operation: "delete")
        }
        Self.storeCache(entry: .missing, for: cacheKey)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func cachedEntry(for key: CacheKey) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func storeCache(entry: CacheEntry, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = entry
    }
}

enum KeychainStoreError: LocalizedError {
    case unexpectedData
    case unexpectedStatus(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "Keychain data had an unexpected format."
        case .unexpectedStatus(let status, let operation):
            if status == errSecMissingEntitlement {
                return "Keychain \(operation) failed (\(status)): missing entitlement. In Xcode, enable Signing for this target and add the Keychain Sharing capability."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain \(operation) failed (\(status)): \(message)"
        }
    }
}
