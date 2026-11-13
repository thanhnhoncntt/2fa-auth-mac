// Made-up accounts with random keys for `--demo`; kept in memory only.
import Foundation
import TwoFACore

final class DemoStorage: SecretStorage {
    private let memory = InMemoryStorage()

    init() {
        let book = try! AccountBook(storage: memory)
        let samples: [(String, String, String)] = [
            ("GitHub", "alex@example.com", L("Work")), ("Google", "alex@example.com", L("Personal")),
            ("Binance", "alex.trader", L("Finance")), ("AWS", "root@example.com", L("Work")),
            ("Zalo", "0901 234 567", L("Personal")), ("Okta", "alex@corp.example", L("Work")),
        ]
        for (issuer, name, group) in samples { _ = try? book.add(Self.draft(issuer, name, group)) }
        // `--demo-profiles` adds two more profiles, to try the profile switcher.
        if CommandLine.arguments.contains("--demo-profiles") {
            _ = try? book.addProfile("Acme Corp")
            _ = try? book.addProfile("Client B")
            _ = try? book.add(Self.draft("Jira", "alex@acme.example", "", profile: "Acme Corp"))
            _ = try? book.add(Self.draft("Slack", "alex@acme.example", "", profile: "Acme Corp"))
            _ = try? book.add(Self.draft("Shopify", "admin@clientb.example", "", profile: "Client B"))
        }
    }

    private static func draft(_ issuer: String, _ name: String, _ group: String, profile: String = "") -> AccountDraft {
        let key = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        return AccountDraft(issuer: issuer, name: name, group: group, secret: Base32.encode(key), profile: profile)
    }

    func load() throws -> Data? { try memory.load() }
    func save(_ data: Data) throws { try memory.save(data) }
}
