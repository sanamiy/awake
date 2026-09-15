import XCTest
import AppKit

@MainActor
final class AppModelTests: AppModelTestCase {
    func testUnlimitedSessionStillStopsAfterUnlock() async throws {
        model.preferences.unlimitedDuration = true
        try await model.perform(.start)
        XCTAssertEqual(session.phase, .locked)
        session.readState = { .unlocked }
        await model.monitorSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
        let actions = await runner.actions
        XCTAssertEqual(actions, ["_start", "stop"])
    }
    func testTerminationClaimsOperationImmediatelyAndReportsRestorationResult() async throws {
        for exitCode: Int32 in [0, 80] {
            model = makeModel()
            await runner.reset()
            try await model.perform(.start)
            await runner.setExit(exitCode, for: "stop")
            let response = expectation(description: "Termination response \(exitCode)")
            XCTAssertTrue(model.prepareToTerminate { shouldTerminate in
                XCTAssertEqual(shouldTerminate, exitCode == 0)
                XCTAssertFalse(self.model.isBusy)
                XCTAssertEqual(self.model.needsRecovery, exitCode != 0)
                XCTAssertEqual(self.model.failure?.code, exitCode == 0 ? nil : .powerRestore)
                XCTAssertEqual(self.session.phase, exitCode == 0 ? .idle : .locked)
                response.fulfill()
            })
            XCTAssertTrue(model.isBusy, "Claim the operation before returning to AppKit")
            XCTAssertFalse(model.prepareToTerminate { _ in XCTFail("Duplicate quit must be rejected") })
            XCTAssertThrowsError(try model.setHotKey(.standard)) {
                XCTAssertEqual(($0 as? AppFailure)?.code, .busy)
            }
            await fulfillment(of: [response], timeout: 2)
            let actions = await runner.actions
            XCTAssertEqual(actions, ["_start", "stop"])
        }
    }

    func testBackgroundStartupKeepsRegistrationFailureAndSkipsUninstallingApp() throws {
        for stage in [nil, UninstallProgress.Stage.cleaning, .readyForFinder] {
            if let stage { try progress.save(stage) }
            var attempts = 0
            let hotKey = GlobalHotKey(register: { _, _ in
                attempts += 1
                throw AppFailure(code: .shortcut)
            })
            Preferences().save(to: defaults)
            model = makeModel(hotKey: hotKey)
            model.startBackgroundServices()
            model.startBackgroundServices()
            XCTAssertEqual(attempts, stage == nil ? 1 : 0)
            XCTAssertEqual(model.failure?.code, stage == nil ? .shortcut : nil)
        }
    }

    // MARK: - Session lifecycle and recovery

