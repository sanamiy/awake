import AppKit
import Foundation

// Runs the production termination path in a separate NSApplication process.
// The only runtime command is a delayed mock stop; no real power/permission changes.
private actor StopRunner: CommandRunning {
    let failFirst: Bool
    private var calls = 0
    init(failFirst: Bool) { self.failFirst = failFirst }

    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        guard executable.path == "/bin/zsh", arguments.last == "stop" else {
            fatalError("Unexpected runtime operation")
        }
        calls += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return CommandResult(code: failFirst && calls == 1 ? 80 : 0, text: "mock stop")
    }
}

@MainActor
private final class Driver: NSObject, NSApplicationDelegate {
    let model: AppModel
    let delegate: AppDelegate
    let failFirst: Bool
    var retried = false
    var responses: [NSApplication.TerminateReply] = []

    init(model: AppModel, failFirst: Bool) {
        self.model = model
        self.failFirst = failFirst
        delegate = AppDelegate(model: model, registerLoginItem: { _ in fatalError("Unexpected registration") })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Do not forward startup: this test exercises termination only.
        if failFirst {
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
                MainActor.assumeIsolated {
                    guard model.needsRecovery else { return }
                    precondition(!model.isBusy && model.failure?.code == .powerRestore)
                    precondition(responses == [.terminateLater])
                    timer.invalidate()
                    retried = true
                    NSApp.terminate(nil)
                }
            }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let response = delegate.applicationShouldTerminate(sender)
        precondition(response == .terminateLater && model.isBusy)
        responses.append(response)
        return response
    }

    func applicationWillTerminate(_ notification: Notification) {
        precondition(!model.isBusy && !model.needsRecovery && model.failure == nil)
        precondition(responses.count == (failFirst ? 2 : 1))
        precondition(retried == failFirst)
        print("PASS: actual AppKit quit loop, failFirst=\(failFirst)")
        fflush(stdout)
    }
}

@main
private enum TerminationProbe {
    @MainActor static func main() {
        let failFirst = CommandLine.arguments.contains("--fail-first")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "AwakeTerminationProbe-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = RuntimeClient(directory: directory, installedCLI: directory, authorizer: directory,
                                    runner: StopRunner(failFirst: failFirst))
        let model = AppModel(runtime: runtime, preferencesStore: defaults, monitorSystemEvents: false,
                             uninstallProgress: UninstallProgress(url: directory.appendingPathComponent("unused-state")),
                             hotKey: GlobalHotKey(register: { _, _ in fatalError("Unexpected key registration") }))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let driver = Driver(model: model, failFirst: failFirst)
        app.delegate = driver
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("FAIL: quit loop stalled\n", stderr)
            exit(42)
        }
        withExtendedLifetime(driver) { app.run() }
    }
}
