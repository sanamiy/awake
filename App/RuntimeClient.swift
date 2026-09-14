import Foundation

/// Invokes the CLI; power-state checks and restoration belong to the CLI alone.
struct RuntimeClient: Sendable {
    enum Action {
        case start(Preferences)
        case stop
        case recover
        case remove
    }

    let directory: URL
    let installedCLI: URL
    let authorizer: URL
    var runner: any CommandRunning = CommandRunner()
    var recoveryAgentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/dev.lid-awake.recover.plist")
    var userID = getuid()

    static var live: Self {
        Self(directory: Bundle.main.resourceURL!.appendingPathComponent("runtime"),
             installedCLI: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lid-awake"),
             authorizer: Bundle.main.executableURL!)
    }

    private var bundledCLI: URL { directory.appendingPathComponent("bin/lid-awake") }
    var bundledRecovery: URL { directory.appendingPathComponent("../../Helpers/AwakeRecovery").standardizedFileURL }
    var installedRecovery: URL { installedCLI.deletingLastPathComponent().appendingPathComponent("AwakeRecovery") }
    private let shell = URL(fileURLWithPath: "/bin/zsh")
    private let quietEnvironment = ["LID_AWAKE_NO_NOTIFY": "1"]

    /// Each check reports its failing component; callers retain the diagnosis.
    func checkInstallation() async throws {
        guard matchesBundledExecutable(installed: installedCLI, bundled: bundledCLI) else {
            throw AppFailure(code: .installation, detail: L10n.text("内部CLIが見つからないか、内容または実行権限が一致しません。"))
        }
        guard matchesBundledExecutable(installed: installedRecovery, bundled: bundledRecovery),
              let agentData = try? Data(contentsOf: recoveryAgentURL),
              let agent = (try? PropertyListSerialization.propertyList(from: agentData, format: nil)) as? [String: Any],
              agent["Label"] as? String == "dev.lid-awake.recover",
              agent["AssociatedBundleIdentifiers"] as? [String] == [AppIdentity.bundleIdentifier],
              agent["ProgramArguments"] as? [String] == [installedRecovery.path],
              agent["RunAtLoad"] as? Bool == true else {
            throw AppFailure(code: .installation, detail: L10n.text("復旧用LaunchAgentの設定が見つからないか、内容が一致しません。"))
        }
        // Both enabling and restoring sleep must work without another prompt.
        for state in ["0", "1"] {
            try await checkRegistrationCommand(URL(fileURLWithPath: "/usr/bin/sudo"),
                arguments: ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", state],
                component: L10n.text("電源制御権限（disablesleep %@）", state))
        }
        try await checkRegistrationCommand(URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(userID)/dev.lid-awake.recover"], component: L10n.text("復旧サービスの登録"))
    }

    private func matchesBundledExecutable(installed: URL, bundled: URL) -> Bool {
        guard let installedData = try? Data(contentsOf: installed),
              let bundledData = try? Data(contentsOf: bundled) else { return false }
        return installedData == bundledData && FileManager.default.isExecutableFile(atPath: installed.path)
    }

    private func checkRegistrationCommand(_ executable: URL, arguments: [String], component: String) async throws {
        let result: CommandResult
        do { result = try await runner.run(executable, arguments: arguments, environment: [:]) }
        catch { throw AppFailure(code: .installation, detail: L10n.text("%@を確認できません。\n%@", component, error.localizedDescription)) }
        guard result.code == 0 else {
            throw AppFailure(code: .installation, detail: L10n.text("%@を確認できません。終了値: %@\n%@", component, String(result.code), result.text))
        }
    }

    func perform(_ action: Action) async throws {
        switch action {
        case .start(let preferences):
            // The user-owned copy is for login recovery/diagnostics, not code
            // executed by the Accessibility-approved application.
            try await runChecked(preferences.startArguments())
        case .stop:
            try await runChecked(["stop"])
        case .recover:
            try await runChecked(["recover"], authorize: true)
        case .remove:
            try await runChecked([], script: directory.appendingPathComponent("uninstall.sh"),
                                 authorize: true, unexpectedExit: .runtimeRemoval)
        }
    }

    /// Process execution and exit decoding only; never retries or recovers.
    private func runChecked(_ arguments: [String], script: URL? = nil, authorize: Bool = false,
                            unexpectedExit: FailureCode = .unexpected) async throws {
        var environment = quietEnvironment
        if authorize { environment["LID_AWAKE_AUTHORIZER"] = authorizer.path }
        let result: CommandResult
        do {
            result = try await runner.run(shell, arguments: ["-f", "--", (script ?? bundledCLI).path] + arguments,
                                          environment: environment)
        }
        catch { throw AppFailure(code: .runtimeUnavailable, detail: error.localizedDescription) }
        guard result.code == 0 else {
            let code = FailureCode.runtimeExit(result.code)
            throw AppFailure(code: code == .unexpected ? unexpectedExit : code,
                             detail: L10n.text("終了値: %@\n%@", String(result.code), result.text))
        }
    }
}
