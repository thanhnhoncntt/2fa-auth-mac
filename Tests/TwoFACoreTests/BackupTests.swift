// Keys here are random dummies, never real ones.
import XCTest
@testable import TwoFACore

final class BackupTests: XCTestCase {
    private let fast = 1_000 // PBKDF2 rounds for tests; real backups use Backup.defaultIterations

    private func sample() throws -> [Account] {
        let book = try AccountBook(storage: InMemoryStorage())
        try book.add(AccountDraft(issuer: "GitHub", name: "alex", group: "Work", secret: "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"))
        try book.add(AccountDraft(issuer: "Bank", name: "a", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", digits: 8, period: 60, algorithm: .SHA256))
        return book.accounts
    }

    func testRoundTripKeepsEveryFieldAndHidesTheKeys() throws {
        let accounts = try sample()
        let file = try Backup.encrypt(accounts, password: "correct horse", iterations: fast)
        XCTAssertTrue(Backup.isEncrypted(file))
        let text = String(decoding: file, as: UTF8.self)
        XCTAssertFalse(text.contains("JBSWY3DP"), "keys are not readable in the file")
        XCTAssertFalse(text.contains("GitHub"), "names are not readable either")
        let restored = try Backup.decrypt(file, password: "correct horse")
        XCTAssertEqual(restored, accounts.map {
            AccountDraft(issuer: $0.issuer, name: $0.name, group: $0.group, secret: $0.secret,
                         digits: $0.digits, period: $0.period, algorithm: $0.algorithm)
        })
    }

    func testWrongPasswordOrTamperingIsRejected() throws {
        let file = try Backup.encrypt(try sample(), password: "correct horse", iterations: fast)
        XCTAssertThrowsError(try Backup.decrypt(file, password: "wrong horse")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "Wrong password, or the backup file is damaged")
        }
        var json = try JSONSerialization.jsonObject(with: file) as! [String: Any]
        var box = Data(base64Encoded: json["data"] as! String)!
        box[box.count / 2] ^= 0xff
        json["data"] = box.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try Backup.decrypt(tampered, password: "correct horse"))
    }

    func testEachBackupUsesFreshSaltAndShortPasswordsAreRefused() throws {
        let accounts = try sample()
        let a = try Backup.encrypt(accounts, password: "correct horse", iterations: fast)
        let b = try Backup.encrypt(accounts, password: "correct horse", iterations: fast)
        XCTAssertNotEqual(a, b)
        XCTAssertThrowsError(try Backup.encrypt(accounts, password: "short", iterations: fast)) {
            XCTAssertEqual(($0 as? OtpError)?.message, "The password needs at least 8 characters")
        }
        XCTAssertGreaterThanOrEqual(Backup.defaultIterations, 600_000)
    }

    func testPlainExportsAndOtherFilesAreNotTakenForBackups() {
        XCTAssertFalse(Backup.isEncrypted(Data(#"{"format":"2fa-auth","version":1,"accounts":[]}"#.utf8)))
        XCTAssertFalse(Backup.isEncrypted(Data("hello".utf8)))
        XCTAssertThrowsError(try Backup.decrypt(Data("hello".utf8), password: "correct horse")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "This is not a 2FA Auth backup file")
        }
    }
}
