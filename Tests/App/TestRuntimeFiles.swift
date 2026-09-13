import Foundation

/// Valid installation files, never executable application code.
/// A runner is mandatory so a fixture cannot accidentally launch system commands.
struct TestRuntimeFiles {
    let directory: URL
    var installedCLI: URL { directory.appendingPathComponent("installed-cli") }
    var bundledCLI: URL { directory.appendingPathComponent("bin/lid-awake") }
    var recoveryAgent: URL { directory.appendingPathComponent("recover.plist") }
    var authorizer: URL { directory.appendingPathComponent("Awake.app/Contents/MacOS/Awake") }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: bundledCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [installedCLI, bundledCLI] {
            try Data("fixture, never executed".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try writeAgent()
    }

    func writeAgent(arguments: [String]? = nil, runAtLoad: Bool = true,
                    associatedBundles: [String]? = [AppIdentity.bundleIdentifier]) throws {
        var agent: [String: Any] = ["Label": "dev.lid-awake.recover",
            "ProgramArguments": arguments ?? [installedCLI.path, "_recover"], "RunAtLoad": runAtLoad]
        agent["AssociatedBundleIdentifiers"] = associatedBundles
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: recoveryAgent)
    }

    func client(runner: any CommandRunning) -> RuntimeClient {
        RuntimeClient(directory: directory, installedCLI: installedCLI, authorizer: authorizer,
            runner: runner, recoveryAgentURL: recoveryAgent, userID: 501)
    }
}
