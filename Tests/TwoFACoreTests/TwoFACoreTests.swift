// Keys here are the public RFC 4226 / RFC 6238 test secrets or random dummies, never real ones.
import XCTest
@testable import TwoFACore

private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

private func base32Encode(_ bytes: [UInt8]) -> String {
    var out = ""
    var value = 0
    var bits = 0
    for byte in bytes {
        value = (value << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            out.append(alphabet[(value >> bits) & 31])
        }
        value &= (1 << bits) - 1
    }
    if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
    return out
}

private let rfcSecret = Array("12345678901234567890".utf8)
private let rfcSecretB32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
private func randomSecret() -> String { base32Encode((0..<20).map { _ in UInt8.random(in: 0...255) }) }

final class OtpTests: XCTestCase {
    func testHotpMatchesRfc4226AppendixD() {
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        for (counter, code) in expected.enumerated() {
            XCTAssertEqual(OTP.hotp(secret: Data(rfcSecret), counter: UInt64(counter)), code)
        }
    }

    func testTotpMatchesRfc6238AppendixB() {
        let keys: [Algorithm: [UInt8]] = [
            .SHA1: rfcSecret,
            .SHA256: Array("12345678901234567890123456789012".utf8),
            .SHA512: Array("1234567890123456789012345678901234567890123456789012345678901234".utf8),
        ]
        let table: [(Double, String, String, String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1111111109, "07081804", "68084774", "25091201"),
            (1111111111, "14050471", "67062674", "99943326"),
            (1234567890, "89005924", "91819424", "93441116"),
            (2000000000, "69279037", "90698825", "38618901"),
            (20000000000, "65353130", "77737706", "47863826"),
        ]
        for (time, sha1, sha256, sha512) in table {
            let date = Date(timeIntervalSince1970: time)
            for (algorithm, code) in [(Algorithm.SHA1, sha1), (.SHA256, sha256), (.SHA512, sha512)] {
                let account = Account(issuer: "RFC", secret: base32Encode(keys[algorithm]!), digits: 8, algorithm: algorithm)
                XCTAssertEqual(account.code(at: date), code, "\(algorithm) at \(time)")
            }
        }
    }

    func testCountdownAndFormatting() {
        XCTAssertEqual(OTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 60)), 30)
        XCTAssertEqual(OTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 89.9)), 1)
        XCTAssertEqual(OTP.format("123456"), "123 456")
        XCTAssertEqual(OTP.format("12345678"), "1234 5678")
    }

    func testCheckSecretNormalizesAndRejectsWithSafeMessages() throws {
        XCTAssertEqual(try Base32.checkSecret(" gezd gnbv-gy3t qojq gezd gnbv gy3t qojq== "), rfcSecretB32)
        XCTAssertEqual(try Base32.decode(rfcSecretB32), Data(rfcSecret))
        XCTAssertThrowsError(try Base32.checkSecret("")) { XCTAssertEqual(($0 as? OtpError)?.message, "Chưa nhập khóa") }
        XCTAssertThrowsError(try Base32.checkSecret("ABCDEFGH1JKLMNOP")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "Khóa chỉ gồm chữ A–Z và số 2–7")
        }
        XCTAssertThrowsError(try Base32.checkSecret("ABCDEFGH")) {
            XCTAssertEqual(($0 as? OtpError)?.message, "Khóa quá ngắn, cần ít nhất 16 ký tự")
        }
    }
}

final class OtpauthTests: XCTestCase {
    func testLabelIssuerAndDefaults() throws {
        let secret = randomSecret()
        let draft = try Otpauth.parse("otpauth://totp/Acme%20Corp:alex%40example.com?secret=\(secret)")
        XCTAssertEqual(draft, AccountDraft(issuer: "Acme Corp", name: "alex@example.com", secret: secret))
    }

    func testIssuerParameterWinsAndCustomSettingsAreKept() throws {
        let secret = randomSecret()
        let draft = try Otpauth.parse("otpauth://totp/Old:alex?secret=\(secret.lowercased())&issuer=GitHub&digits=8&period=60&algorithm=sha256")
        XCTAssertEqual(draft, AccountDraft(issuer: "GitHub", name: "alex", secret: secret, digits: 8, period: 60, algorithm: .SHA256))
        let plain = try Otpauth.parse("otpauth://totp/alex%20smith?secret=\(secret)")
        XCTAssertEqual(plain.issuer, "")
        XCTAssertEqual(plain.name, "alex smith")
    }

