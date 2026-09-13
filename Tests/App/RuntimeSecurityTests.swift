import XCTest

/// Harmless fixture scripts only: no real CLI, power, lock or TCC operations.
final class RuntimeSecurityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Awake security \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testStartNeverExecutesTheMutableInstalledCopy() async throws {
        let bundled = try script("bin/lid-awake", "#!/bin/zsh\nexit 0\n")
        let installed = try script("installed/lid-awake", "#!/bin/zsh\nexit 0\n")
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: bundled))
        // Model a replacement after the readiness check; no timing race needed.
        try Data("#!/bin/zsh\nexit 99\n".utf8).write(to: installed)
        let runtime = RuntimeClient(directory: directory, installedCLI: installed, authorizer: bundled)
        try await runtime.perform(.start(Preferences()))
    }

    // Exact executable/argument/environment contracts live in RuntimeClientTests.
    // Here we exercise real, harmless child processes to verify isolation.
    func testUserStartupCodeCannotRunBeforeAnyBundledAction() async throws {
        let bundled = try script("bin/lid-awake", "#!/bin/zsh\nexit 0\n")
        _ = try script("uninstall.sh", "#!/bin/zsh\nexit 0\n")
        _ = try script(".zshenv", "exit 99\n")
        let runtime = RuntimeClient(directory: directory, installedCLI: directory.appendingPathComponent("unused"),
            authorizer: bundled, runner: StartupEnvironmentRunner(startupDirectory: directory))
        for action: RuntimeClient.Action in [.start(Preferences()), .stop, .recover, .remove] {
            try await runtime.perform(action)
        }
    }

    func testRunnerPreservesArgumentsAndFailureCode() async throws {
        let result = try await CommandRunner().run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", "print -r -- \"$1\"; exit 7", "test", "space and $(not executed)"])
        XCTAssertEqual(result.code, 7)
        XCTAssertEqual(result.text, "space and $(not executed)")
    }

    func testCommandEnvironmentIsExplicitAndDoesNotInheritAmbientVariables() async throws {
        // Only emit variable names, never values or credentials from the host.
        let probe = try script("environment.zsh", "print -rl -- ${(k)parameters[(R)*export*]}\n")
        let result = try await CommandRunner().run(URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", probe.path], environment: ["LID_AWAKE_NO_NOTIFY": "1"])
        XCTAssertEqual(result.code, 0)
        let names = Set(result.text.split(separator: "\n").map(String.init))
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LC_ALL", "LID_AWAKE_NO_NOTIFY", "PWD", "OLDPWD", "SHLVL", "_"]
        XCTAssertTrue(names.isSubset(of: allowed), "Unexpected inherited variable names: \(names.subtracting(allowed).sorted())")
        XCTAssertTrue(names.contains("LID_AWAKE_NO_NOTIFY"))
    }
}

private struct StartupEnvironmentRunner: CommandRunning {
    let startupDirectory: URL
    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        // Test-only injection, stronger than production's stripped environment.
        try await CommandRunner().run(executable, arguments: arguments,
            environment: environment.merging(["ZDOTDIR": startupDirectory.path]) { _, new in new })
    }
}
