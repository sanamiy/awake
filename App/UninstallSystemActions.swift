import AppKit
import ServiceManagement

@MainActor
struct UninstallSystemActions {
    // OS boundaries only. AppModel owns ordering, progress and power restoration.
    var applicationURL = Bundle.main.bundleURL
    var unregisterLoginItem: () async throws -> Void = {
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
        }
    }
    var showInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var terminate: () -> Void = { NSApp.terminate(nil) }

    func removeLoginItem() async throws {
        do {
            try await unregisterLoginItem()
        } catch {
            throw AppFailure(code: .loginRemoval, detail: error.localizedDescription)
        }
    }

    func reveal() throws {
        try validateTarget()
        showInFinder([applicationURL])
        // This API does not report completion. Do not claim the app was deleted.
    }

    func validateTarget() throws {
        let url = applicationURL
        // Only the running app bundle is passed by AppModel. Reject broad paths,
        // symlinks and other apps before any cleanup begins.
        guard url.isFileURL, url.pathExtension == "app",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == AppIdentity.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL,
              executable.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppFailure(code: .invalidTarget)
        }
    }
}
