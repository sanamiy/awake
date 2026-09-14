import AppKit
import Darwin

@main
enum AppEntry {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        do {
            let mode = try AppLaunch(arguments: Array(CommandLine.arguments.dropFirst()))
            if case .authorize(let argument) = mode {
                // No model/window/hotkey; the caller retains its operation lock.
                try AdministrativeAuthorization.perform(argument)
                exit(0)
            }
            let delegate = AppDelegate(model: AppModel())
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            switch AppFailure.normalize(error).code {
            case .authorizationCancelled: exit(82)
            case .invalidInput: exit(64)
            default: exit(84)
            }
        }
    }
}
