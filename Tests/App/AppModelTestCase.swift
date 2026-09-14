import XCTest

/// Shared isolated runtime and model fixtures. Contains no test methods.
@MainActor
class AppModelTestCase: XCTestCase {
    var directory: URL!
    var defaults: UserDefaults!
    var suite: String!
    var runner: ModelRunner!
    var runtime: RuntimeClient!
    var session: ScreenLockSession!
    var displaySleep: LidDisplaySleep!
    var model: AppModel!
    var application: TestApplicationBundle!
    var uninstaller: UninstallSystemActions!
    var failBackgroundRemoval = false
    var lifecycleCalls: [String] = []

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
        failBackgroundRemoval = false
        lifecycleCalls = []
        uninstaller = UninstallSystemActions(applicationURL: application.app,
            unregisterLoginItem: {
                self.lifecycleCalls.append("unregister")
                XCTAssertEqual(self.model.uninstallStage, .cleaning)
                XCTAssertFalse(self.model.needsRecovery)
                if self.failBackgroundRemoval { throw AppFailure(code: .loginRemoval) }
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

    var progress: UninstallProgress {
        .init(url: directory.appendingPathComponent("uninstall-state"))
    }

    // The same isolated dependencies are used on first launch and every reopen.
    func makeModel(progress: UninstallProgress? = nil, hotKey: GlobalHotKey? = nil) -> AppModel {
        AppModel(runtime: runtime, preferencesStore: defaults, lockedSession: session, lidDisplaySleep: displaySleep,
            monitorSystemEvents: false, uninstallProgress: progress ?? self.progress, uninstaller: uninstaller,
            hotKey: hotKey ?? GlobalHotKey(register: FakeHotKeyRegistry().register))
    }

}

actor ModelRunner: CommandRunning {
    private let progressURL: URL
    init(progressURL: URL) { self.progressURL = progressURL }
    private var exitCodes: [String: Int32] = [:]
    private(set) var actions: [String] = []
    private var corruptProgressAfterRemoval = false
    private var registrationCheck: (@MainActor () async -> Void)?
    func setCorruptProgressAfterRemoval(_ value: Bool) { corruptProgressAfterRemoval = value }
    func onNextRegistrationCheck(_ action: @escaping @MainActor () async -> Void) { registrationCheck = action }

    func setExit(_ code: Int32, for action: String) { exitCodes[action] = code }
    func reset() { exitCodes = [:]; actions = [] }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        if executable.path == "/usr/bin/sudo" || executable.path == "/bin/launchctl" {
            if let registrationCheck {
                self.registrationCheck = nil
                await registrationCheck()
            }
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
        if runtimeAction == "remove", corruptProgressAfterRemoval {
            try FileManager.default.removeItem(at: progressURL)
            try FileManager.default.createDirectory(at: progressURL, withIntermediateDirectories: false)
        }
        return CommandResult(code: exitCodes[runtimeAction] ?? 0, text: "fixture \(runtimeAction)")
    }
}
