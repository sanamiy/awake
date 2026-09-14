import XCTest
import AppKit
import Carbon

final class AppLaunchTests: XCTestCase {
    func testLaunchArgumentsSelectApplicationOrAuthorization() throws {
        XCTAssertEqual(try AppLaunch(arguments: []), .application)
        XCTAssertEqual(try AppLaunch(arguments: ["--authorize-restore"]), .authorize("--authorize-restore"))
        XCTAssertEqual(try AppLaunch(arguments: ["--authorize-remove"]), .authorize("--authorize-remove"))
        for args in [["--background"], ["--background", "extra"], ["--authorize-other"]] {
            XCTAssertThrowsError(try AppLaunch(arguments: args))
        }
    }

    func testOnlyUnmarkedOpenEventsRequestSettings() {
        for id in [kAEOpenApplication, kAEReopenApplication, kAEQuitApplication] {
            let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id,
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            XCTAssertEqual(AppLaunch.requestsSettings(event), id != kAEQuitApplication)
            for reason in [NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
                           NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem),
                           NSAppleEventDescriptor(string: "unknown"), NSAppleEventDescriptor.null()] {
                event.setParam(reason, forKeyword: keyAEPropData)
                XCTAssertFalse(AppLaunch.requestsSettings(event))
            }
        }
    }
}
