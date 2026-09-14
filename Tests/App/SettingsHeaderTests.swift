import XCTest
import SwiftUI

@MainActor
final class SettingsHeaderTests: HotKeySettingTestCase {
    func testHeaderRendersAtMinimumWidthWithoutChangingRecording() throws {
        try withSetting(header: true, width: 480) { fixture, host, button in
            let bounds = button.convert(button.bounds, to: host)
            XCTAssertGreaterThan(bounds.minX, host.bounds.midX)
            XCTAssertLessThanOrEqual(bounds.maxX, host.bounds.maxX - 24)
            try attach(host, name: "header-480-idle")
            button.performClick(nil)
            settle()
            try attach(host, name: "header-480-recording")
            sendKey(.keyDown, to: button)
            sendKey(.keyUp, to: button)
            XCTAssertEqual(fixture.saved, [candidate])
        }
    }

    func testHeaderUnsetStateAndDarkAppearance() throws {
        try withSetting(header: true, width: 480, colorScheme: .dark) { fixture, host, button in
            fixture.key = nil
            settle()
            XCTAssertEqual(button.title, L10n.text("クリックして設定"))
            try attach(host, name: "header-480-dark-unset")
        }
    }

}
