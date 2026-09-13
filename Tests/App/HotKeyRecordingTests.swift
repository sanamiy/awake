import XCTest
import AppKit
import Carbon

@MainActor
final class HotKeyRecordingTests: XCTestCase {
    private func recorder() -> HotKeyRecorder.RecorderButton {
        _ = NSApplication.shared
        let button = HotKeyRecorder.RecorderButton()
        button.savedTitle = "old shortcut"
        return button
    }

    private func window(containing button: HotKeyRecorder.RecorderButton) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        button.frame = NSRect(x: 20, y: 20, width: 210, height: 28)
        window.contentView!.addSubview(button)
        return window
    }

    private func event(_ type: NSEvent.EventType, keyCode: UInt16 = 13,
                       flags: NSEvent.ModifierFlags = [.control, .command], repeatKey: Bool = false,
                       windowNumber: Int = 0) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                         isARepeat: repeatKey, keyCode: keyCode)!
    }

    func testApplicationDispatchUsesOneCapturePathForKeysAndOutsideClicks() {
        let button = recorder()
        let window = window(containing: button)
        var saved: [HotKey] = []
        var states: [Bool] = []
        button.onSelect = { saved.append($0) }
        button.onRecordingChange = { states.append($0) }
        button.beginRecording()
        defer { button.finishRecording() }
        NSApp.sendEvent(event(.keyDown, windowNumber: window.windowNumber))
        XCTAssertTrue(saved.isEmpty)
        NSApp.sendEvent(event(.keyUp, windowNumber: window.windowNumber))
        XCTAssertEqual(saved, [.standard], "One key release must produce exactly one selection")
        XCTAssertEqual(states, [true, false])
        button.beginRecording()
        NSApp.sendEvent(event(.keyDown, keyCode: 12, windowNumber: window.windowNumber))
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 150),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(click)
        XCTAssertFalse(button.recording)
        XCTAssertEqual(states, [true, false, true, false])
        XCTAssertEqual(saved, [.standard])
    }

    func testRecordingOnlySelectsCandidateAfterKeyRelease() {
        let button = recorder()
        var sequence: [String] = []
        var selected: HotKey?
        button.onRecordingChange = { sequence.append($0 ? "begin" : "end") }
        button.onSelect = { selected = $0; sequence.append("select") }
        button.beginRecording()
        defer { button.finishRecording() }
        button.record(event(.keyDown))
        XCTAssertEqual(sequence, ["begin"])
        XCTAssertNil(selected)
        XCTAssertTrue(button.recording)
        button.record(event(.keyDown, repeatKey: true))
        button.record(event(.keyUp, keyCode: 0))
        XCTAssertEqual(sequence, ["begin"])
        button.record(event(.keyUp))
        XCTAssertEqual(sequence, ["begin", "end", "select"])
        XCTAssertEqual(selected, HotKey.standard)
        XCTAssertFalse(button.recording)
        button.record(event(.keyUp))
        XCTAssertEqual(sequence.count, 3)
    }

    func testEscapeEndsRecordingOnceWithoutSelecting() {
        let button = recorder()
        var states: [Bool] = []
        button.onRecordingChange = { states.append($0) }
        button.onSelect = { _ in XCTFail("Cancel must not select a candidate") }
        button.beginRecording()
        button.record(event(.keyDown))
        button.record(event(.keyDown, keyCode: 53, flags: []))
        button.finishRecording()
        XCTAssertEqual(states, [true, false])
        XCTAssertEqual(button.title, "old shortcut")
    }

    func testInvalidInputAndRepeatsKeepRecording() {
        let button = recorder()
        var states: [Bool] = []
        button.onRecordingChange = { states.append($0) }
        button.onSelect = { _ in XCTFail("Invalid input must not be selected") }
        button.beginRecording()
        button.record(event(.keyDown, flags: []))
        button.record(event(.keyUp, flags: []))
        button.record(event(.keyDown, repeatKey: true))
        button.record(event(.keyUp))
        XCTAssertTrue(button.recording)
        XCTAssertEqual(states, [true])
        button.finishRecording()
        XCTAssertEqual(states, [true, false])
    }

    func testFocusLossCancelsPendingKey() {
        let button = recorder()
        var states: [Bool] = []
        button.onRecordingChange = { states.append($0) }
        button.onSelect = { _ in XCTFail("Focus loss must cancel the pending key") }
        button.beginRecording()
        button.record(event(.keyDown))
        _ = button.resignFirstResponder()
        XCTAssertFalse(button.recording)
        XCTAssertEqual(states, [true, false])
    }

    func testOutsideClicksCancelWithoutChangingTheSavedKey() {
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let button = recorder()
            let window = window(containing: button)
            var states: [Bool] = []
            var saved = HotKey.standard
            button.onRecordingChange = { states.append($0) }
            button.onSelect = { saved = $0; XCTFail("An outside click must not select") }
            button.beginRecording()
            // A pending replacement must also be discarded when clicking away.
            XCTAssertNil(button.handleMonitoredEvent(event(.keyDown, keyCode: 12)))
            let click = NSEvent.mouseEvent(with: type, location: NSPoint(x: 300, y: 150),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            XCTAssertTrue(button.handleMonitoredEvent(click) === click, "Do not swallow the destination click")
            XCTAssertFalse(button.recording)
            XCTAssertEqual(states, [true, false])
            XCTAssertEqual(saved, .standard)
            XCTAssertEqual(button.title, "old shortcut")
            let release = event(.keyUp, keyCode: 12)
            XCTAssertTrue(button.handleMonitoredEvent(release) === release)
            XCTAssertEqual(saved, .standard)
        }
    }

    func testClickInsideRecorderDoesNotCancelOrSave() {
        let button = recorder()
        let window = window(containing: button)
        button.onSelect = { _ in XCTFail("Clicking must not change the key") }
        button.beginRecording()
        defer { button.finishRecording() }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 30, y: 30),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertTrue(button.handleMonitoredEvent(click) === click)
        XCTAssertTrue(button.recording)
    }

    func testAppDeactivationAndViewRemovalEndRecordingWithoutSelecting() {
        let button = recorder()
        var states: [Bool] = []
        button.onRecordingChange = { states.append($0) }
        button.onSelect = { _ in XCTFail("Interrupted recording must not select") }
        button.beginRecording()
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        XCTAssertEqual(states, [true, false])
        button.beginRecording()
        HotKeyRecorder.dismantleNSView(button, coordinator: ())
        XCTAssertEqual(states, [true, false, true, false])
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        XCTAssertEqual(states.count, 4, "Observers must be removed when recording ends")
    }

    func testRepeatedBeginAndDisabledButtonDoNotStartExtraSessions() {
        let button = recorder()
        var states: [Bool] = []
        button.onRecordingChange = { states.append($0) }
        button.isEnabled = false
        button.beginRecording()
        XCTAssertTrue(states.isEmpty)
        button.isEnabled = true
        button.beginRecording()
        button.beginRecording()
        button.finishRecording()
        XCTAssertEqual(states, [true, false])
    }

    func testKeyConversionRequiresCommandOrControlAndKeepsModifierOrder() {
        XCTAssertNil(HotKey(event: event(.keyDown, flags: [.option, .shift])))
        XCTAssertEqual(HotKey(event: event(.keyDown)), .standard)
        let key = HotKey(event: event(.keyDown, flags: [.control, .option, .shift, .command, .capsLock]))
        XCTAssertEqual(key?.modifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(key?.label, "⌃⌥⇧⌘W")
    }

}