    func testStartAndStopUpdateSessionAndReleaseBusyState() async throws {
        XCTAssertEqual(startSoundCount, 0)
        session.requestLock = { XCTAssertEqual(self.startSoundCount, 0) }
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
        XCTAssertTrue(model.installationFailure?.detail?.contains(L10n.text("内部CLIが見つからないか、内容または実行権限が一致しません。")) == true)
        XCTAssertEqual(model.failure?.code, .installation, "Retain the actual operation failure")
        XCTAssertNil(model.visibleFailure, "The installation section already displays this failure")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)
        let calls = await runner.actions
        XCTAssertTrue(calls.isEmpty)
    }

    func testLockFailureRollsBackWithoutLeavingRecoveryState() async {
        defer { XCTAssertEqual(startSoundCount, 0) }
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
        defer { XCTAssertEqual(startSoundCount, 0) }
        await runner.setExit(87, for: "_start")
        await expectFailure(.start, .powerStart)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(session.phase, .idle)
    }

    func testUnavailableStartCLIWithVerifiedRollbackDoesNotSuggestRecovery() async {
        await runner.setExit(127, for: "_start")
        await expectFailure(.start, .runtimeUnavailable)
        XCTAssertFalse(model.needsRecovery, "Successful rollback takes precedence over the original start error")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.failure?.localizedDescription.contains(L10n.text("停止を再試行")) ?? true,
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
            XCTAssertNil(self.model.failure, "Rejected operation must not overwrite the owner's result")
            state = .locked
        }
        try await model.perform(.start)
        XCTAssertEqual(session.phase, .locked)
        XCTAssertFalse(model.isBusy)
        let calls = await runner.actions
        XCTAssertEqual(calls, ["_start"])
    }

    func testEarlierFailureCannotOverwriteNewerRecoveryResultDuringRefresh() async {
        for nextExit: Int32 in [0, 85] {
            model = makeModel()
            await runner.reset()
            await runner.setExit(80, for: "stop")
            await runner.onNextRegistrationCheck {
                XCTAssertFalse(self.model.isBusy)
                XCTAssertEqual(self.model.failure?.code, .powerRestore)
                await self.runner.setExit(nextExit, for: "recover")
                await self.model.retryStop()
            }
            // The first caller still receives its own error after diagnostic I/O.
            await expectFailure(.stop, .powerRestore)
            XCTAssertEqual(model.failure?.code, nextExit == 0 ? nil : .foreignSession)
            XCTAssertEqual(model.needsRecovery, nextExit != 0)
            let actions = await runner.actions
            XCTAssertEqual(actions, ["stop", "recover"])
        }
    }

    func testPermissionFailureBeforeStartDoesNotClearEarlierRecoveryWarning() async {
        await runner.setExit(80, for: "stop")
        await expectFailure(.stop, .powerRestore)
        session.prepareLock = { throw AppFailure(code: .screenPermission) }
        await expectFailure(.start, .screenPermission)
        XCTAssertEqual(model.failure?.code, .screenPermission)
        XCTAssertNil(model.visibleFailure, "Permission guidance owns the current permission state")
        XCTAssertTrue(model.needsRecovery)
        let actions = await runner.actions
        XCTAssertEqual(actions, ["stop"], "No enable or rollback before permission is obtained")
    }

    private func expectFailure(_ action: SessionAction, _ code: FailureCode, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await model.perform(action); XCTFail("Operation should fail", file: file, line: line) }
        catch { XCTAssertEqual((error as? AppFailure)?.code, code, file: file, line: line) }
        XCTAssertFalse(model.isBusy, file: file, line: line)
    }

    func testBatteryCutoffIsSuccessfulLockOnlyWithoutAutomaticRestart() async throws {
        await runner.setExit(86, for: "_start")
        var locks = 0
        session.requestLock = { locks += 1 }
        try await model.perform(.start)
        XCTAssertEqual(locks, 1)
        XCTAssertEqual(startSoundCount, 0)
        XCTAssertEqual(model.failure?.code, .batteryLow)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(session.phase, .idle)
        let actions = await runner.actions
        XCTAssertEqual(actions, ["_start", "stop"])
        await runner.setExit(0, for: "_start")
        await model.monitorSession()
        let afterCharging = await runner.actions
        XCTAssertEqual(afterCharging, actions)
        try await model.perform(.start)
        XCTAssertEqual(session.phase, .locked)
        XCTAssertNil(model.failure)
        XCTAssertEqual(startSoundCount, 1)
    }

    // MARK: - Uninstall and persisted progress

    func testUninstallRequestOnlyShowsConfirmationAndCanBeCancelled() async throws {
        model.requestUninstall()
        XCTAssertTrue(model.isUninstallConfirmationPresented)
        let actions = await runner.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(model.isUninstallPending)
        model.isUninstallConfirmationPresented = false
        XCTAssertNil(progress.load())
        session.requestLock = {
            self.model.requestUninstall()
            XCTAssertFalse(self.model.isUninstallConfirmationPresented)
        }
        try await model.perform(.start)
    }

    func testPartialUninstallSuppressesRepairAndBackgroundRegistrationGuidance() async throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("installed-cli"))
        await model.refresh()
        XCTAssertTrue(model.needsRepair)
        failBackgroundRemoval = true
        await model.uninstall()
        await model.revealInFinderAndQuit()
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
        failBackgroundRemoval = true
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

    func testBackgroundRemovalFailureCanBeRetriedBeforeFinderHandoff() async {
        failBackgroundRemoval = true
        await model.uninstall()
        await model.revealInFinderAndQuit()
        XCTAssertEqual(model.failure?.code, .loginRemoval)
        XCTAssertEqual(model.uninstallStage, .cleaning)
        failBackgroundRemoval = false
        await model.uninstall()
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.isReadyForFinder)
        await model.revealInFinderAndQuit()
        XCTAssertEqual(lifecycleCalls, ["unregister", "unregister", "finder", "quit"])
        let actions = await runner.actions
        XCTAssertEqual(actions, ["remove", "remove", "stop"])
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

    func testCancelledUninstallPreservesEarlierRecoveryWarning() async {
        await runner.setExit(80, for: "stop")
        await expectFailure(.stop, .powerRestore)
        await runner.setExit(82, for: "remove")
        await model.uninstall()
        XCTAssertEqual(model.failure?.code, .authorizationCancelled)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertEqual(model.uninstallStage, .cleaning)
        XCTAssertTrue(lifecycleCalls.isEmpty)
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
        await runner.setCorruptProgressAfterRemoval(true)
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
        await runner.setCorruptProgressAfterRemoval(false)
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
