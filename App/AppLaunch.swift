import AppKit
import Carbon

enum AppLaunch: Equatable {
    case application, authorize(String)

    init(arguments: [String]) throws {
        switch arguments {
        case []: self = .application
        case ["--authorize-restore"], ["--authorize-remove"]: self = .authorize(arguments[0])
        default: throw AppFailure(code: .invalidInput)
        }
    }

    /// Inspect a delivered event, never the absence of currentAppleEvent.
    /// Unknown launch metadata is conservatively treated as a background launch.
    static func requestsSettings(_ event: NSAppleEventDescriptor) -> Bool {
        event.eventClass == kCoreEventClass
            && [kAEOpenApplication, kAEReopenApplication].contains(event.eventID)
            && event.paramDescriptor(forKeyword: keyAEPropData) == nil
    }
}
