import AppKit
import Darwin

@main
enum AppEntry {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first?.hasPrefix("--authorize-") == true {
            // Run as a separate instance of this signed app, not osascript.
            // No model/window/hotkey is created; the caller retains its operation lock.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            do {
                guard arguments.count == 1 else { throw AppFailure(code: .invalidInput) }
                try AdministrativeAuthorization.perform(arguments[0])
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                let failure = AppFailure.normalize(error)
                switch failure.code {
                case .authorizationCancelled: exit(82)
                case .invalidInput: exit(64)
                default: exit(84)
                }
            }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
