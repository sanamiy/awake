import XCTest
import AppKit

@MainActor
final class AppModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var runner: ModelRunner!
    private var runtime: RuntimeClient!
    private var session: ScreenLockSession!
    private var displaySleep: LidDisplaySleep!
    private var model: AppModel!
    private var application: TestApplicationBundle!
    private var uninstaller: AppUninstaller!
    private var failLoginRemoval = false
    private var lifecycleCalls: [String] = []

    override func setUpWithError() throws {
        suite = "LidAwakeModelTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        var preferences = Preferences()
        preferences.hotKey = nil
        preferences.save(to: defaults)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let files = try TestRuntimeFiles(directory: directory)
        runner = ModelRunner(progressURL: progress.url)
        runtime = files.client(runner: runner)
        session = ScreenLockSession()
        session.prepareLock = {}
        session.requestLock = {}
        session.pause = {}
        session.readState = { .locked }
        displaySleep = LidDisplaySleep()
        displaySleep.readPowerState = { .init(lidClosed: false, sleepDisabled: true) }
        displaySleep.requestDisplaySleep = { XCTFail("Unexpected display sleep") }
        application = try TestApplicationBundle()
        failLoginRemoval = false
        lifecycleCalls = []
        uninstaller = AppUninstaller(applicationURL: application.app,
            unregisterLoginItem: {
                self.lifecycleCalls.append("unregister")
                XCTAssertEqual(self.model.uninstallStage, .cleaning)
                XCTAssertFalse(self.model.needsRecovery)
                if self.failLoginRemoval { throw AppFailure(code: .unexpected, detail: "fixture login failure") }
            }, showInFinder: { urls in
                XCTAssertEqual(urls, [self.application.app])
                self.lifecycleCalls.append("finder")
            }, terminate: {
                XCTAssertTrue(self.model.didFinishUninstallHandoff)
                XCTAssertFalse(self.model.needsRecovery)
                self.lifecycleCalls.append("quit")
            })
        // No real commands, key registration, unlock observer, timer or saved preferences.
        model = makeModel()
    }

    override func tearDownWithError() throws {
        model = nil
        uninstaller = nil
        session = nil
        displaySleep = nil
        application?.cleanUp()
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private var progress: UninstallProgress {
        .init(url: directory.appendingPathComponent("uninstall-state"))
    }

    // The same isolated dependencies are used on first launch and every reopen.
    private func makeModel(progress: UninstallProgress? = nil) -> AppModel {
        AppModel(runtime: runtime, preferencesStore: defaults, lockedSession: session, lidDisplaySleep: displaySleep,
            monitorSystemEvents: false, uninstallProgress: progress ?? self.progress, uninstaller: uninstaller)
    }

    // MARK: - Session lifecycle and recovery

    func testStartAndStopUpdateSessionAndReleaseBusyState() async throws {
        session.prepareLock = { XCTAssertTrue(self.model.isBusy) }
        try await model.perform(.start)
        XCTAssertEqual(session.phase, .locked)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.needsRecovery)
        try await model.perform(.stop)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.failure)
    }

    func testSessionMonitorSleepsDisplayOnlyAfterSuccessfulStartAndLidClose() async throws {
        var requests = 0
        displaySleep.readPowerState = { .init(lidClosed: true, sleepDisabled: true) }
        displaySleep.requestDisplaySleep = { requests += 1 }
        await model.monitorSession()
        XCTAssertEqual(requests, 0)
        try await model.perform(.start)
        await model.monitorSession()
        await model.monitorSession()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(session.phase, .locked)
        session.readState = { .unlocked }
        await model.monitorSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.needsRecovery)
    }

    func testDisplaySleepFailureKeepsLockedSessionAndReportsDiagnostic() async throws {
        displaySleep.readPowerState = { .init(lidClosed: true, sleepDisabled: true) }
        displaySleep.requestDisplaySleep = { throw AppFailure(code: .displaySleep) }
        try await model.perform(.start)
        await model.monitorSession()
        XCTAssertEqual(model.failure?.code, .displaySleep)
        XCTAssertEqual(session.phase, .locked)
        XCTAssertFalse(model.needsRecovery)
    }

    func testInstallationFailureBlocksStartAndRetainsDiagnosis() async throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("installed-cli"))
        await expectFailure(.start, .installation)
        XCTAssertTrue(model.needsRepair)
        XCTAssertTrue(model.installationFailure?.detail?.contains("内部CLI") == true)
        XCTAssertNil(model.failure, "The installation section already displays this failure")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
        let calls = await runner.actions
        XCTAssertTrue(calls.isEmpty)
    }

    func testLockFailureRollsBackWithoutLeavingRecoveryState() async {
        session.requestLock = { throw AppFailure(code: .screenLock) }
        await expectFailure(.start, .screenLock)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
        let calls = await runner.actions
        XCTAssertEqual(calls, ["_start", "stop"])
    }

    func testRollbackFailureRemainsPendingUntilExplicitRecoverySucceeds() async {
        session.requestLock = { throw AppFailure(code: .screenLock) }
        await runner.setExit(80, for: "stop")
        await expectFailure(.start, .powerRestore)
        XCTAssertEqual(session.phase, .needsStop)
        XCTAssertTrue(model.needsRecovery)
        await model.retryStop()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.failure)
    }

    func testSuccessfulRollbackOnRetryClearsAnEarlierRecoveryWarning() async {
        session.requestLock = { throw AppFailure(code: .screenLock) }
        await runner.setExit(80, for: "stop")
        await expectFailure(.start, .powerRestore)
        XCTAssertTrue(model.needsRecovery)
        await runner.setExit(0, for: "stop")
        await expectFailure(.start, .screenLock)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery, "Verified rollback must also clear a previous attempt's warning")
    }

    func testStopFailureAndCancelledRecoveryKeepRecoveryAvailable() async throws {
        try await model.perform(.start)
        await runner.setExit(80, for: "stop")
        await expectFailure(.stop, .powerRestore)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertFalse(model.isBusy)
        await runner.setExit(82, for: "recover")
        await model.retryStop()
        XCTAssertEqual(model.failure?.code, .authorizationCancelled)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertFalse(model.isBusy)
        await runner.setExit(0, for: "stop")
        try await model.perform(.stop)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
    }

    func testFailedStartWithSuccessfulRollbackDoesNotSuggestRecovery() async {
        await runner.setExit(86, for: "_start")
        await expectFailure(.start, .batteryLow)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(session.phase, .idle)
    }

    func testUnavailableStartCLIWithVerifiedRollbackDoesNotSuggestRecovery() async {
        await runner.setExit(127, for: "_start")
        await expectFailure(.start, .runtimeUnavailable)
        XCTAssertFalse(model.needsRecovery, "Successful rollback takes precedence over the original start error")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.failure?.localizedDescription.contains("停止を再試行") ?? true,
                       "Do not instruct the user to use a recovery button that is not shown")
    }

    func testDiagnosisDoesNotOverwriteAnOperationFailure() async throws {
        await runner.setExit(80, for: "stop")
        await expectFailure(.stop, .powerRestore)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("recover.plist"))
        await model.refresh()
        XCTAssertEqual(model.failure?.code, .powerRestore)
        XCTAssertTrue(model.needsRepair)
        XCTAssertTrue(model.installationFailure?.detail?.contains("LaunchAgent") == true)
    }

    func testUnexpectedStopFailureStillAllowsRetry() async throws {
        try await model.perform(.start)
        await runner.setExit(1, for: "stop")
        await expectFailure(.stop, .unexpected)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertFalse(model.isBusy)
        await model.retryStop()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
    }

    func testMissingStopCLIIsReportedRatherThanTreatedAsSuccessfulRestoration() async {
        await runner.setExit(127, for: "stop")
        await expectFailure(.stop, .runtimeUnavailable)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertFalse(model.isBusy)
    }

    func testAnotherOperationIsRejectedWhileWaitingForScreenLock() async throws {
        var state = ScreenLockState.unlocked
        session.readState = { state }
        session.pause = {
            XCTAssertTrue(self.model.isBusy)
            do { try await self.model.perform(.stop); XCTFail("Concurrent stop must not run") }
            catch { XCTAssertEqual((error as? AppFailure)?.code, .busy) }
            XCTAssertTrue(self.model.isBusy, "Rejected operation must not release the owner's busy flag")
            state = .locked
        }
        try await model.perform(.start)
        XCTAssertEqual(session.phase, .locked)
        XCTAssertFalse(model.isBusy)
        let calls = await runner.actions
        XCTAssertEqual(calls, ["_start"])
    }

    private func expectFailure(_ action: SessionAction, _ code: FailureCode, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await model.perform(action); XCTFail("Operation should fail", file: file, line: line) }
        catch { XCTAssertEqual((error as? AppFailure)?.code, code, file: file, line: line) }
        XCTAssertFalse(model.isBusy, file: file, line: line)
    }

    // MARK: - Uninstall and persisted progress

    func testPartialUninstallSuppressesRepairAndLoginRegistrationGuidance() async throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("installed-cli"))
        await model.refresh()
        XCTAssertTrue(model.needsRepair)
        failLoginRemoval = true
        await model.uninstall()
        await model.refresh()
        model.refreshLoginItemStatus()
        model.registerLoginItem() // Must return without invoking the live service.
        XCTAssertTrue(model.isUninstallPending)
        XCTAssertFalse(model.didFinishUninstallHandoff)
        XCTAssertFalse(model.needsRepair)
        XCTAssertNil(model.loginItemIssue)
        XCTAssertEqual(model.failure?.code, .loginRemoval)
        XCTAssertFalse(model.needsRecovery)
    }

    func testPartialUninstallPreventsRestartAndRechecksPowerBeforeQuit() async throws {
        failLoginRemoval = true
        await model.uninstall()
        do {
            try await model.perform(.start)
            XCTFail("A partially uninstalled app cannot start")
        } catch { XCTAssertEqual((error as? AppFailure)?.code, .uninstallPending) }
        try await model.perform(.stop)
        await model.monitorSession()
        let calls = await runner.actions
        XCTAssertEqual(calls, ["remove", "stop"])
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
    }

    func testReopeningDuringUninstallSuppressesRegistrationButDoesNotTrustSavedPowerState() async throws {
        for stage in [UninstallProgress.Stage.cleaning, .readyForFinder] {
            await runner.reset()
            try progress.save(stage)
            model = makeModel()
            XCTAssertTrue(model.isUninstallPending)
            XCTAssertEqual(model.isReadyForFinder, stage == .readyForFinder)
            model.registerLoginItem() // Must not call the real service.
            model.refreshLoginItemStatus()
            await model.refresh()
            XCTAssertNil(model.loginItemIssue)
            XCTAssertFalse(model.needsRepair)
            await expectFailure(.start, .uninstallPending)
            await runner.setExit(80, for: "stop")
            do {
                try await model.perform(.stop)
                XCTFail("Saved progress must not bypass a failed power check")
            } catch { XCTAssertEqual((error as? AppFailure)?.code, .powerRestore) }
            XCTAssertTrue(model.needsRecovery)
            XCTAssertFalse(model.didFinishUninstallHandoff)
            if stage == .readyForFinder {
                // The failed check must prevent both Finder and NSApp.terminate.
                await model.revealInFinderAndQuit()
                XCTAssertEqual(model.failure?.code, .powerRestore)
                XCTAssertTrue(model.needsRecovery)
                XCTAssertFalse(model.didFinishUninstallHandoff)
                XCTAssertEqual(progress.load(), .readyForFinder)
            }
        }
    }

    func testUninstallEntryPointPersistsProgressAndHandsOffOnlyAfterAnotherPowerCheck() async throws {
        await model.uninstall()
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.isReadyForFinder)
        XCTAssertEqual(progress.load(), .readyForFinder)
        XCTAssertEqual(lifecycleCalls, ["unregister"])
        XCTAssertFalse(model.didFinishUninstallHandoff)
        await model.revealInFinderAndQuit()
        let actions = await runner.actions
        XCTAssertEqual(actions, ["remove", "stop"])
        XCTAssertEqual(lifecycleCalls, ["unregister", "finder", "quit"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: application.app.path))
        let delegate = AppDelegate(model: model)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        await model.uninstall()
        XCTAssertEqual(lifecycleCalls, ["unregister", "finder", "quit"], "No duplicate handoff or cleanup")
    }

    func testLoginRemovalFailureResumesThroughTheRealEntryPoint() async {
        failLoginRemoval = true
        await model.uninstall()
        XCTAssertEqual(model.failure?.code, .loginRemoval)
        XCTAssertEqual(model.uninstallStage, .cleaning)
        failLoginRemoval = false
        await model.uninstall()
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.isReadyForFinder)
        XCTAssertEqual(lifecycleCalls, ["unregister", "unregister"])
        let actions = await runner.actions
        XCTAssertEqual(actions, ["remove", "remove"])
    }

    func testRuntimeRemovalFailureNeverUnregistersOrReportsReady() async {
        let cases: [(Int32, FailureCode)] = [
            (80, .powerRestore), (81, .powerUnknown), (82, .authorizationCancelled),
            (83, .runtimeRemoval), (85, .foreignSession)
        ]
        for (code, expected) in cases {
            model = makeModel()
            await runner.reset()
            await runner.setExit(code, for: "remove")
            await model.uninstall()
            XCTAssertEqual(model.failure?.code, expected, "exit \(code)")
            XCTAssertEqual(model.needsRecovery, [80, 81].contains(code), "exit \(code)")
            XCTAssertEqual(model.uninstallStage, .cleaning)
            XCTAssertTrue(lifecycleCalls.isEmpty)
            XCTAssertFalse(model.didFinishUninstallHandoff)
        }
    }

    func testProgressWriteFailurePreventsAnyCleanup() async throws {
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        model = makeModel(progress: .init(url: blocked.appendingPathComponent("progress")))
        await model.uninstall()
        XCTAssertEqual(model.failure?.code, .runtimeRemoval)
        XCTAssertFalse(model.isUninstallPending)
        let actions = await runner.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(lifecycleCalls.isEmpty)
    }

    func testFinalProgressWriteFailureDoesNotReportReadyAndCanBeRetried() async throws {
        let progressURL = directory.appendingPathComponent("uninstall-state")
        uninstaller.unregisterLoginItem = {
            self.lifecycleCalls.append("unregister")
            try FileManager.default.removeItem(at: progressURL)
            try FileManager.default.createDirectory(at: progressURL, withIntermediateDirectories: false)
        }
        model = makeModel()
        await model.uninstall()
        XCTAssertEqual(model.failure?.code, .runtimeRemoval)
        XCTAssertEqual(model.uninstallStage, .cleaning)
        XCTAssertFalse(model.needsRecovery)
        await model.revealInFinderAndQuit()
        XCTAssertEqual(lifecycleCalls, ["unregister"])
        XCTAssertEqual(UninstallProgress(url: progressURL).load(), .cleaning)
        // Repair only the test fixture, then retry the real workflow after reopen.
        try FileManager.default.removeItem(at: progressURL)
        try UninstallProgress(url: progressURL).save(.cleaning)
        uninstaller.unregisterLoginItem = { self.lifecycleCalls.append("unregister") }
        model = makeModel()
        await model.uninstall()
        XCTAssertTrue(model.isReadyForFinder)
        XCTAssertNil(model.failure)
    }

    func testInvalidBundlePreventsProgressWriteAndCleanup() async {
        uninstaller.applicationURL = directory
        model = makeModel()
        await model.uninstall()
        XCTAssertEqual(model.failure?.code, .invalidTarget)
        XCTAssertFalse(model.isUninstallPending)
        let actions = await runner.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(lifecycleCalls.isEmpty)
    }
}

