import Foundation
import Security

/// The token of the server in the Keychain: one generic-password item of this
/// app, readable after the first unlock and on this device only
/// (`docs/features/ios-app.md`, "Ownership"). The service is the bundle
/// identifier, so a product that changes its identifier keeps its own item.
enum Keychain {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "dev.helyx.app"
    }

    private static let account = "token"

    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
            let data = found as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// False when the Keychain refused the item, as it does for an app with
    /// no signature.
    static func save(_ token: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var added = item
        added.merge(attributes) { _, new in new }
        return SecItemAdd(added as CFDictionary, nil) == errSecSuccess
    }
}
