import Foundation

struct CommandResult {
    let code: Int32
    let text: String
}

protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult
}

struct CommandRunner: CommandRunning {
    // Do not pass shell startup/search paths, loader settings or unrelated app
    // credentials to descendants. Runtime overrides are owned by RuntimeClient.
    private var baseEnvironment: [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "USER": NSUserName(), "LOGNAME": NSUserName(),
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "TMPDIR": FileManager.default.temporaryDirectory.path,
         "LC_ALL": "C"]
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:]) async throws -> CommandResult {
        let childEnvironment = baseEnvironment.merging(environment) { _, new in new }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = childEnvironment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    // Drain while running so verbose setup errors cannot fill the pipe.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: CommandResult(code: process.terminationStatus, text: text))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
