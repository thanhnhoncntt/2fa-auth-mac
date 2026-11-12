import Foundation

/// When "Khoá bằng Touch ID" is on: the app locks again once the user has been away from it for `after` seconds.
public struct AutoLock: Sendable {
    public let after: TimeInterval
    private var awaySince: Date?

    public init(after: TimeInterval) { self.after = after }

    /// The user switched to another app or hid this one. Being away already keeps the first time.
    public mutating func left(at date: Date) {
        if awaySince == nil { awaySince = date }
    }

    public mutating func returned() { awaySince = nil }

    public func isExpired(at now: Date) -> Bool {
        guard let awaySince else { return false }
        return now.timeIntervalSince(awaySince) >= after
    }
}
