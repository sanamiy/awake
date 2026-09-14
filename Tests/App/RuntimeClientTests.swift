import XCTest

final class RuntimeClientTests: XCTestCase {
    private var directory: URL!
    private var files: TestRuntimeFiles!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Awake tests \(UUID().uuidString)")
        files = try TestRuntimeFiles(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func client(_ runner: StubRunner) -> RuntimeClient {
        files.client(runner: runner)
    }

    func testActionsKeepPathsArgumentsAndAuthorizationSeparate() async throws {
        let runner = StubRunner(results: Array(repeating: CommandResult(code: 0, text: "ok"), count: 4))
        let runtime = client(runner)
        var preferences = Preferences()
        preferences.minutes = 45
        preferences.minimumBattery = 40
        for action: RuntimeClient.Action in [.start(preferences), .stop, .recover, .remove] {
            try await runtime.perform(action)
        }
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.executable.path), Array(repeating: "/bin/zsh", count: 4))
        XCTAssertEqual(calls.map(\.arguments), [
            ["-f", "--", files.bundledCLI.path, "_start", "--minutes", "45", "--min-battery", "40"],
            ["-f", "--", files.bundledCLI.path, "stop"],
            ["-f", "--", files.bundledCLI.path, "recover"],
            ["-f", "--", files.runtimeDirectory.appendingPathComponent("uninstall.sh").path]
        ])
        for call in calls.prefix(2) {
            XCTAssertEqual(call.environment, ["LID_AWAKE_NO_NOTIFY": "1"])
        }
        for call in calls.suffix(2) {
            XCTAssertEqual(call.environment, ["LID_AWAKE_NO_NOTIFY": "1", "LID_AWAKE_AUTHORIZER": files.authorizer.path])
        }
    }

    func testInvalidPreferencesNeverLaunchAProcess() async {
        let runner = StubRunner(results: [])
        var preferences = Preferences()
        preferences.minutes = -1
        do {
            try await client(runner).perform(.start(preferences))
            XCTFail("Invalid settings must not start the runtime")
        } catch {
            XCTAssertEqual((error as? AppFailure)?.code, .invalidInput)
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testEveryActionReportsCommandFailureIncludingEmptyOutput() async {
        for action: RuntimeClient.Action in [.start(Preferences()), .stop, .recover, .remove] {
            for output in ["permission denied", ""] {
                let runner = StubRunner(results: [CommandResult(code: 7, text: output)])
                do {
                    try await client(runner).perform(action)
                    XCTFail("Nonzero exit must throw")
                } catch {
                    let code: FailureCode
                    switch action {
                    case .stop, .recover: code = .unexpected
                    case .remove: code = .runtimeRemoval
                    case .start: code = .unexpected
                    }
                    XCTAssertEqual((error as? AppFailure)?.code, code)
                }
            }
        }
    }

    func testMissingOrOutdatedRuntimeRequiresSetupWithoutExecutingIt() async throws {
        let runner = StubRunner(results: [])
        try Data("old-runtime".utf8).write(to: files.installedCLI)
        await assertInstallationFailure(client(runner), component: L10n.text("内部CLIが見つからないか、内容または実行権限が一致しません。"))
        try FileManager.default.removeItem(at: files.installedCLI)
        await assertInstallationFailure(client(runner), component: L10n.text("内部CLIが見つからないか、内容または実行権限が一致しません。"))
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCurrentRuntimeChecksBothPermissionsWithoutPrompting() async throws {
        let runner = StubRunner(results: Array(repeating: CommandResult(code: 0, text: "allowed"), count: 3))
        try await client(runner).checkInstallation()
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.executable.path), ["/usr/bin/sudo", "/usr/bin/sudo", "/bin/launchctl"])
        XCTAssertEqual(calls.map(\.arguments), [
            ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
            ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["print", "gui/501/dev.lid-awake.recover"]
        ])
        XCTAssertTrue(calls.allSatisfy { $0.environment.isEmpty })
    }

    func testEitherMissingPermissionRequiresSetup() async throws {
        for codes: [Int32] in [[1], [0, 1]] {
            let runner = StubRunner(results: codes.map { CommandResult(code: $0, text: "") })
            await assertInstallationFailure(client(runner), component: L10n.text("電源制御権限（disablesleep %@）", String(codes.count - 1)))
        }
    }

    func testMissingCorruptOrMisconfiguredRecoveryAgentRequiresRepair() async throws {
        let runner = StubRunner(results: [])
        try FileManager.default.removeItem(at: files.recoveryAgent)
        await assertInstallationFailure(client(runner), component: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        try Data("not a plist".utf8).write(to: files.recoveryAgent)
        await assertInstallationFailure(client(runner), component: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        try files.writeAgent(arguments: ["/wrong/runtime", "_recover"])
        await assertInstallationFailure(client(runner), component: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        try files.writeAgent(runAtLoad: false)
        await assertInstallationFailure(client(runner), component: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        try files.writeAgent(associatedBundles: nil)
        await assertInstallationFailure(client(runner), component: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        try files.writeAgent(associatedBundles: ["example.wrong.app"])
        await assertInstallationFailure(client(runner), component: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testUnregisteredRecoveryAgentRequiresRepair() async throws {
        let runner = StubRunner(results: [0, 0, 1].map { CommandResult(code: Int32($0), text: "") })
        await assertInstallationFailure(client(runner), component: L10n.text("復旧サービスの登録"))
    }

    func testMissingChangedOrNonExecutableRecoveryEntryRequiresRepair() async throws {
        let runner = StubRunner(results: [])
        let detail = L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files.installedRecovery.path)
        await assertInstallationFailure(client(runner), component: detail)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.installedRecovery.path)
        try Data("outdated recovery".utf8).write(to: files.installedRecovery)
        await assertInstallationFailure(client(runner), component: detail)
        try FileManager.default.removeItem(at: files.installedRecovery)
        await assertInstallationFailure(client(runner), component: detail)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testNonExecutableRuntimeRequiresRepair() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files.installedCLI.path)
        await assertInstallationFailure(client(StubRunner(results: [])), component: L10n.text("内部CLIが見つからないか、内容または実行権限が一致しません。"))
    }

    func testMissingCLIReportsFailureWithoutSwitchingImplementations() async {
        for action: RuntimeClient.Action in [.stop, .recover] {
            let runner = StubRunner(results: [CommandResult(code: 127, text: "missing script")])
            do { try await client(runner).perform(action); XCTFail("A missing CLI must fail") }
            catch { XCTAssertEqual((error as? AppFailure)?.code, .runtimeUnavailable) }
            let calls = await runner.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testAuthorizationFailuresNeverInvokeAnotherRecoveryPrompt() async {
        let cases: [(Int32, FailureCode)] = [(82, .authorizationCancelled), (84, .authorizationFailed)]
        for (exit, expected) in cases {
            let runner = StubRunner(results: [CommandResult(code: exit, text: "fixture authorization failure")])
            do { try await client(runner).perform(.recover); XCTFail("Recovery succeeded: \(exit)") }
            catch { XCTAssertEqual((error as? AppFailure)?.code, expected, "exit \(exit)") }
            let calls = await runner.calls
            XCTAssertEqual(calls.count, 1, "exit \(exit)")
        }
    }

    func testDiagnosisRetainsComponentWhenProcessCannotLaunch() async {
        await assertInstallationFailure(client(StubRunner(results: [])), component: L10n.text("電源制御権限（disablesleep %@）", "0"))
    }

    private func assertInstallationFailure(_ runtime: RuntimeClient, component: String,
                                           file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await runtime.checkInstallation()
            XCTFail("Invalid installation accepted", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? AppFailure)?.code, .installation, file: file, line: line)
            XCTAssertTrue((error as? AppFailure)?.detail?.contains(component) == true, file: file, line: line)
        }
    }
}

private actor StubRunner: CommandRunning {
    struct Invocation {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private var results: [CommandResult]
    private(set) var calls: [Invocation] = []

    init(results: [CommandResult]) { self.results = results }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        calls.append(Invocation(executable: executable, arguments: arguments, environment: environment))
        guard !results.isEmpty else { throw AppFailure(code: .unexpected, detail: "Unexpected command") }
        return results.removeFirst()
    }
}
