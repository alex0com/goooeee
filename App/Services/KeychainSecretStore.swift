import Foundation
import GoooeeeCore
import Security

/// API keys and MCP secrets in the login Keychain (generic passwords, service "goooeee").
///
/// Values are cached in memory so the Keychain is read once per secret. With ad-hoc signing
/// macOS may ask for access again after a rebuild; "Always Allow" stops that.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    init(service: String = "goooeee") {
        self.service = service
    }

    func secret(for ref: SecretRef) -> String? {
        if let cached = lock.withLock({ cache[ref.account] }) { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String? = (status == errSecSuccess) ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        lock.withLock { cache[ref.account] = .some(value) }
        return value
    }

    func setSecret(_ value: String?, for ref: SecretRef) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref.account,
        ]
        SecItemDelete(base as CFDictionary)
        lock.withLock { cache[ref.account] = .some(value?.isEmpty == false ? value : nil) }
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "goooeee: \(ref.account)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)",
            ])
        }
    }
}
