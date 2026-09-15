import AppKit
import Combine
import Foundation
import ServiceManagement
import CoreGraphics
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if preferences != oldValue { preferences.save(to: preferencesStore) }
        }
    }
    @Published private(set) var installationFailure: AppFailure?
    var needsRepair: Bool { installationFailure != nil }
    @Published private(set) var needsRecovery = false
    @Published private(set) var isBusy = false
    @Published var isUninstallConfirmationPresented = false
    @Published var failure: AppFailure?
    // Keep the actual error, but let the current permission/installation sections
    // explain those conditions without a second, potentially stale message.
    var visibleFailure: AppFailure? {
        if failure?.code == .screenPermission { return nil }
        if needsRepair, failure?.code == .installation { return nil }
        return failure
    }
    @Published private(set) var needsAccessibilityPermission = !CGPreflightPostEventAccess()
    @Published private(set) var loginItemIssue: String?
    private(set) var didFinishUninstallHandoff = false
    @Published private(set) var uninstallStage: UninstallProgress.Stage?
    var isUninstallPending: Bool { uninstallStage != nil }
    var isReadyForFinder: Bool { uninstallStage == .readyForFinder }
    private let uninstallProgress: UninstallProgress
    private let uninstaller: UninstallSystemActions
    private let preferencesStore: UserDefaults
    private let runtime: RuntimeClient
    private let hotKey: GlobalHotKey
    private let monitorSystemEvents: Bool
    private var didStartBackgroundServices = false
    private var isRefreshing = false
    private let lockedSession: ScreenLockSession
    private let lidDisplaySleep: LidDisplaySleep
    private let playStartSound: () -> Void
    private var screenMonitor: Task<Void, Never>?
    private var unlockObserver: NSObjectProtocol?

    init(runtime: RuntimeClient = .live, preferencesStore: UserDefaults = .standard,
         lockedSession: ScreenLockSession? = nil, lidDisplaySleep: LidDisplaySleep? = nil,
         monitorSystemEvents: Bool = true, uninstallProgress: UninstallProgress = .init(),
         uninstaller: UninstallSystemActions? = nil, hotKey: GlobalHotKey? = nil,
         playStartSound: @escaping () -> Void = {
             let sound = NSSound(named: NSSound.Name("Submarine"))
             sound?.volume = 0.5
             _ = sound?.play()
         }) {
        self.playStartSound = playStartSound
        self.hotKey = hotKey ?? GlobalHotKey()
        self.monitorSystemEvents = monitorSystemEvents
        self.uninstallProgress = uninstallProgress
        self.uninstaller = uninstaller ?? UninstallSystemActions()
        self.uninstallStage = uninstallProgress.load()
        self.runtime = runtime
        self.preferencesStore = preferencesStore
        self.preferences = Preferences.load(from: preferencesStore)
        self.lockedSession = lockedSession ?? ScreenLockSession()
        self.lidDisplaySleep = lidDisplaySleep ?? LidDisplaySleep()
    }

    /// Called once at will-finish-launching, before menus, windows or login-item checks.
    /// Constructing a model or opening/closing settings never starts another listener.
    func startBackgroundServices() {
        guard !didStartBackgroundServices else { return }
        didStartBackgroundServices = true
        hotKey.onPress = { [weak self] in
            try? await self?.perform(.start)
        }
        do {
            try hotKey.setSuspended(isUninstallPending, for: .uninstalling)
            if !isUninstallPending {
                try hotKey.setKey(preferences.hotKey)
                Logger(subsystem: AppIdentity.bundleIdentifier, category: "startup")
                    .info("Shortcut initialization complete; assigned=\(self.preferences.hotKey != nil)")
            }
        }
        catch {
            Logger(subsystem: AppIdentity.bundleIdentifier, category: "startup").error("Shortcut registration failed")
            failure = AppFailure.normalize(error, fallback: .shortcut)
        }
        guard monitorSystemEvents else { return }
        // This notification is an implementation detail, so polling also checks
        // the state. Never treat app activation or display wake as screen unlock.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lockedSession.didUnlock()
                await self?.monitorSession()
            }
        }
        // Independent of the settings window, which may be closed while locked.
        screenMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                await self?.monitorSession()
            }
        }
    }

    deinit {
        screenMonitor?.cancel()
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
    }

    func monitorSession() async {
        // Latch unlocks even while an operation is in progress.
        lockedSession.observe(lockedSession.readState())
        if !didFinishUninstallHandoff, lockedSession.needsStop, !isBusy {
            // runOperation records the error; the session retains the stop request.
            try? await runOperation(fallback: .powerRestore) {
                try await self.restoreSleep(.stop)
            }
        }
        // The awaited stop/refresh may have allowed another operation to start.
        guard !didFinishUninstallHandoff, !isBusy else { return }
        do {
            try lidDisplaySleep.update(sessionActive: lockedSession.phase == .locked,
                                       screenState: lockedSession.readState())
        } catch {
            // Keep the locked session and its existing time/battery safeguards.
            // Report through the normal app error state without opening a window.
            failure = AppFailure.normalize(error, fallback: .displaySleep)
        }
    }

    func openAccessibilitySettings() {
        // These deep links are provided by System Settings and may change with macOS.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            failure = AppFailure(code: .unexpected, detail: L10n.text("設定画面を開けませんでした。システム設定 → プライバシーとセキュリティ → アクセシビリティを開いてください。"))
            return
        }
    }

    func refreshAccessibilityPermission() {
        // Read-only: opening or refreshing settings must never request permission.
        needsAccessibilityPermission = !CGPreflightPostEventAccess()
    }

    func setEditingHotKey(_ editing: Bool) {
        guard didStartBackgroundServices else { return }
        do { try hotKey.setSuspended(editing, for: .editing) }
        catch { failure = AppFailure.normalize(error, fallback: .shortcut) }
    }

    func setHotKey(_ key: HotKey?) throws {
        guard !isBusy, !isUninstallPending else { throw AppFailure(code: .busy) }
        if didStartBackgroundServices { try hotKey.setKey(key) }
        preferences.hotKey = key
        failure = nil
    }

    // All entry points report failures once. App termination also needs the
    // thrown error so it can keep the app running if sleep cannot be restored.
    func perform(_ action: SessionAction) async throws {
        if isUninstallPending, case .start = action {
            throw AppFailure(code: .uninstallPending)
        }
        try await runOperation {
            switch action {
            case .start: try await self.start()
            case .stop: try await self.restoreSleep(.stop)
            }
        }
    }

    func refresh() async {
        refreshAccessibilityPermission()
        guard !isBusy, !isRefreshing, !didFinishUninstallHandoff else { return }
        refreshLoginItemStatus()
        isRefreshing = true
        defer { isRefreshing = false }
        await updateInstallationDiagnosis()
    }

    private func updateInstallationDiagnosis() async {
        guard !isUninstallPending else { return }
        let diagnosis: AppFailure?
        do {
            try await runtime.checkInstallation()
            diagnosis = nil
        } catch { diagnosis = AppFailure.normalize(error, fallback: .installation) }
        // A check started before uninstall may finish after runtime removal.
        guard !isUninstallPending else { return }
        installationFailure = diagnosis
    }

    /// Normal async operations share the gate/reporting with the modal quit path.
    /// Recovery decisions stay with the operation that knows whether it restored sleep.
    private func runOperation(fallback: FailureCode = .unexpected,
                              _ operation: () async throws -> Void) async throws {
        try beginOperation()
        var operationFailure: AppFailure?
        do {
            try await operation()
        } catch {
            operationFailure = AppFailure.normalize(error, fallback: fallback)
        }
        // Publish before yielding to diagnostic I/O. A newer operation may run
        // during refresh; never overwrite its result when this call resumes.
        finishOperation(operationFailure)
        if !didFinishUninstallHandoff { await refresh() }
        if let operationFailure { throw operationFailure }
    }

    private func beginOperation() throws {
        // Rejected calls must not modify the active operation's state.
        guard !isBusy, !didFinishUninstallHandoff else { throw AppFailure(code: .busy) }
        isBusy = true
        failure = nil
    }

    private func finishOperation(_ operationFailure: AppFailure?) {
        isBusy = false
        if let operationFailure { failure = operationFailure }
    }

    /// Claim the operation synchronously before AppKit enters its modal quit loop.
    /// MainActor Tasks cannot be relied on to progress inside that nested loop.
    func prepareToTerminate(reply: @escaping @MainActor (Bool) -> Void) -> Bool {
        do { try beginOperation() }
        catch { return false }
        let runtime = self.runtime
        Task.detached {
            let result: Result<Void, Error>
            do { try await runtime.perform(.stop); result = .success(()) }
            catch { result = .failure(error) }
            // Deliver directly on the main run loop, including AppKit's quit mode.
            // Do not enqueue another MainActor Task here.
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated {
                    var operationFailure: AppFailure?
                    do { try self.finishRestoringSleep(result) }
                    catch { operationFailure = AppFailure.normalize(error, fallback: .powerRestore) }
                    self.finishOperation(operationFailure)
                    // No diagnostic await or other yield between restoration and reply.
                    reply(operationFailure == nil)
                }
            }
        }
        return true
    }

    private func didRestoreSleep() {
        lockedSession.didStop()
        lidDisplaySleep.reset()
        needsRecovery = false
    }

    func retryStop() async {
        guard !isBusy else { return }
        try? await runOperation(fallback: .powerRestore) {
            try await self.restoreSleep(.recover)
        }
    }

    private func saveUninstallStage(_ stage: UninstallProgress.Stage) throws {
        do { try uninstallProgress.save(stage) }
        catch { throw AppFailure(code: .runtimeRemoval, detail: L10n.text("削除の進行状況を保存できません。\n%@", error.localizedDescription)) }
        uninstallStage = stage
        installationFailure = nil
        loginItemIssue = nil
        try hotKey.setSuspended(true, for: .uninstalling)
    }

    private func start() async throws {
        let snapshot = preferences
        lidDisplaySleep.reset()
        await updateInstallationDiagnosis()
        if let installationFailure { throw installationFailure }
        // Do not intercept the system's ⌃⌘Q if it is also the user's start key.
        try hotKey.setSuspended(true, for: .locking)
        defer {
            do { try hotKey.setSuspended(false, for: .locking) }
            catch { failure = AppFailure.normalize(error, fallback: .shortcut) }
        }
        let lockOnlyReason = try await lockedSession.start(
            enable: { try await self.runtime.perform(.start(snapshot)) },
            restore: { try await self.restoreSleep(.stop) })
        if let lockOnlyReason, failure == nil { failure = lockOnlyReason }
        needsRecovery = false
        // Playback is best-effort feedback, not part of the power/lock transaction.
        if lockOnlyReason == nil { playStartSound() }
    }

    private func restoreSleep(_ action: RuntimeClient.Action) async throws {
        let result: Result<Void, Error>
        do { try await runtime.perform(action); result = .success(()) }
        catch { result = .failure(error) }
        try finishRestoringSleep(result)
    }

    private func finishRestoringSleep(_ result: Result<Void, Error>) throws {
        do {
            try result.get()
            didRestoreSleep()
        } catch {
            // A failed stop has not confirmed restoration, regardless of its exit code.
            needsRecovery = true
            throw error
        }
    }

    func requestUninstall() {
        guard !isBusy, !didFinishUninstallHandoff else { return }
        if isReadyForFinder { Task { await revealInFinderAndQuit() } }
        else { isUninstallConfirmationPresented = true }
    }

    func uninstall() async {
        guard !isBusy else { return }
        try? await runOperation(fallback: .runtimeRemoval) {
            do {
                try self.uninstaller.validateTarget()
                try self.saveUninstallStage(.cleaning)
                try await self.runtime.perform(.remove)
                // Update the confirmed power result before a later stage can fail.
                self.didRestoreSleep()
                try await self.uninstaller.removeLoginItem()
                try self.saveUninstallStage(.readyForFinder)
            } catch {
                self.needsRecovery = self.needsRecovery || self.lockedSession.needsStop
                    || AppFailure.normalize(error).suggestsPowerRecovery
                throw error
            }
        }
    }

    func registerLoginItem() {
        guard !isUninstallPending else { return }
        loginItemIssue = LoginStartup.registerIfNeeded(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() })
    }

    func revealInFinderAndQuit() async {
        guard isReadyForFinder, !isBusy else { return }
        try? await runOperation {
            // Saved UI progress never bypasses the live power check.
            try await self.restoreSleep(.stop)
            try self.uninstaller.reveal()
            self.didFinishUninstallHandoff = true
            self.screenMonitor?.cancel()
            self.uninstaller.terminate()
        }
    }

    func refreshLoginItemStatus() {
        guard !isUninstallPending else { return }
        // Preserve the actual registration failure until resolved.
        loginItemIssue = LoginStartup.issue(for: SMAppService.mainApp.status, previousIssue: loginItemIssue)
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