private actor ModelRunner: CommandRunning {
    private let progressURL: URL
    init(progressURL: URL) { self.progressURL = progressURL }
    private var exitCodes: [String: Int32] = [:]
    private(set) var actions: [String] = []

    func setExit(_ code: Int32, for action: String) { exitCodes[action] = code }
    func reset() { exitCodes = [:]; actions = [] }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        if executable.path == "/usr/bin/sudo" || executable.path == "/bin/launchctl" {
            return CommandResult(code: 0, text: "fixture registration")
        }
        guard executable.path == "/bin/zsh", arguments.count >= 3 else {
            XCTFail("Unexpected model command: \(executable.path)")
            throw AppFailure(code: .unexpected)
        }
        let runtimeAction: String
        switch (URL(fileURLWithPath: arguments[2]).lastPathComponent, arguments.dropFirst(3).first) {
        case ("uninstall.sh", nil):
            runtimeAction = "remove"
            // Shared ordering invariant: removal may only begin after saving intent.
            XCTAssertEqual(UninstallProgress(url: progressURL).load(), .cleaning)
        case ("lid-awake", let action?) where ["_start", "stop", "recover"].contains(action):
            runtimeAction = action
        default:
            XCTFail("Unexpected model runtime arguments: \(arguments)")
            throw AppFailure(code: .unexpected)
        }
        actions.append(runtimeAction)
        return CommandResult(code: exitCodes[runtimeAction] ?? 0, text: "fixture \(runtimeAction)")
    }
}
