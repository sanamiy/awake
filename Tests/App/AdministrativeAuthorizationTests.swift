import AppKit
import XCTest

final class AdministrativeAuthorizationTests: XCTestCase {
    func testRecoveryCanOnlyRestoreSleepAndCannotInstallPermissions() throws {
        XCTAssertEqual(try AdministrativeAuthorization.command(for: "--authorize-restore", username: "test-user"),
                       "/usr/bin/pmset -a disablesleep 0")
        XCTAssertThrowsError(try AdministrativeAuthorization.command(for: "--authorize-install", username: "test-user"))
    }

    func testRemovalTargetsOnlyThisUsersRule() throws {
        XCTAssertEqual(try AdministrativeAuthorization.command(for: "--authorize-remove", username: "test-user"),
                       "/bin/rm -f '/etc/sudoers.d/lid-awake-test-user'")
    }

    func testRejectsUnexpectedCommandsAndUnsafeUsernames() {
        for username in ["", "a'; echo bad", "../root", "a\nb"] {
            XCTAssertThrowsError(try AdministrativeAuthorization.command(for: "--authorize-restore", username: username))
        }
        XCTAssertThrowsError(try AdministrativeAuthorization.command(for: "--authorize-arbitrary", username: "test-user"))
    }

    func testAuthorizationScriptCompilesWithoutExecutingIt() throws {
        for action in ["--authorize-restore", "--authorize-remove"] {
            let command = try AdministrativeAuthorization.command(for: action, username: "test-user")
            let source = AdministrativeAuthorization.appleScript(for: command)
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var details: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&details), "\(String(describing: details))")
        }
    }
}
