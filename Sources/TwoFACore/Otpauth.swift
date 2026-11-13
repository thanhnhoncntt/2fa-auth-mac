import Foundation

/// Reads the otpauth://totp/ link inside a 2FA setup QR code.
public enum Otpauth {
    public static func isOtpauth(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth")
    }

    public static func parse(_ text: String) throws -> AccountDraft {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.hasPrefix("otpauth-migration:") {
            throw OtpError(L("This is a Google Authenticator export QR code with several accounts"))
        }
        guard lower.hasPrefix("otpauth://") else { throw OtpError(L("This QR code is not a 2FA code")) }
        // Some sites put raw spaces in the label.
        guard let url = URLComponents(string: raw.replacingOccurrences(of: " ", with: "%20")) else {
            throw OtpError(L("This 2FA QR code is malformed"))
        }
        switch url.host?.lowercased() {
        case "totp": break
        case "hotp": throw OtpError(L("Counter-based codes (HOTP) are not supported, only time-based ones"))
        default: throw OtpError(L("This 2FA QR code is malformed"))
        }

        var params: [String: String] = [:]
        for item in url.queryItems ?? [] where params[item.name.lowercased()] == nil {
            params[item.name.lowercased()] = item.value ?? ""
        }
        let secret = try Base32.checkSecret(params["secret"] ?? "")
        let digits = Int(params["digits"] ?? "6")
        let period = Int(params["period"] ?? "30")
        let algorithm = Algorithm(rawValue: (params["algorithm"] ?? "SHA1").uppercased())
        guard let digits, [6, 7, 8].contains(digits), let period, period > 0, let algorithm else {
            throw OtpError(L("This 2FA QR code uses an unsupported number of digits, period or algorithm"))
        }

        // The label is "Issuer:account" or just "account"; the issuer parameter wins over the prefix.
        let label = String(url.path.drop(while: { $0 == "/" }))
        let colon = label.firstIndex(of: ":")
        let labelIssuer = colon.map { String(label[..<$0]) } ?? ""
        let name = colon.map { String(label[label.index(after: $0)...]) } ?? label
        let issuer = params["issuer"] ?? labelIssuer
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        return AccountDraft(issuer: trim(issuer), name: trim(name), secret: secret,
                            digits: digits, period: period, algorithm: algorithm)
    }
}
