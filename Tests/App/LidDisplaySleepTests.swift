import XCTest

@MainActor
final class LidDisplaySleepTests: XCTestCase {
    func testOnlyAnActiveLockedSessionWithClosedLidCanSleepDisplays() throws {
        for active in [false, true] {
            for lock: ScreenLockState in [.unlocked, .unknown, .locked] {
                for closed in [false, true] {
                    for disabled in [false, true] {
                        let monitor = LidDisplaySleep()
                        monitor.readPowerState = { .init(lidClosed: closed, sleepDisabled: disabled) }
                        var requests = 0
                        monitor.requestDisplaySleep = { requests += 1 }
                        try monitor.update(sessionActive: active, screenState: lock)
                        XCTAssertEqual(requests, active && lock == .locked && closed && disabled ? 1 : 0)
                    }
                }
            }
        }
    }

    func testOneRequestPerClosureAndAnotherAfterReopening() throws {
        let monitor = LidDisplaySleep()
        var closed = true
        var requests = 0
        monitor.readPowerState = { .init(lidClosed: closed, sleepDisabled: true) }
        monitor.requestDisplaySleep = { requests += 1 }
        for _ in 0..<5 { try monitor.update(sessionActive: true, screenState: .locked) }
        XCTAssertEqual(requests, 1)
        closed = false
        try monitor.update(sessionActive: true, screenState: .locked)
        closed = true
        try monitor.update(sessionActive: true, screenState: .locked)
        XCTAssertEqual(requests, 2)
        monitor.reset()
        try monitor.update(sessionActive: true, screenState: .locked)
        XCTAssertEqual(requests, 3)
    }

    func testUnreadableStateDoesNotSleepDisplaysOrRepeatARequest() throws {
        let monitor = LidDisplaySleep()
        var state: LidDisplaySleep.PowerState?
        var requests = 0
        monitor.readPowerState = { state }
        monitor.requestDisplaySleep = { requests += 1 }
        try monitor.update(sessionActive: true, screenState: .locked)
        XCTAssertEqual(requests, 0)
        state = .init(lidClosed: true, sleepDisabled: true)
        try monitor.update(sessionActive: true, screenState: .locked)
        state = nil
        try monitor.update(sessionActive: true, screenState: .locked)
        state = .init(lidClosed: true, sleepDisabled: true)
        try monitor.update(sessionActive: true, screenState: .locked)
        XCTAssertEqual(requests, 1)
    }

    func testFailedRequestIsReportedOnceAndCanRetryOnNextClosure() throws {
        let monitor = LidDisplaySleep()
        var closed = true
        var requests = 0
        monitor.readPowerState = { .init(lidClosed: closed, sleepDisabled: true) }
        monitor.requestDisplaySleep = { requests += 1; throw AppFailure(code: .displaySleep) }
        XCTAssertThrowsError(try monitor.update(sessionActive: true, screenState: .locked))
        try monitor.update(sessionActive: true, screenState: .locked)
        XCTAssertEqual(requests, 1)
        closed = false
        try monitor.update(sessionActive: true, screenState: .locked)
        closed = true
        XCTAssertThrowsError(try monitor.update(sessionActive: true, screenState: .locked))
        XCTAssertEqual(requests, 2)
    }
}