    func testUnsupportedOrBrokenContentsGiveMessagesWithoutTheKey() {
        let secret = randomSecret()
        let cases: [(String, String)] = [
            ("https://example.com", "Mã QR này không phải mã 2FA"),
            ("otpauth-migration://offline?data=abc", "Đây là mã QR chuyển tài khoản của Google Authenticator, chưa hỗ trợ nhập"),
            ("otpauth://hotp/x?secret=\(secret)&counter=1", "Chưa hỗ trợ mã theo bộ đếm (HOTP), chỉ hỗ trợ mã theo thời gian"),
            ("otpauth://totp/x?secret=\(secret)&digits=9", "Mã QR 2FA dùng số chữ số, chu kỳ hoặc thuật toán chưa hỗ trợ"),
            ("otpauth://totp/x?secret=\(secret)&algorithm=MD5", "Mã QR 2FA dùng số chữ số, chu kỳ hoặc thuật toán chưa hỗ trợ"),
            ("otpauth://totp/x?secret=ABC", "Khóa quá ngắn, cần ít nhất 16 ký tự"),
        ]
        for (text, message) in cases {
            XCTAssertThrowsError(try Otpauth.parse(text)) { error in
                let shown = (error as? OtpError)?.message ?? ""
                XCTAssertEqual(shown, message, text)
                XCTAssertFalse(shown.contains(secret), "messages never contain the key")
            }
        }
    }
}

final class AccountBookTests: XCTestCase {
    func testAddRejectsDuplicateKeysAndPersists() throws {
        let storage = InMemoryStorage()
        let book = try AccountBook(storage: storage)
        let secret = randomSecret()
        let added = try book.add(AccountDraft(issuer: " GitHub ", name: "alex", group: " Công việc ", secret: secret.lowercased()))
        XCTAssertEqual(added.issuer, "GitHub")
        XCTAssertEqual(added.group, "Công việc")
        XCTAssertEqual(added.secret, secret)
        XCTAssertThrowsError(try book.add(AccountDraft(issuer: "Other", secret: secret))) {
            XCTAssertEqual(($0 as? OtpError)?.message, "Khóa này đã có trong danh sách: GitHub (alex)")
        }
        XCTAssertThrowsError(try book.add(AccountDraft(secret: randomSecret()))) {
            XCTAssertEqual(($0 as? OtpError)?.message, "Nhập tên tài khoản")
        }
        XCTAssertEqual(try AccountBook(storage: storage).accounts, [added], "a fresh load sees the saved list")
    }

    func testUpdateKeepsTheKeyAndRemoveDeletes() throws {
        let storage = InMemoryStorage()
        let book = try AccountBook(storage: storage)
        let account = try book.add(AccountDraft(issuer: "Google", name: "a", secret: randomSecret()))
        try book.update(account.id, issuer: "Gmail", name: "b", group: "Cá nhân")
        XCTAssertEqual(book.accounts[0].issuer, "Gmail")
        XCTAssertEqual(book.accounts[0].secret, account.secret)
        try book.remove(account.id)
        XCTAssertEqual(try AccountBook(storage: storage).accounts, [])
    }

    func testImportSkipsDuplicatesAndInvalidEntries() throws {
        let book = try AccountBook(storage: InMemoryStorage())
        let existing = randomSecret()
        _ = try book.add(AccountDraft(issuer: "Old", secret: existing))
        let fresh = randomSecret()
        let result = try book.importDrafts([
            AccountDraft(issuer: "Dup", secret: existing),
            AccountDraft(issuer: "New", secret: fresh),
            AccountDraft(issuer: "New again", secret: fresh),
            AccountDraft(issuer: "Broken", secret: "xyz"),
        ])
        XCTAssertEqual(result, ImportResult(added: 1, skipped: 3))
        XCTAssertEqual(book.accounts.map(\.issuer), ["Old", "New"])
    }

    func testTitleIsTheAccountNameWithTheServiceUnderIt() {
        XCTAssertEqual(Account(issuer: "GitHub", name: "alex@x.com", secret: rfcSecretB32).title, "alex@x.com")
        XCTAssertEqual(Account(issuer: "GitHub", name: "alex@x.com", secret: rfcSecretB32).detail, "GitHub")
        XCTAssertEqual(Account(issuer: "GitHub", name: "", secret: rfcSecretB32).title, "GitHub")
        XCTAssertEqual(Account(issuer: "GitHub", name: "", secret: rfcSecretB32).detail, "")
        XCTAssertEqual(Account(issuer: "Zalo", name: "Zalo", secret: rfcSecretB32).detail, "")
    }

    func testSearchIgnoresCaseAndVietnameseAccents() {
        let account = Account(issuer: "Điện lực", name: "Nhơn", group: "Gia đình", secret: rfcSecretB32)
        XCTAssertTrue(account.matches("dien"))
        XCTAssertTrue(account.matches("NHON gia dinh"))
        XCTAssertTrue(account.matches(""))
        XCTAssertFalse(account.matches("github"))
    }
}
