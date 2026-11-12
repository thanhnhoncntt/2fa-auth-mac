// Base32 and TOTP (RFC 4226 / RFC 6238). Secrets pass through here: never log them or put them in error messages.
import CryptoKit
import Foundation

/// An error whose message is safe to show: it never contains a key.
public struct OtpError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Algorithm: String, Codable, CaseIterable, Sendable {
    case SHA1, SHA256, SHA512
}

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    /// Same floor as Google Authenticator ("key value is too short").
    public static let minSecretLength = 16

    /// Drops spaces, dashes and padding, and upper-cases: "abcd efgh-..." -> "ABCDEFGH...".
    public static func normalize(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "[\\s-]+", with: "", options: .regularExpression)
        while s.hasSuffix("=") { s.removeLast() }
        return s.uppercased()
    }

    private static func isBase32(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(alphabet.contains) }

    /// The normalized secret, or an OtpError that is safe to show.
    public static func checkSecret(_ input: String) throws -> String {
        let s = normalize(input)
        if s.isEmpty { throw OtpError("Chưa nhập khóa") }
        if !isBase32(s) { throw OtpError("Khóa chỉ gồm chữ A–Z và số 2–7") }
        if s.count < minSecretLength { throw OtpError("Khóa quá ngắn, cần ít nhất \(minSecretLength) ký tự") }
        return s
    }

    public static func decode(_ input: String) throws -> Data {
        let s = normalize(input)
        guard isBase32(s) else { throw OtpError("Khóa chỉ gồm chữ A–Z và số 2–7") }
        var out = Data()
        var value = 0
        var bits = 0
        for ch in s {
            value = (value << 5) | alphabet.firstIndex(of: ch)!
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xff))
                value &= (1 << bits) - 1
            }
        }
        return out
    }
}

public enum OTP {
    public static func hotp(secret: Data, counter: UInt64, digits: Int = 6, algorithm: Algorithm = .SHA1) -> String {
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .SHA1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .SHA256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .SHA512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let modulus = (0..<digits).reduce(UInt32(1)) { m, _ in m * 10 }
        let code = String(bin % modulus)
        return String(repeating: "0", count: digits - code.count) + code
    }

    public static func counter(period: Int, at date: Date) -> UInt64 {
        UInt64(max(0, Int64(date.timeIntervalSince1970.rounded(.down))) / Int64(period))
    }

    /// Seconds before the code changes, from period down to 1.
    public static func secondsRemaining(period: Int, at date: Date) -> Int {
        period - Int(Int64(date.timeIntervalSince1970.rounded(.down)) % Int64(period))
    }

    /// "123456" -> "123 456", "12345678" -> "1234 5678".
    public static func format(_ code: String) -> String {
        let half = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<half]) \(code[half...])"
    }
}
