// Profiles: separate account lists. Keys here are random dummies, never real ones.
import XCTest
@testable import TwoFACore

private func randomKey() -> String { Base32.encode(Data((0..<20).map { _ in UInt8.random(in: 0...255) })) }

final class ProfileTests: XCTestCase {
    func testAccountsSavedBeforeProfilesLoadIntoTheDefaultProfile() throws {
        let storage = InMemoryStorage()
        let key = randomKey()
        let old = #"{"version":1,"accounts":[{"id":"6F1C2B9A-0000-4000-8000-000000000001","issuer":"GitHub","name":"alex","group":"","secret":"\#(key)","digits":6,"period":30,"algorithm":"SHA1"}]}"#
        try storage.save(Data(old.utf8))
        let book = try AccountBook(storage: storage)
        XCTAssertEqual(book.accounts.map(\.profile), [""])
        XCTAssertEqual(book.profiles, [])
    }

    func testProfilesAreCreatedRenamedAndRemovedOnlyWhenEmpty() throws {
        let storage = InMemoryStorage()
        let book = try AccountBook(storage: storage)
        XCTAssertEqual(try book.addProfile("  Company A "), "Company A")
        try book.addProfile("Client B")
        XCTAssertThrowsError(try book.addProfile("company a")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "There is already a profile named company a")
        }
        XCTAssertThrowsError(try book.addProfile("   ")) { XCTAssertEqual(($0 as? OtpError)?.message, "Enter a profile name") }
        XCTAssertEqual(book.profiles, ["Company A", "Client B"])

        let account = try book.add(AccountDraft(issuer: "GitHub", name: "alex", secret: randomKey(), profile: "Company A"))
        XCTAssertThrowsError(try book.removeProfile("Company A")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "Company A still has 1 accounts. Move or delete them first.")
        }
        try book.renameProfile("Company A", to: "Company Alpha")
        XCTAssertEqual(book.accounts.first?.profile, "Company Alpha")
        XCTAssertEqual(book.profiles, ["Company Alpha", "Client B"])
        try book.removeProfile("Client B")

        let reloaded = try AccountBook(storage: storage)
        XCTAssertEqual(reloaded.profiles, ["Company Alpha"], "profiles are saved with the accounts")
        XCTAssertEqual(reloaded.accounts.first?.id, account.id)
    }

    func testTheSameKeyMayBeInTwoProfilesButNotTwiceInOne() throws {
        let book = try AccountBook(storage: InMemoryStorage())
        try book.addProfile("Work")
        let key = randomKey()
        try book.add(AccountDraft(issuer: "GitHub", name: "alex", secret: key))
        try book.add(AccountDraft(issuer: "GitHub", name: "alex", secret: key, profile: "Work"))
        XCTAssertThrowsError(try book.add(AccountDraft(issuer: "Again", secret: key, profile: "Work")))
        let result = try book.importDrafts([AccountDraft(issuer: "x", secret: key, profile: "Work"),
                                            AccountDraft(issuer: "y", secret: randomKey(), profile: "Work")])
        XCTAssertEqual(result, ImportResult(added: 1, skipped: 1))
        XCTAssertEqual(book.accounts.filter { $0.profile == "Work" }.count, 2)
    }

    func testMovingAnAccountToAnotherProfile() throws {
        let book = try AccountBook(storage: InMemoryStorage())
        try book.addProfile("Work")
        let key = randomKey()
        let personal = try book.add(AccountDraft(issuer: "GitHub", secret: key))
        try book.add(AccountDraft(issuer: "GitHub", secret: key, profile: "Work"))
        let other = try book.add(AccountDraft(issuer: "Okta", secret: randomKey()))
        XCTAssertThrowsError(try book.update(personal.id, issuer: "GitHub", name: "", group: "", profile: "Work")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "This key is already in Work: GitHub")
        }
        try book.update(other.id, issuer: "Okta", name: "", group: "", profile: "Work")
        XCTAssertEqual(book.accounts.first { $0.id == other.id }?.profile, "Work")
    }

    func testImportingIntoAProfileAddsItToTheList() throws {
        let book = try AccountBook(storage: InMemoryStorage())
        _ = try book.importDrafts([AccountDraft(issuer: "x", secret: randomKey(), profile: "From Backup")])
        XCTAssertEqual(book.profiles, ["From Backup"])
    }

    func testBackupKeepsEachAccountsProfile() throws {
        let accounts = [Account(issuer: "A", secret: randomKey()), Account(issuer: "B", secret: randomKey(), profile: "Work")]
        let drafts = try Backup.decrypt(try Backup.encrypt(accounts, password: "correct horse", iterations: 1_000), password: "correct horse")
        XCTAssertEqual(drafts.map(\.profile), ["", "Work"])
    }

    func testRestoreListsTheProfilesInTheFileAndPicksSomeOfThem() {
        let drafts = [AccountDraft(issuer: "A", secret: randomKey()), AccountDraft(issuer: "B", secret: randomKey(), profile: "Work"),
                      AccountDraft(issuer: "C", secret: randomKey(), profile: "Work"), AccountDraft(issuer: "D", secret: randomKey(), profile: "Club")]
        XCTAssertEqual(Backup.profiles(in: drafts).map(\.name), ["", "Work", "Club"])
        XCTAssertEqual(Backup.profiles(in: drafts).map(\.count), [1, 2, 1])

        let own = Backup.pick(drafts, profiles: ["Work"], into: nil)
        XCTAssertEqual(own.map(\.issuer), ["B", "C"])
        XCTAssertEqual(own.map(\.profile), ["Work", "Work"], "kept in their own profile")

        let moved = Backup.pick(drafts, profiles: ["", "Club"], into: "Family")
        XCTAssertEqual(moved.map(\.issuer), ["A", "D"])
        XCTAssertEqual(moved.map(\.profile), ["Family", "Family"])
    }
}
