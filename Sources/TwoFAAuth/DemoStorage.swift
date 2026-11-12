// Made-up accounts with random keys for `--demo`; kept in memory only.
import Foundation
import TwoFACore

final class DemoStorage: SecretStorage {
    private let memory = InMemoryStorage()

    init() {
        let book = try! AccountBook(storage: memory)
        let samples: [(String, String, String)] = [
            ("GitHub", "alex@example.com", "Công việc"), ("Google", "alex@example.com", "Cá nhân"),
            ("Binance", "alex.trader", "Tài chính"), ("AWS", "root@example.com", "Công việc"),
            ("Zalo", "0901 234 567", "Cá nhân"), ("Okta", "alex@corp.example", "Công việc"),
        ]
        for (issuer, name, group) in samples {
            let key = (0..<20).map { _ in UInt8.random(in: 0...255) }
            _ = try? book.add(AccountDraft(issuer: issuer, name: name, group: group, secret: Self.base32(key)))
        }
    }

    func load() throws -> Data? { try memory.load() }
    func save(_ data: Data) throws { try memory.save(data) }

    private static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", value = 0, bits = 0
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(value >> bits) & 31]) }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }
}
