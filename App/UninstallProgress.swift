import Foundation

/// Saved intent is for resuming the UI, never evidence that power is restored.
struct UninstallProgress {
    enum Stage: String { case cleaning, readyForFinder }
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LidAwake/uninstall-state")
    var url = defaultURL

    func load() -> Stage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8),
              let stage = Stage(rawValue: value) else { return .cleaning }
        return stage
    }

    func save(_ stage: Stage) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(stage.rawValue.utf8).write(to: url, options: .atomic)
    }
}
