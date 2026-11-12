import Foundation

/// Where the account list is kept: the Keychain in the app, memory in tests.
public protocol SecretStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public final class InMemoryStorage: SecretStorage {
    private var data: Data?
    public init() {}
    public func load() throws -> Data? { data }
    public func save(_ data: Data) throws { self.data = data }
}

public struct ImportResult: Equatable, Sendable {
    public let added: Int
    public let skipped: Int
}

/// The account list. Every change is written straight through to storage as one blob.
public final class AccountBook {
    private struct File: Codable {
        var version = 1
        var accounts: [Account]
    }

    public private(set) var accounts: [Account]
    private let storage: SecretStorage

    public init(storage: SecretStorage) throws {
        self.storage = storage
        if let data = try storage.load() {
            guard let file = try? JSONDecoder().decode(File.self, from: data) else {
                throw OtpError("Dữ liệu tài khoản trong Keychain bị hỏng")
            }
            accounts = file.accounts
        } else {
            accounts = []
        }
    }

    private func save(_ next: [Account]) throws {
        try storage.save(try JSONEncoder().encode(File(accounts: next)))
        accounts = next
    }

    private static func cleanNames(_ issuer: String, _ name: String, _ group: String) throws -> (String, String, String) {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let clean = (trim(issuer), trim(name), trim(group))
        if clean.0.isEmpty && clean.1.isEmpty { throw OtpError("Nhập tên tài khoản") }
        return clean
    }

    private func checked(_ draft: AccountDraft, against list: [Account]) throws -> Account {
        let (issuer, name, group) = try Self.cleanNames(draft.issuer, draft.name, draft.group)
        let secret = try Base32.checkSecret(draft.secret)
        guard [6, 7, 8].contains(draft.digits), draft.period > 0 else {
            throw OtpError("Số chữ số hoặc chu kỳ chưa hỗ trợ")
        }
        if let twin = list.first(where: { $0.secret == secret }) {
            throw OtpError("Khóa này đã có trong danh sách: \(twin.label)")
        }
        return Account(issuer: issuer, name: name, group: group, secret: secret,
                       digits: draft.digits, period: draft.period, algorithm: draft.algorithm)
    }

    @discardableResult
    public func add(_ draft: AccountDraft) throws -> Account {
        let account = try checked(draft, against: accounts)
        try save(accounts + [account])
        return account
    }

    public func update(_ id: UUID, issuer: String, name: String, group: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw OtpError("Không tìm thấy tài khoản") }
        var next = accounts
        (next[index].issuer, next[index].name, next[index].group) = try Self.cleanNames(issuer, name, group)
        try save(next)
    }

    public func remove(_ id: UUID) throws {
        try save(accounts.filter { $0.id != id })
    }

    /// Adds every valid, new account in one write; duplicates and broken entries are skipped.
    public func importDrafts(_ drafts: [AccountDraft]) throws -> ImportResult {
        var next = accounts
        for draft in drafts {
            if let account = try? checked(draft, against: next) { next.append(account) }
        }
        let added = next.count - accounts.count
        if added > 0 { try save(next) }
        return ImportResult(added: added, skipped: drafts.count - added)
    }
}
