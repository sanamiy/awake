import XCTest
import CoreGraphics

@MainActor
final class ScreenLockSessionTests: XCTestCase {
    private func session() -> ScreenLockSession {
        let value = ScreenLockSession()
        value.prepareLock = {}
        value.requestLock = {}
        value.pause = {}
        value.readState = { .locked }
        return value
    }

    func testMissingPermissionDoesNotChangePowerOrStartSession() async {
        let value = session()
        value.prepareLock = { throw AppFailure(code: .unexpected, detail: "accessibility denied") }
        value.requestLock = { XCTFail("Do not send keys before permission") }
        do {
            try await value.start(enable: { XCTFail("Do not enable without permission") },
                                  restore: { XCTFail("Power has not changed") })
            XCTFail("Permission failure must reject start")
        } catch {
            XCTAssertEqual((error as? AppFailure)?.detail, "accessibility denied")
        }
        XCTAssertEqual(value.phase, .idle)
    }

    func testDirectLockRefusesToPostWithoutPermission() {
        var requests = 0
        let lock = DirectScreenLock(hasAccess: { false }, requestAccess: { requests += 1; return false },
                                    post: { _ in XCTFail("Denied access must not send keys") })
        XCTAssertThrowsError(try lock.requestLock()) { error in
            XCTAssertEqual((error as? AppFailure)?.code, .screenPermission)
        }
        XCTAssertEqual(requests, 1)
    }

    func testDirectLockPostsBalancedShortcutWithoutRequestingExistingPermission() throws {
        var events: [CGEvent] = []
        let lock = DirectScreenLock(hasAccess: { true },
                                    requestAccess: { XCTFail("Permission already exists"); return false },
                                    post: { events.append($0) })
        try lock.requestLock()
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [12, 12])
        XCTAssertTrue(events.allSatisfy { $0.flags == [.maskControl, .maskCommand] })
    }

    func testDirectLockAcceptsNewlyGrantedPermission() throws {
        var events: [CGEvent] = []
        let lock = DirectScreenLock(hasAccess: { false }, requestAccess: { true }, post: { events.append($0) })
        try lock.requestLock()
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
    }

    func testLockIsAlwaysRequestedAndMustBeObservedBeforeSuccess() async throws {
        let value = session()
        var events: [String] = []
        var state: ScreenLockState = .unlocked
        value.requestLock = { events.append("lock") }
        value.readState = { state }
        value.pause = {
            XCTAssertEqual(value.phase, .awaitingLock)
            XCTAssertFalse(value.needsStop, "Do not stop during the initial lock transition")
            events.append("wait")
            state = .locked
        }
        try await value.start(enable: { events.append("start") }, restore: { XCTFail("Unexpected rollback") })
        XCTAssertEqual(events, ["start", "lock", "wait"])
        XCTAssertEqual(value.phase, .locked)
        XCTAssertFalse(value.needsStop)
        state = .unlocked
        XCTAssertFalse(value.needsStop, "A query must not read or mutate state")
        value.observe(state)
        XCTAssertTrue(value.needsStop)
        state = .locked
        value.observe(state)
        XCTAssertTrue(value.needsStop, "Relocking must not cancel the pending stop")
        value.didStop()
        XCTAssertFalse(value.needsStop)
    }

    func testUnlockNotificationOnlyStopsAnArmedSession() async throws {
        let value = session()
        value.didUnlock()
        XCTAssertFalse(value.needsStop)
        try await value.start(enable: {
            value.didUnlock()
            XCTAssertFalse(value.needsStop)
        }, restore: {})
        value.didUnlock()
        XCTAssertTrue(value.needsStop)
        value.didUnlock()
        XCTAssertTrue(value.needsStop)
        value.didStop()
        value.didUnlock()
        XCTAssertFalse(value.needsStop)
    }

    func testLockRequestFailureRestoresSleep() async {
        let value = session()
        var restored = 0
        value.requestLock = { throw AppFailure(code: .unexpected, detail: "permission denied") }
        do {
            try await value.start(enable: {}, restore: { restored += 1 })
            XCTFail("Lock failure must reject start")
        } catch { XCTAssertEqual((error as? AppFailure)?.detail, "permission denied") }
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(value.phase, .idle)
    }

    func testMissingLockConfirmationTimesOutAndRestoresSleep() async {
        for state in [ScreenLockState.unlocked, .unknown] {
            let value = session()
            var waits = 0
            var restored = 0
            value.readState = { state }
            value.pause = { waits += 1 }
            do {
                try await value.start(enable: {}, restore: { restored += 1 })
                XCTFail("A successful key event is not proof of screen lock")
            } catch { }
            XCTAssertEqual(waits, 24)
            XCTAssertEqual(restored, 1)
            XCTAssertEqual(value.phase, .idle)
        }
    }

    func testFailedRollbackKeepsRetryRequiredUntilStopSucceeds() async {
        let value = session()
        value.requestLock = { throw AppFailure(code: .unexpected, detail: "lock failed") }
        do {
            try await value.start(enable: {}, restore: { throw AppFailure(code: .unexpected, detail: "restore failed") })
            XCTFail("Must report both errors")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("lock failed"))
            XCTAssertTrue(error.localizedDescription.contains("restore failed"))
        }
        for _ in 0..<3 { XCTAssertTrue(value.needsStop) }
        value.didStop()
        XCTAssertFalse(value.needsStop)
    }

    func testRuntimeFailureDoesNotLockAndStillAttemptsCleanup() async {
        let value = session()
        var restored = false
        value.requestLock = { XCTFail("Do not lock after runtime start failed") }
        do {
            try await value.start(enable: { throw AppFailure(code: .unexpected, detail: "start failed") }, restore: { restored = true })
            XCTFail("Expected failure")
        } catch { }
        XCTAssertTrue(restored)
        XCTAssertEqual(value.phase, .idle)
    }

    func testUnavailableSessionAfterLockFailsClosed() async throws {
        let value = session()
        try await value.start(enable: {}, restore: {})
        value.observe(.unknown)
        XCTAssertTrue(value.needsStop)
    }

    func testCanceledLockWaitRestoresSleep() async {
        let value = session()
        value.readState = { .unlocked }
        value.pause = { throw CancellationError() }
        var restored = false
        do {
            try await value.start(enable: {}, restore: { restored = true })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(restored)
        XCTAssertEqual(value.phase, .idle)
    }

    func testSessionStateRequiresCurrentUserAndPositiveLockEvidence() {
        var data: [String: Any] = [kCGSessionUserIDKey: NSNumber(value: 501),
                                  kCGSessionOnConsoleKey: true, kCGSessionLoginDoneKey: true]
        XCTAssertEqual(ScreenLockState.decode(nil, userID: 501), .unknown)
        XCTAssertEqual(ScreenLockState.decode(data, userID: 502), .unknown)
        XCTAssertEqual(ScreenLockState.decode(data, userID: 501), .unlocked)
        data["CGSSessionScreenIsLocked"] = true
        XCTAssertEqual(ScreenLockState.decode(data, userID: 501), .locked)
        data["CGSSessionScreenIsLocked"] = false
        XCTAssertEqual(ScreenLockState.decode(data, userID: 501), .unlocked)
        data[kCGSessionOnConsoleKey] = false
        XCTAssertEqual(ScreenLockState.decode(data, userID: 501), .unknown)
    }
}
