import XCTest

final class AppFailureTests: XCTestCase {
    func testBatteryLimitIsGuidanceWithoutExposingDiagnostics() {
        let failure = AppFailure(code: .runtimeExit(86), detail: "exit 86; battery 14%, limit 20%")
        XCTAssertTrue(failure.isInformational)
        XCTAssertEqual(failure.displayMessage, failure.code.message)
        XCTAssertFalse(failure.displayMessage.contains("LA3006"))
        XCTAssertTrue(failure.localizedDescription.contains("LA3006"))
        XCTAssertTrue(failure.localizedDescription.contains("exit 86"))
        XCTAssertFalse(failure.suggestsPowerRecovery)
        let genuineFailure = AppFailure(code: .powerRestore, detail: "diagnostic")
        XCTAssertFalse(genuineFailure.isInformational)
        XCTAssertEqual(genuineFailure.displayMessage, genuineFailure.localizedDescription)
    }
    func testUninstallStagesAndCancellationDoNotSuggestPowerRecovery() {
        for code in [FailureCode.runtimeRemoval, .loginRemoval, .uninstallPending, .invalidTarget, .authorizationCancelled, .authorizationFailed] {
            XCTAssertFalse(AppFailure(code: code).suggestsPowerRecovery)
        }
        for code in [FailureCode.powerRestore, .powerUnknown, .runtimeUnavailable] {
            XCTAssertTrue(AppFailure(code: code).suggestsPowerRecovery)
        }
    }
    func testStableCodeIsIndependentOfDiagnosticWording() {
        for detail in ["日本語", "localized OS error", ""] {
            let failure = AppFailure(code: .uninstallPending, detail: detail)
            XCTAssertEqual(failure.code.rawValue, "LA4003")
            XCTAssertTrue(failure.localizedDescription.contains("LA4003"))
            XCTAssertFalse(failure.suggestsPowerRecovery)
        }
        XCTAssertEqual(FailureCode.runtimeExit(80), .powerRestore)
        XCTAssertEqual(FailureCode.runtimeExit(82), .authorizationCancelled)
        XCTAssertEqual(FailureCode.runtimeExit(83), .runtimeRemoval)
        XCTAssertEqual(FailureCode.runtimeExit(7), .unexpected)
    }
}
