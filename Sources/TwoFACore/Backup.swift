// Password-protected backup files. The account list (keys included) is sealed with AES-256-GCM under a key
// derived from the password with PBKDF2-HMAC-SHA256 and a fresh random salt, so the file is safe to keep in
// iCloud Drive or on a USB stick. Never log the password, the derived key or the decrypted contents.
import CommonCrypto
import CryptoKit
import Foundation

public enum Backup {
    public static let format = "2fa-auth-backup"
    public static let defaultIterations = 600_000
    public static let minPasswordLength = 8

    private struct File: Codable {
        var format = Backup.format
        var version = 1
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: String // base64
        var data: String // base64 of AES-GCM nonce + ciphertext + tag
    }

    /// What is sealed inside a backup file.
    private struct Payload: Codable {
        var format = "2fa-auth"
        var version = 1
        var accounts: [Account]
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(File.self, from: data))?.format == format
    }

    public static func encrypt(_ accounts: [Account], password: String, iterations: Int = defaultIterations) throws -> Data {
        guard password.count >= minPasswordLength else { throw OtpError(L("The password needs at least %ld characters", minPasswordLength)) }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw OtpError(L("Could not create the backup file")) }
        let key = try deriveKey(password, salt: salt, iterations: iterations)
        let plain = try JSONEncoder().encode(Payload(accounts: accounts))
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw OtpError(L("Could not create the backup file")) }
        let file = File(iterations: iterations, salt: salt.base64EncodedString(), data: sealed.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public static func decrypt(_ data: Data, password: String) throws -> [AccountDraft] {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == format,
              let salt = Data(base64Encoded: file.salt), let sealed = Data(base64Encoded: file.data),
              file.iterations > 0 else {
            throw OtpError(L("This is not a 2FA Auth backup file"))
        }
        guard file.version == 1, file.kdf == "pbkdf2-sha256" else {
            throw OtpError(L("This backup was made by a newer 2FA Auth; update the app"))
        }
        let key = try deriveKey(password, salt: salt, iterations: file.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: plain) else {
            throw OtpError(L("Wrong password, or the backup file is damaged"))
        }
        return payload.accounts.map {
            AccountDraft(issuer: $0.issuer, name: $0.name, group: $0.group, secret: $0.secret,
                         digits: $0.digits, period: $0.period, algorithm: $0.algorithm, profile: $0.profile)
        }
    }

    private static func deriveKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passwordBytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count)
        }
        guard status == kCCSuccess else { throw OtpError(L("Could not derive a key from the password")) }
        defer { _ = key.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: key)
    }
}

// MARK: choosing what to restore

extension Backup {
    /// The profiles in a decrypted backup with their account counts, in the order they first appear.
    public static func profiles(in drafts: [AccountDraft]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for draft in drafts {
            if counts[draft.profile] == nil { order.append(draft.profile) }
            counts[draft.profile, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }
    }

    /// The accounts of the chosen profiles, each kept in its own profile, or all moved `into` one.
    public static func pick(_ drafts: [AccountDraft], profiles: Set<String>, into target: String?) -> [AccountDraft] {
        drafts.filter { profiles.contains($0.profile) }.map { draft in
            var draft = draft
            if let target { draft.profile = target }
            return draft
        }
    }
}
