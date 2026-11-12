import XCTest
@testable import TwoFACore

final class AutoLockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testLocksOnlyAfterBeingAwayLongEnough() {
        var lock = AutoLock(after: 300)
        XCTAssertFalse(lock.isExpired(at: t0), "never left the app")
        lock.left(at: t0)
        XCTAssertFalse(lock.isExpired(at: t0.addingTimeInterval(299)))
        XCTAssertTrue(lock.isExpired(at: t0.addingTimeInterval(300)))
    }

    func testComingBackResetsTheTimerAndTheFirstDepartureCounts() {
        var lock = AutoLock(after: 300)
        lock.left(at: t0)
        lock.left(at: t0.addingTimeInterval(200)) // a second "left" while still away keeps the first time
        XCTAssertTrue(lock.isExpired(at: t0.addingTimeInterval(300)))
        lock.returned()
        XCTAssertFalse(lock.isExpired(at: t0.addingTimeInterval(10_000)))
    }
}
