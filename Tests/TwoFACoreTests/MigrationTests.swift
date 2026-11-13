// Import from other authenticator apps. Every key here is a random dummy, never a real one.
import XCTest
@testable import TwoFACore

private func randomBytes(_ n: Int = 10) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255) } }
private func randomKey() -> String { Base32.encode(Data(randomBytes(20))) }
private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// A tiny protobuf writer, enough to build Google Authenticator export payloads.
private struct Proto {
    var bytes: [UInt8] = []
    mutating func varint(_ v: UInt64) { var v = v; while v >= 0x80 { bytes.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }; bytes.append(UInt8(v)) }
    mutating func int(_ field: Int, _ v: UInt64) { varint(UInt64(field << 3)); varint(v) }
    mutating func data(_ field: Int, _ d: [UInt8]) { varint(UInt64(field << 3 | 2)); varint(UInt64(d.count)); bytes += d }
    mutating func string(_ field: Int, _ s: String) { data(field, Array(s.utf8)) }
}

private func googleUri(_ accounts: [(secret: [UInt8], name: String, issuer: String, algorithm: UInt64, digits: UInt64, type: UInt64)]) -> String {
    var payload = Proto()
    for a in accounts {
        var p = Proto()
        p.data(1, a.secret); p.string(2, a.name); p.string(3, a.issuer)
        p.int(4, a.algorithm); p.int(5, a.digits); p.int(6, a.type)
        payload.data(1, p.bytes)
    }
    payload.int(2, 1); payload.int(3, 1); payload.int(4, 0); payload.int(5, 12345)
    let b64 = Data(payload.bytes).base64EncodedString()
    let encoded = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    return "otpauth-migration://offline?data=\(encoded)"
}

