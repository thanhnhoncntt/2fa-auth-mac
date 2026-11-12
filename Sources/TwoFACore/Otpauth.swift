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
            throw OtpError("Đây là mã QR chuyển tài khoản của Google Authenticator, chưa hỗ trợ nhập")
        }
        guard lower.hasPrefix("otpauth://") else { throw OtpError("Mã QR này không phải mã 2FA") }
        // Some sites put raw spaces in the label.
        guard let url = URLComponents(string: raw.replacingOccurrences(of: " ", with: "%20")) else {
            throw OtpError("Mã QR 2FA bị lỗi định dạng")
        }
        switch url.host?.lowercased() {
        case "totp": break
        case "hotp": throw OtpError("Chưa hỗ trợ mã theo bộ đếm (HOTP), chỉ hỗ trợ mã theo thời gian")
        default: throw OtpError("Mã QR 2FA bị lỗi định dạng")
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
            throw OtpError("Mã QR 2FA dùng số chữ số, chu kỳ hoặc thuật toán chưa hỗ trợ")
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
