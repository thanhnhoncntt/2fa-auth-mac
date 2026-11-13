// Reads the export files of other authenticator apps, and Google Authenticator's export QR codes.
// Rather than one parser per app, JSON is searched for anything shaped like a 2FA account (an object with a
// "secret", or with an "info" or "otp" object holding one), and text for otpauth:// links. That covers the
// "Authenticator" Chrome extensions, Aegis, 2FAS, andOTP, Bitwarden, Ente Auth, Raivo and plain link lists.
// Keys pass through here; never log them or put them in error messages.
import Foundation

public struct MigrationResult: Equatable, Sendable {
    /// Accounts ready for AccountBook.importDrafts, which still skips the ones already in the list.
    public var drafts: [AccountDraft] = []
    /// Accounts found that this app cannot use: counter-based (HOTP), Steam, password-protected or broken.
    public var unsupported = 0
}

public enum Migration {
    /// Reads an export file of another app. Throws a message that is safe to show when nothing usable is in it.
    public static func parse(_ data: Data) throws -> MigrationResult {
        var result = MigrationResult()
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            try refuseEncrypted(object)
            walk(object, into: &result)
        } else if let text = String(data: data, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                guard let start = line.range(of: "otpauth", options: .caseInsensitive)?.lowerBound else { continue }
                let link = line[start...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\",;")))
                try readLink(link, into: &result)
            }
        }
        if result.drafts.isEmpty && result.unsupported == 0 { throw OtpError(L("No 2FA accounts found in this file")) }
        return result
    }

    /// An otpauth-migration:// link, from the QR codes of Google Authenticator's "Transfer accounts → Export".
    public static func isGoogleExport(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth-migration:")
    }

    // MARK: JSON

    private static func refuseEncrypted(_ object: Any) throws {
        guard let root = object as? [String: Any] else { return }
        if root["header"] != nil, root["db"] is String {
            throw OtpError(L("This Aegis backup is encrypted. In Aegis, export again without encryption."))
        }
        if let sealed = root["servicesEncrypted"] as? String, !sealed.isEmpty {
            throw OtpError(L("This 2FAS backup is encrypted. In 2FAS, export again without a password."))
        }
    }

    private static func walk(_ value: Any, into result: inout MigrationResult) {
        switch value {
        case let text as String:
            if Otpauth.isOtpauth(text) { try? readLink(text, into: &result) }
        case let list as [Any]:
            for item in list { walk(item, into: &result) }
        case let object as [String: Any]:
            if let login = object["login"] as? [String: Any], let totp = login["totp"] as? String, !totp.isEmpty {
                readBitwarden(item: object, login: login, totp: totp, into: &result)
            } else if object["secret"] is String || (object["info"] as? [String: Any])?["secret"] is String {
                readEntry(object, into: &result)
            } else {
                for key in object.keys.sorted() { walk(object[key]!, into: &result) }
            }
        default:
            break
        }
    }

    private static func readEntry(_ entry: [String: Any], into result: inout MigrationResult) {
        let otp = entry["otp"] as? [String: Any] ?? [:]
        let info = entry["info"] as? [String: Any] ?? [:]
        let layers = [entry, otp, info]
        func text(_ keys: String...) -> String? {
            for layer in layers { for key in keys { if let s = layer[key] as? String, !s.trimmed.isEmpty { return s.trimmed } } }
            return nil
        }
        func number(_ keys: String...) -> Int? {
            for layer in layers {
                for key in keys {
                    if let n = layer[key] as? NSNumber { return n.intValue }
                    if let s = layer[key] as? String, let n = Int(s.trimmed) { return n }
                }
            }
            return nil
        }

        let type = (text("type", "tokenType") ?? "totp").lowercased()
        guard type == "totp", (entry["encrypted"] as? Bool) != true,
              let secret = try? Base32.checkSecret(text("secret") ?? "") else {
            result.unsupported += 1
            return
        }
        let algorithmName = (text("algorithm", "algo") ?? "SHA1").uppercased()
            .replacingOccurrences(of: "HMAC", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        let digits = number("digits") ?? 6
        let period = number("period", "interval", "step") ?? 30
        guard let algorithm = Algorithm(rawValue: algorithmName), (6...8).contains(digits), period > 0 else {
            result.unsupported += 1
            return
        }

        // Account name and service: 2FAS keeps them in "otp", Aegis in "name"/"issuer", andOTP in "label".
        var name = (otp["account"] as? String)?.trimmed.nonEmpty ?? text("account", "label", "username", "email")
        var issuer = text("issuer") ?? ""
        if let entryName = (entry["name"] as? String)?.trimmed.nonEmpty {
            if name == nil { name = entryName } else if issuer.isEmpty { issuer = entryName }
        }
        let (finalIssuer, finalName) = splitLabel(issuer: issuer, name: name ?? "")
        result.drafts.append(AccountDraft(issuer: finalIssuer, name: finalName, secret: secret,
                                          digits: digits, period: period, algorithm: algorithm))
    }

    /// Bitwarden keeps the 2FA key of a login as an otpauth:// link or as the bare key.
    private static func readBitwarden(item: [String: Any], login: [String: Any], totp: String, into result: inout MigrationResult) {
        let itemName = (item["name"] as? String)?.trimmed ?? ""
        if Otpauth.isOtpauth(totp) {
            var links = MigrationResult()
            try? readLink(totp, into: &links)
            for var draft in links.drafts {
                if draft.issuer.isEmpty { draft.issuer = itemName }
                result.drafts.append(draft)
            }
            result.unsupported += links.unsupported
        } else if let secret = try? Base32.checkSecret(totp) {
            result.drafts.append(AccountDraft(issuer: itemName, name: (login["username"] as? String)?.trimmed ?? "", secret: secret))
        } else {
            result.unsupported += 1 // e.g. "steam://…"
        }
    }

    /// "Issuer: account" in the name field (or in both fields, as the Authenticator extension does) becomes two parts.
    static func splitLabel(issuer: String, name: String) -> (String, String) {
        guard let colon = name.firstIndex(of: ":") else { return (issuer, name) }
        let prefix = name[..<colon].trimmed
        let rest = name[name.index(after: colon)...].trimmed
        guard !prefix.isEmpty, !rest.isEmpty else { return (issuer, name) }
        if issuer.isEmpty || issuer == name { return (prefix, rest) }
        if prefix.caseInsensitiveCompare(issuer) == .orderedSame { return (issuer, rest) }
        return (issuer, name)
    }

    // MARK: links

    private static func readLink(_ link: String, into result: inout MigrationResult) throws {
        if isGoogleExport(link) {
            try readGoogleExport(link, into: &result)
        } else if let draft = try? Otpauth.parse(link) {
            result.drafts.append(draft)
        } else {
            result.unsupported += 1
        }
    }

    /// The `data` parameter is a base64 protobuf MigrationPayload: repeated OtpParameters in field 1, each with
    /// secret bytes (1), name (2), issuer (3), algorithm (4), digit count (5) and type (6).
    private static func readGoogleExport(_ link: String, into result: inout MigrationResult) throws {
        let damaged = OtpError(L("This Google Authenticator export QR code is damaged"))
        guard let query = URLComponents(string: link.trimmed)?.queryItems,
              var base64 = query.first(where: { $0.name == "data" })?.value else { throw damaged }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let payload = Data(base64Encoded: base64) else { throw damaged }

        var reader = ProtoReader(Array(payload))
        while let (field, value) = try reader.next() {
            guard field == 1, case .bytes(let bytes) = value else { continue }
            var secret: [UInt8] = [], name = "", issuer = ""
            var algorithm: UInt64 = 1, digits: UInt64 = 1, type: UInt64 = 2
            var account = ProtoReader(bytes)
            while let (f, v) = try account.next() {
                switch (f, v) {
                case (1, .bytes(let b)): secret = b
                case (2, .bytes(let b)): name = String(decoding: b, as: UTF8.self)
                case (3, .bytes(let b)): issuer = String(decoding: b, as: UTF8.self)
                case (4, .varint(let n)): algorithm = n
                case (5, .varint(let n)): digits = n
                case (6, .varint(let n)): type = n
                default: break
                }
            }
            let algorithms: [UInt64: Algorithm] = [0: .SHA1, 1: .SHA1, 2: .SHA256, 3: .SHA512]
            guard type == 2 || type == 0, let algo = algorithms[algorithm], digits <= 2,
                  let key = try? Base32.checkSecret(Base32.encode(Data(secret))) else {
                result.unsupported += 1
                continue
            }
            let (finalIssuer, finalName) = splitLabel(issuer: issuer.trimmed, name: name.trimmed)
            result.drafts.append(AccountDraft(issuer: finalIssuer, name: finalName, secret: key,
                                              digits: digits == 2 ? 8 : 6, algorithm: algo))
        }
    }
}

/// Just enough protobuf to walk Google Authenticator's export payload.
private struct ProtoReader {
    enum Value { case varint(UInt64), bytes([UInt8]), other }
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private static var damaged: OtpError { OtpError(L("This Google Authenticator export QR code is damaged")) }

    private mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard index < bytes.count else { throw Self.damaged }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw Self.damaged
    }

    private mutating func skip(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - index else { throw Self.damaged }
        defer { index += count }
        return Array(bytes[index..<index + count])
    }

    mutating func next() throws -> (Int, Value)? {
        guard index < bytes.count else { return nil }
        let tag = try varint()
        let field = Int(tag >> 3)
        switch tag & 7 {
        case 0: return (field, .varint(try varint()))
        case 1: _ = try skip(8); return (field, .other)
        case 2:
            let length = try varint()
            guard length <= UInt64(Int.max) else { throw Self.damaged }
            return (field, .bytes(try skip(Int(length))))
        case 5: _ = try skip(4); return (field, .other)
        default: throw Self.damaged
        }
    }
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
