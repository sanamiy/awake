import XCTest
import SwiftUI

@MainActor
final class HotKeySettingTests: HotKeySettingTestCase {
    func testOneClickAndKeyReleaseRegisterWithoutSaveDialog() throws {
        try withSetting { fixture, _, button in
            XCTAssertFalse(button.recording, "Opening settings must not capture keys")
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            XCTAssertTrue(fixture.saved.isEmpty)
            sendKey(.keyUp, to: button)
            settle()
            XCTAssertEqual(fixture.saved, [candidate])
            XCTAssertEqual(fixture.key, candidate)
            XCTAssertEqual(button.title, candidate.label)
            XCTAssertEqual(fixture.editing, [true, false])
        }
    }

    func testOutsideClickDoesNotClearOrSavePendingKey() throws {
        try withSetting { fixture, host, button in
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            click(host.convert(NSPoint(x: 10, y: 10), to: nil), in: host.window!)
            sendKey(.keyUp, to: button)
            XCTAssertFalse(button.recording)
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertEqual(fixture.key, .standard)
        }
    }

    func testEscapeKeepsExistingAssignment() throws {
        try withSetting { fixture, _, button in
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            sendKey(.keyDown, to: button, code: 53)
            XCTAssertFalse(button.recording)
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertEqual(button.title, HotKey.standard.label)
        }
    }

    func testRejectedKeyPreservesAssignmentAndCanBeRetried() throws {
        try withSetting { fixture, host, button in
            fixture.reject = true
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            sendKey(.keyUp, to: button)
            settle()
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertEqual(fixture.key, .standard)
            XCTAssertEqual(button.title, HotKey.standard.label)
            try attach(host, name: "shortcut-conflict")
            fixture.reject = false
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            sendKey(.keyUp, to: button)
            XCTAssertEqual(fixture.saved, [candidate])
        }
    }

    func testClearButtonExplicitlyRemovesAssignmentEvenWhileRecording() throws {
        try withSetting { fixture, _, button in
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            let clearCenter = button.convert(NSPoint(x: button.bounds.maxX + 24, y: button.bounds.midY), to: nil)
            click(clearCenter, in: button.window!)
            settle()
            XCTAssertEqual(fixture.saved.count, 1)
            XCTAssertNil(fixture.key)
            XCTAssertFalse(button.recording)
            XCTAssertEqual(button.title, L10n.text("クリックして設定"))
        }
    }

    func testUnsetKeyCanBeRegisteredDirectly() throws {
        try withSetting { fixture, _, button in
            fixture.key = nil
            settle()
            XCTAssertEqual(button.title, L10n.text("クリックして設定"))
            button.performClick(nil)
            sendKey(.keyDown, to: button)
            sendKey(.keyUp, to: button)
            XCTAssertEqual(fixture.key, candidate)
        }
    }

    func testNativeRowRendersIdleAndRecordingAtMinimumWidth() throws {
        try withSetting { _, host, button in
            try attach(host, name: "shortcut-inline")
            button.performClick(nil)
            settle()
            try attach(host, name: "shortcut-recording")
        }
    }

}
