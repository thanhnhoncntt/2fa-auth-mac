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

/// The account list and its profiles. Every change is written straight through to storage as one blob.
/// A profile is a separate list: the same key may be in two profiles, but only once in each.
public final class AccountBook {
    private struct File: Codable {
        var version = 1
        var accounts: [Account]
        /// Named profiles in the user's order; "" (the default profile) is never listed. Missing in older files.
        var profiles: [String]?
    }

    public private(set) var accounts: [Account]
    private var savedProfiles: [String]
    private let storage: SecretStorage

    public init(storage: SecretStorage) throws {
        self.storage = storage
        if let data = try storage.load() {
            guard let file = try? JSONDecoder().decode(File.self, from: data) else {
                throw OtpError(L("The account data in the Keychain is damaged"))
            }
            accounts = file.accounts
            savedProfiles = file.profiles ?? []
        } else {
            accounts = []
            savedProfiles = []
        }
    }

    /// The named profiles: the saved order, then any that only accounts mention (from a restored backup, say).
    public var profiles: [String] {
        var names = savedProfiles
        for account in accounts where !account.profile.isEmpty && !names.contains(account.profile) {
            names.append(account.profile)
        }
        return names
    }

    private func save(_ next: [Account], profiles: [String]? = nil) throws {
        let nextProfiles = profiles ?? savedProfiles
        try storage.save(try JSONEncoder().encode(File(accounts: next, profiles: nextProfiles)))
        accounts = next
        savedProfiles = nextProfiles
    }

    // MARK: profiles

    private func checkedProfileName(_ name: String, ignoring old: String? = nil) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { throw OtpError(L("Enter a profile name")) }
        if profiles.contains(where: { $0 != old && $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            throw OtpError(L("There is already a profile named %@", clean))
        }
        return clean
    }

    @discardableResult
    public func addProfile(_ name: String) throws -> String {
        let clean = try checkedProfileName(name)
        try save(accounts, profiles: profiles + [clean])
        return clean
    }

    /// Renames a named profile and moves its accounts along. The default profile's name lives in the app settings.
    public func renameProfile(_ old: String, to new: String) throws {
        guard !old.isEmpty, profiles.contains(old) else { throw OtpError(L("Profile not found")) }
        let clean = try checkedProfileName(new, ignoring: old)
        let next = accounts.map { account in
            var account = account
            if account.profile == old { account.profile = clean }
            return account
        }
        try save(next, profiles: profiles.map { $0 == old ? clean : $0 })
    }

    /// Only an empty profile can go, so no account is ever deleted by accident.
    public func removeProfile(_ name: String) throws {
        let count = accounts.filter { $0.profile == name }.count
        if count > 0 { throw OtpError(L("%@ still has %ld accounts. Move or delete them first.", name, count)) }
        try save(accounts, profiles: profiles.filter { $0 != name })
    }

    // MARK: accounts

    private static func cleanNames(_ issuer: String, _ name: String, _ group: String) throws -> (String, String, String) {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let clean = (trim(issuer), trim(name), trim(group))
        if clean.0.isEmpty && clean.1.isEmpty { throw OtpError(L("Enter an account name")) }
        return clean
    }

    private func checked(_ draft: AccountDraft, against list: [Account]) throws -> Account {
        let (issuer, name, group) = try Self.cleanNames(draft.issuer, draft.name, draft.group)
        let secret = try Base32.checkSecret(draft.secret)
        guard [6, 7, 8].contains(draft.digits), draft.period > 0 else {
            throw OtpError(L("Unsupported number of digits or period"))
        }
        let profile = draft.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if let twin = list.first(where: { $0.secret == secret && $0.profile == profile }) {
            throw OtpError(L("This key is already in the list: %@", twin.label))
        }
        return Account(issuer: issuer, name: name, group: group, secret: secret,
                       digits: draft.digits, period: draft.period, algorithm: draft.algorithm, profile: profile)
    }

    @discardableResult
    public func add(_ draft: AccountDraft) throws -> Account {
        let account = try checked(draft, against: accounts)
        try save(accounts + [account])
        return account
    }

    /// Renames an account; with `profile`, also moves it to that profile.
    public func update(_ id: UUID, issuer: String, name: String, group: String, profile: String? = nil) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw OtpError(L("Account not found")) }
        var next = accounts
        (next[index].issuer, next[index].name, next[index].group) = try Self.cleanNames(issuer, name, group)
        if let profile, profile != next[index].profile {
            if let twin = accounts.first(where: { $0.profile == profile && $0.secret == next[index].secret }) {
                throw OtpError(L("This key is already in %@: %@", profile, twin.label))
            }
            next[index].profile = profile
        }
        try save(next)
    }

    public func remove(_ id: UUID) throws {
        try save(accounts.filter { $0.id != id })
    }

    /// Adds every valid, new account in one write, each to its draft's profile; duplicates and broken entries are skipped.
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
