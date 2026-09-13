import Foundation
import IOKit

/// Requests display sleep once per lid closure, only during our locked session.
/// Does not alter display timers, brightness preferences or system sleep state.
@MainActor
final class LidDisplaySleep {
    struct PowerState {
        let lidClosed: Bool
        let sleepDisabled: Bool
    }

    var readPowerState: () -> PowerState? = currentPowerState
    var requestDisplaySleep: () throws -> Void = sleepDisplays
    private var requestedForClosure = false

    func update(sessionActive: Bool, screenState: ScreenLockState) throws {
        guard sessionActive, screenState == .locked else {
            reset()
            return
        }
        guard let power = readPowerState() else { return }
        guard power.lidClosed, power.sleepDisabled else {
            reset()
            return
        }
        guard !requestedForClosure else { return }
        // Do not repeatedly darken displays or flood errors if macOS refuses.
        // Opening and closing the lid allows another attempt.
        requestedForClosure = true
        try requestDisplaySleep()
    }

    func reset() { requestedForClosure = false }

    private static func currentPowerState() -> PowerState? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any],
              let closed = values["AppleClamshellState"] as? Bool,
              let disabled = values["SleepDisabled"] as? Bool else { return nil }
        return PowerState(lidClosed: closed, sleepDisabled: disabled)
    }

    private static func sleepDisplays() throws {
        // Same request used by Apple's `pmset displaysleepnow`. Doing it here
        // preserves the IOKit error and avoids a deferred subprocess launch.
        // This sleeps all attached displays, not just the built-in panel.
        let service = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard service != 0 else {
            throw AppFailure(code: .displaySleep, detail: L10n.text("ディスプレイの制御サービスが見つかりません。"))
        }
        defer { IOObjectRelease(service) }
        let result = IORegistryEntrySetCFProperty(service, "IORequestIdle" as CFString, kCFBooleanTrue)
        guard result == KERN_SUCCESS else {
            throw AppFailure(code: .displaySleep, detail: "IOKit: \(result)")
        }
    }
}
