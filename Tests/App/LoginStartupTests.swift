import XCTest
import ServiceManagement
import AppKit
import Carbon

final class LoginStartupTests: XCTestCase {
    func testOnlyLoginEventSuppressesSettingsWindow() {
        XCTAssertFalse(LoginStartup.isLoginLaunch(nil))
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass,
                                          eventID: kAEOpenApplication, targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginStartup.isLoginLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(LoginStartup.isLoginLaunch(event))
    }

    func testRegistersMissingLoginItem() {
        for initialStatus in [SMAppService.Status.notRegistered, .notFound] {
            var status = initialStatus
            var calls = 0
            let issue = LoginStartup.registerIfNeeded(status: { status }, register: { calls += 1; status = .enabled })
            XCTAssertEqual(calls, 1, "\(initialStatus)")
            XCTAssertNil(issue, "\(initialStatus)")
        }
    }

    func testDoesNotReregisterEnabledOrApprovalPendingItems() {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            var calls = 0
            let issue = LoginStartup.registerIfNeeded(status: { status }, register: { calls += 1 })
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(issue == nil, status == .enabled)
        }
    }

    func testPendingApprovalAfterRegistrationRemainsVisible() {
        for initialStatus in [SMAppService.Status.notRegistered, .notFound] {
            var status = initialStatus
            var calls = 0
            let issue = LoginStartup.registerIfNeeded(status: { status }, register: {
                calls += 1
                status = .requiresApproval
            })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(issue, LoginStartup.issue(for: .requiresApproval))
            XCTAssertNotNil(issue)
        }
    }

    func testRegistrationErrorAndUnchangedStatusAreNotSuccess() {
        for status in [SMAppService.Status.notRegistered, .notFound] {
            var calls = 0
            let issue = LoginStartup.registerIfNeeded(status: { status }, register: {
                calls += 1
                throw Failure()
            })
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(issue?.contains("LA5004") == true)
            XCTAssertTrue(issue?.contains("registration failure detail") == true)

            calls = 0
            XCTAssertNotNil(LoginStartup.registerIfNeeded(status: { status }, register: { calls += 1 }))
            XCTAssertEqual(calls, 1, "An unchanged status must not cause a registration loop")
        }
    }

    func testStatusRefreshPreservesRegistrationFailureUntilResolved() {
        let failure = LoginStartup.registerIfNeeded(status: { .notFound }, register: { throw Failure() })
        XCTAssertNotNil(failure)
        for status in [SMAppService.Status.notRegistered, .notFound] {
            XCTAssertEqual(LoginStartup.issue(for: status, previousIssue: failure), failure)
        }
        XCTAssertNil(LoginStartup.issue(for: .enabled, previousIssue: failure))
        XCTAssertEqual(LoginStartup.issue(for: .requiresApproval, previousIssue: failure),
                       LoginStartup.issue(for: .requiresApproval))
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "registration failure detail" }
    }
}
