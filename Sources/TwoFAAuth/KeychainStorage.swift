// The whole account list is one generic-password item in the login Keychain, on this Mac only.
import Foundation
import Security
import TwoFACore

struct KeychainStorage: SecretStorage {
    private let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.twofa-auth",
        kSecAttrAccount as String: "accounts",
    ]

    func load() throws -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OtpError("Không đọc được Keychain (mã lỗi \(status))") }
        return result as? Data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "2FA Auth – tài khoản"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw OtpError("Không lưu được vào Keychain (mã lỗi \(added))") }
        } else if status != errSecSuccess {
            throw OtpError("Không lưu được vào Keychain (mã lỗi \(status))")
        }
    }
}