final class MigrationTests: XCTestCase {
    func testBase32EncodeRoundTrips() throws {
        XCTAssertEqual(Base32.encode(Data("12345678901234567890".utf8)), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let bytes = Data(randomBytes(13))
        XCTAssertEqual(try Base32.decode(Base32.encode(bytes)), bytes)
    }

    /// The "Authenticator" Chrome extension export (version 2.0): both issuer and name hold the full "Issuer: account" label.
    func testAuthenticatorExtensionExportSplitsTheLabel() throws {
        let (k1, k2) = (randomKey(), randomKey())
        let file = json([
            "version": "2.0", "exportDate": "2026-11-13T00:00:00.000Z", "appVersion": "1.16.1", "accountCount": 2,
            "sourceLink": String(repeating: "a", count: 64),
            "accounts": [
                ["algorithm": "SHA1", "color": "#123456", "createdAt": 1, "digits": 6, "id": "1-a", "period": 30,
                 "issuer": "Acme Corp: alex@example.com", "name": "Acme Corp: alex@example.com", "secret": k1,
                 "sites": ["login.acme.example"], "updatedAt": 1],
                ["algorithm": "SHA1", "color": "#654321", "createdAt": 2, "digits": 6, "id": "2-b", "period": 30,
                 "issuer": "Zalo", "name": "0901 234 567", "secret": k2, "updatedAt": 2],
            ],
        ])
        let result = try Migration.parse(file)
        XCTAssertEqual(result.drafts, [
            AccountDraft(issuer: "Acme Corp", name: "alex@example.com", secret: k1),
            AccountDraft(issuer: "Zalo", name: "0901 234 567", secret: k2),
        ])
        XCTAssertEqual(result.unsupported, 0)
    }

    /// authenticator.cc: an object keyed by hash; counter-based, Steam and password-protected entries cannot be used.
    func testAuthenticatorCcExportSkipsWhatCannotBeUsed() throws {
        let key = randomKey()
        let file = json([
            "h1": ["account": "alex", "issuer": "GitHub", "secret": key, "type": "totp", "encrypted": false,
                   "period": 30, "digits": 6, "algorithm": "SHA1", "hash": "h1", "index": 0, "counter": 0],
            "h2": ["account": "bob", "issuer": "Bank", "secret": randomKey(), "type": "hotp", "encrypted": false, "counter": 3],
            "h3": ["account": "carol", "issuer": "Steam", "secret": randomKey(), "type": "steam", "encrypted": false],
            "h4": ["account": "dave", "issuer": "Locked", "secret": "U2FsdGVkX1+abc", "type": "totp", "encrypted": true],
        ])
        let result = try Migration.parse(file)
        XCTAssertEqual(result.drafts, [AccountDraft(issuer: "GitHub", name: "alex", secret: key)])
        XCTAssertEqual(result.unsupported, 3)
    }

    func testAegisPlainExportKeepsCustomSettings() throws {
        let key = randomKey()
        let file = json([
            "version": 1, "header": ["slots": NSNull(), "params": NSNull()],
            "db": ["version": 2, "entries": [
                ["type": "totp", "uuid": "u1", "name": "alex", "issuer": "GitHub", "note": "",
                 "info": ["secret": key, "algo": "SHA256", "digits": 8, "period": 60]],
                ["type": "steam", "uuid": "u2", "name": "gamer", "issuer": "Steam",
                 "info": ["secret": randomKey(), "algo": "SHA1", "digits": 5, "period": 30]],
            ]],
        ])
        let result = try Migration.parse(file)
        XCTAssertEqual(result.drafts, [AccountDraft(issuer: "GitHub", name: "alex", secret: key, digits: 8, period: 60, algorithm: .SHA256)])
        XCTAssertEqual(result.unsupported, 1)
    }

    func testTwoFasExportUsesTheServiceAndAccount() throws {
        let key = randomKey()
        let file = json([
            "schemaVersion": 4, "appVersionCode": 5000000, "groups": [],
            "services": [["name": "Google", "secret": key, "updatedAt": 1,
                          "otp": ["account": "alex@example.com", "issuer": "Google", "digits": 6, "period": 30,
                                  "algorithm": "SHA1", "tokenType": "TOTP"]]],
        ])
        XCTAssertEqual(try Migration.parse(file).drafts, [AccountDraft(issuer: "Google", name: "alex@example.com", secret: key)])
    }

    func testAndOtpAndBitwardenExports() throws {
        let (k1, k2, k3) = (randomKey(), randomKey(), randomKey())
        let andOtp = json([["secret": k1, "issuer": "Dropbox", "label": "alex", "digits": 6, "type": "TOTP",
                            "algorithm": "SHA1", "period": 30, "thumbnail": "Default", "tags": []]])
        XCTAssertEqual(try Migration.parse(andOtp).drafts, [AccountDraft(issuer: "Dropbox", name: "alex", secret: k1)])

        let bitwarden = json(["encrypted": false, "items": [
            ["name": "GitLab", "type": 1, "login": ["username": "alex", "totp": k2]],
            ["name": "Other", "type": 1, "login": ["username": "x", "totp": "otpauth://totp/Other:bob?secret=\(k3)&issuer=Other"]],
            ["name": "No 2FA", "type": 1, "login": ["username": "y", "totp": NSNull()]],
        ]])
        XCTAssertEqual(try Migration.parse(bitwarden).drafts, [
            AccountDraft(issuer: "GitLab", name: "alex", secret: k2),
            AccountDraft(issuer: "Other", name: "bob", secret: k3),
        ])
    }

    /// Ente Auth, Aegis (text), Raivo and many others export one otpauth:// link per line.
    func testPlainTextLinks() throws {
        let (k1, k2) = (randomKey(), randomKey())
        let text = """
        otpauth://totp/GitHub:alex?secret=\(k1)&issuer=GitHub

        otpauth://totp/Bank:bob?secret=\(k2)&digits=8
        otpauth://hotp/Old:carol?secret=\(randomKey())&counter=1
        """
        let result = try Migration.parse(Data(text.utf8))
        XCTAssertEqual(result.drafts, [
            AccountDraft(issuer: "GitHub", name: "alex", secret: k1),
            AccountDraft(issuer: "Bank", name: "bob", secret: k2, digits: 8),
        ])
        XCTAssertEqual(result.unsupported, 1)
    }

    func testGoogleAuthenticatorExportQrCode() throws {
        let (s1, s2) = (randomBytes(), randomBytes(20))
        let uri = googleUri([
            (s1, "GitHub:alex", "GitHub", 1, 1, 2),
            (s2, "bob@example.com", "", 2, 2, 2),
            (randomBytes(), "counter", "Old", 1, 1, 1), // HOTP
        ])
        let result = try Migration.parse(Data(uri.utf8))
        XCTAssertEqual(result.drafts, [
            AccountDraft(issuer: "GitHub", name: "alex", secret: Base32.encode(Data(s1))),
            AccountDraft(issuer: "", name: "bob@example.com", secret: Base32.encode(Data(s2)), digits: 8, algorithm: .SHA256),
        ])
        XCTAssertEqual(result.unsupported, 1)
        XCTAssertTrue(Migration.isGoogleExport(uri))
        XCTAssertThrowsError(try Migration.parse(Data("otpauth-migration://offline?data=%%%".utf8)))
    }

    func testEncryptedOrEmptyFilesGiveMessagesWithoutTheKey() {
        let key = randomKey()
        let cases: [(Data, String)] = [
            (json(["version": 1, "header": ["slots": [["type": 1]]], "db": "c2VhbGVk\(key)"]),
             "This Aegis backup is encrypted. In Aegis, export again without encryption."),
            (json(["schemaVersion": 4, "services": [], "servicesEncrypted": "abc:\(key)"]),
             "This 2FAS backup is encrypted. In 2FAS, export again without a password."),
            (json(["notes": "nothing here", "list": [1, 2, 3]]), "No 2FA accounts found in this file"),
            (Data([0xFF, 0xFE, 0x00, 0x01]), "No 2FA accounts found in this file"),
        ]
        for (data, message) in cases {
            XCTAssertThrowsError(try Migration.parse(data)) { error in
                let shown = (error as? OtpError)?.message ?? ""
                XCTAssertEqual(shown, message)
                XCTAssertFalse(shown.contains(key))
            }
        }
    }

    func testImportIntoTheBookSkipsDuplicates() throws {
        let book = try AccountBook(storage: InMemoryStorage())
        let key = randomKey()
        _ = try book.add(AccountDraft(issuer: "GitHub", name: "alex", secret: key))
        let result = try Migration.parse(Data("otpauth://totp/GitHub:alex?secret=\(key)\notpauth://totp/New:x?secret=\(randomKey())".utf8))
        XCTAssertEqual(try book.importDrafts(result.drafts), ImportResult(added: 1, skipped: 1))
    }
}
