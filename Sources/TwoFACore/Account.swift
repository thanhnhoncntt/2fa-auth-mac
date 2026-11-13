import Foundation

/// A saved 2FA account. The secret is normalized base32 and is never shown again after saving.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var issuer: String
    public var name: String
    public var group: String
    public var secret: String
    public var digits: Int
    public var period: Int
    public var algorithm: Algorithm
    /// The profile (separate account list) it belongs to; "" is the default profile.
    public var profile: String

    public init(id: UUID = UUID(), issuer: String = "", name: String = "", group: String = "", secret: String,
                digits: Int = 6, period: Int = 30, algorithm: Algorithm = .SHA1, profile: String = "") {
        self.id = id
        self.issuer = issuer
        self.name = name
        self.group = group
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey { case id, issuer, name, group, secret, digits, period, algorithm, profile }

    /// Lists and backups saved before profiles existed have no "profile": those accounts are in the default one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        issuer = try c.decode(String.self, forKey: .issuer)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        secret = try c.decode(String.self, forKey: .secret)
        digits = try c.decode(Int.self, forKey: .digits)
        period = try c.decode(Int.self, forKey: .period)
        algorithm = try c.decode(Algorithm.self, forKey: .algorithm)
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
    }

    /// "Google (alex@example.com)", or whichever of the two names exists.
    public var label: String { !issuer.isEmpty && !name.isEmpty ? "\(issuer) (\(name))" : issuer.isEmpty ? name : issuer }

    /// What the list shows: the account name, or the service name when there is no account name.
    public var title: String { name.isEmpty ? issuer : name }

    /// The service name under the title, when it adds something.
    public var detail: String { name.isEmpty || issuer == name ? "" : issuer }

    public func code(at date: Date) -> String {
        guard let key = try? Base32.decode(secret) else { return String(repeating: "-", count: digits) }
        return OTP.hotp(secret: key, counter: OTP.counter(period: period, at: date), digits: digits, algorithm: algorithm)
    }

    public func secondsRemaining(at date: Date) -> Int { OTP.secondsRemaining(period: period, at: date) }

    /// Every word of the query appears in the issuer, name or group, ignoring case and Vietnamese accents.
    public func matches(_ query: String) -> Bool {
        let haystack = Search.fold("\(issuer) \(name) \(group)")
        return Search.fold(query).split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

/// What the user typed or a QR code held, before it is checked and saved.
public struct AccountDraft: Equatable, Sendable {
    public var issuer: String
    public var name: String
    public var group: String
    public var secret: String
    public var digits: Int
    public var period: Int
    public var algorithm: Algorithm
    public var profile: String

    public init(issuer: String = "", name: String = "", group: String = "", secret: String,
                digits: Int = 6, period: Int = 30, algorithm: Algorithm = .SHA1, profile: String = "") {
        self.issuer = issuer
        self.name = name
        self.group = group
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.profile = profile
    }
}

public enum Search {
    /// Lowercase, accents stripped: "Điện" and "dien" match.
    public static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "đ", with: "d")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
