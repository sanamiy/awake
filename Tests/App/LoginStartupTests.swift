import XCTest
import ServiceManagement

final class LoginStartupTests: XCTestCase {
    func testRegistrationReportsEnabledOrPendingApproval() {
        for initial in [SMAppService.Status.notRegistered, .notFound] {
            for result in [SMAppService.Status.enabled, .requiresApproval] {
                var status = initial
                var calls = 0
                let issue = LoginStartup.registerIfNeeded(status: { status }, register: {
                    calls += 1
                    status = result
                })
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(issue, LoginStartup.issue(for: result))
            }
        }
    }

    func testEnabledAndPendingItemsAreNotReregistered() {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            let issue = LoginStartup.registerIfNeeded(status: { status }, register: {
                XCTFail("Do not reregister an enabled or pending login item")
            })
            XCTAssertEqual(issue == nil, status == .enabled)
        }
    }

    func testRegistrationErrorAndUnchangedStatusAreNotSuccess() {
        for status in [SMAppService.Status.notRegistered, .notFound] {
            let issue = LoginStartup.registerIfNeeded(status: { status }, register: { throw Failure() })
            XCTAssertTrue(issue?.contains("LA5004") == true)
            XCTAssertTrue(issue?.contains("registration failure detail") == true)
            var calls = 0
            XCTAssertNotNil(LoginStartup.registerIfNeeded(status: { status }, register: { calls += 1 }))
            XCTAssertEqual(calls, 1, "An unchanged status must not cause a registration loop")
        }
    }

    func testStatusRefreshPreservesRegistrationFailureUntilResolved() {
        let failure = LoginStartup.registerIfNeeded(status: { .notRegistered }, register: { throw Failure() })
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
