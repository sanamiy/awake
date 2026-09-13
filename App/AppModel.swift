import AppKit
import Combine
import Foundation
import ServiceManagement
import CoreGraphics

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var preferences: Preferences {
        didSet {
            if preferences != oldValue { preferences.save(to: preferencesStore) }
        }
    }
    @Published private(set) var installationFailure: AppFailure?
    var needsRepair: Bool { installationFailure != nil }
    @Published private(set) var needsRecovery = false
    @Published private(set) var isBusy = false
    @Published var failure: AppFailure?
    @Published private(set) var needsAccessibilityPermission = !CGPreflightPostEventAccess()
    @Published private(set) var loginItemIssue: String?
    var showSettings: (() -> Void)?
    private(set) var didFinishUninstallHandoff = false
    @Published private(set) var uninstallStage: UninstallProgress.Stage?
    var isUninstallPending: Bool { uninstallStage != nil }
    var isReadyForFinder: Bool { uninstallStage == .readyForFinder }
    private let uninstallProgress: UninstallProgress
    private let uninstaller: AppUninstaller
    private let preferencesStore: UserDefaults
    private let runtime: RuntimeClient
    private let hotKey = GlobalHotKey()
    private var isRefreshing = false
    private let lockedSession: ScreenLockSession
    private let lidDisplaySleep: LidDisplaySleep
    private var screenMonitor: Task<Void, Never>?
    private var unlockObserver: NSObjectProtocol?
    private var didPresentAutomaticStopError = false

    init(runtime: RuntimeClient = .live, preferencesStore: UserDefaults = .standard,
         lockedSession: ScreenLockSession? = nil, lidDisplaySleep: LidDisplaySleep? = nil,
         monitorSystemEvents: Bool = true, uninstallProgress: UninstallProgress = .init(),
         uninstaller: AppUninstaller? = nil) {
        self.uninstallProgress = uninstallProgress
        self.uninstaller = uninstaller ?? AppUninstaller()
        self.uninstallStage = uninstallProgress.load()
        self.runtime = runtime
        self.preferencesStore = preferencesStore
        self.preferences = Preferences.load(from: preferencesStore)
        self.lockedSession = lockedSession ?? ScreenLockSession()
        self.lidDisplaySleep = lidDisplaySleep ?? LidDisplaySleep()
        if monitorSystemEvents { startMonitoring() }
    }

    private func startMonitoring() {
        hotKey.onPress = { [weak self] in
            try? await self?.perform(.start)
        }
        do {
            try hotKey.setSuspended(isUninstallPending, for: .uninstalling)
            if !isUninstallPending { try hotKey.setKey(preferences.hotKey) }
        }
        catch { failure = AppFailure.normalize(error, fallback: .shortcut) }
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
        let state = lockedSession.readState()
        lockedSession.observe(state)
        await stopAfterUnlockIfNeeded(screenState: state)
        sleepDisplaysAfterLidCloseIfNeeded()
    }

    private func stopAfterUnlockIfNeeded(screenState: ScreenLockState) async {
        guard !didFinishUninstallHandoff, lockedSession.needsStop, !isBusy else { return }
        do {
            try await runOperation { try await self.restoreSleep(.stop) }
            didPresentAutomaticStopError = false
        } catch {
            failure = AppFailure.normalize(error, fallback: .powerRestore)
            if !didPresentAutomaticStopError, screenState == .unlocked {
                didPresentAutomaticStopError = true
                showSettings?()
            }
        }
    }

    private func sleepDisplaysAfterLidCloseIfNeeded() {
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
        do { try hotKey.setSuspended(editing, for: .editing) }
        catch { failure = AppFailure.normalize(error, fallback: .shortcut) }
    }

    func setHotKey(_ key: HotKey?) throws {
        guard !isBusy, !isUninstallPending else { throw AppFailure(code: .busy) }
        try hotKey.setKey(key)
        preferences.hotKey = key
        failure = nil
    }

    private func present(_ error: Error) {
        refreshAccessibilityPermission()
        // The permission section already explains the next step. Avoid leaving
        // a duplicate error behind after the user grants access.
        let mapped = AppFailure.normalize(error)
        failure = (mapped.code == .screenPermission && needsAccessibilityPermission)
            || (needsRepair && mapped.code == .installation) ? nil : mapped
        showSettings?()
    }

    // All entry points report failures once. App termination also needs the
    // thrown error so it can keep the app running if sleep cannot be restored.
    func perform(_ action: SessionAction) async throws {
        if isUninstallPending, case .start = action {
            throw AppFailure(code: .uninstallPending)
        }
        do {
            try await runOperation {
                switch action {
                case .start: try await self.start()
                case .stop: try await self.restoreSleep(.stop)
                }
            }
        } catch {
            present(error)
            throw error
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

    /// Owns the busy lifetime and refresh for every mutating operation.
    /// Recovery decisions stay with the operation that knows whether it restored sleep.
    private func runOperation(_ operation: () async throws -> Void) async throws {
        guard !isBusy, !didFinishUninstallHandoff else { throw AppFailure(code: .busy) }
        isBusy = true
        failure = nil
        let result: Result<Void, Error>
        do {
            try await operation()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        isBusy = false
        if !didFinishUninstallHandoff { await refresh() }
        try result.get()
    }

    private func didRestoreSleep() {
        lockedSession.didStop()
        lidDisplaySleep.reset()
        needsRecovery = false
    }

    func retryStop() async {
        guard !isBusy else { return }
        do {
            try await runOperation {
                try await self.restoreSleep(.recover)
            }
        } catch { failure = AppFailure.normalize(error, fallback: .powerRestore) }
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
        didPresentAutomaticStopError = false
        await updateInstallationDiagnosis()
        if let installationFailure { throw installationFailure }
        // Do not intercept the system's ⌃⌘Q if it is also the user's start key.
        try hotKey.setSuspended(true, for: .locking)
        defer {
            do { try hotKey.setSuspended(false, for: .locking) }
            catch { failure = AppFailure.normalize(error, fallback: .shortcut) }
        }
        do {
            try await lockedSession.start(
                enable: { try await self.runtime.perform(.start(snapshot)) },
                restore: {
                    try await self.runtime.perform(.stop)
                    // ScreenLockSession resets its phase after this returns.
                    // Clear a recovery warning left by an earlier failed attempt too.
                    self.needsRecovery = false
                })
        } catch {
            // The start error may describe a broken CLI even after rollback
            // succeeded. Only an uncompleted rollback requires recovery here.
            needsRecovery = needsRecovery || lockedSession.needsStop
            throw error
        }
        needsRecovery = false
    }

    private func restoreSleep(_ action: RuntimeClient.Action) async throws {
        do {
            try await runtime.perform(action)
            didRestoreSleep()
        } catch {
            // A failed stop has not confirmed restoration, regardless of its exit code.
            needsRecovery = true
            throw error
        }
    }

    func uninstall() async {
        guard !isBusy else { return }
        do {
            try await runOperation {
                try self.uninstaller.validateTarget()
                try self.saveUninstallStage(.cleaning)
                try await self.runtime.perform(.remove)
                // Update the confirmed power result before a later stage can fail.
                self.didRestoreSleep()
                try await self.uninstaller.removeLoginItem()
                try self.saveUninstallStage(.readyForFinder)
            }
        } catch {
            needsRecovery = needsRecovery || lockedSession.needsStop
                || AppFailure.normalize(error).suggestsPowerRecovery
            present(AppFailure.normalize(error, fallback: .runtimeRemoval))
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
        do {
            try await runOperation {
                // Saved UI progress never bypasses the live power check.
                try await self.restoreSleep(.stop)
                try self.uninstaller.reveal()
                self.didFinishUninstallHandoff = true
                self.screenMonitor?.cancel()
                self.uninstaller.terminate()
            }
        } catch { present(error) }
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
