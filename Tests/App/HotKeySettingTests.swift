import XCTest
import SwiftUI

@MainActor
final class HotKeySettingTests: XCTestCase {
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
            XCTAssertEqual(button.title, "クリックして設定")
        }
    }

    func testUnsetKeyCanBeRegisteredDirectly() throws {
        try withSetting { fixture, _, button in
            fixture.key = nil
            settle()
            XCTAssertEqual(button.title, "クリックして設定")
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
            XCTAssertEqual(button.title, "クリックして設定")
            try attach(host, name: "header-480-dark-unset")
        }
    }

    private var candidate: HotKey { HotKey(keyCode: 0, modifiers: 4352, label: "⌃⌘A") }

    private func sendKey(_ type: NSEvent.EventType, to button: NSButton, code: UInt16 = 0) {
        NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.control, .command],
            timestamp: 0, windowNumber: button.window!.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!)
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func withSetting(header: Bool = false, width: CGFloat = 560, colorScheme: ColorScheme = .light,
                             _ body: (Fixture, NSView, HotKeyRecorder.RecorderButton) throws -> Void) throws {
        _ = NSApplication.shared
        let fixture = Fixture()
        let host = NSHostingView(rootView: SettingFixture(fixture: fixture, header: header)
            .padding(24).frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, colorScheme))
        host.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle()
        let button = try XCTUnwrap(findRecorder(host))
        try body(fixture, host, button)
    }

    private func findRecorder(_ view: NSView) -> HotKeyRecorder.RecorderButton? {
        if let button = view as? HotKeyRecorder.RecorderButton { return button }
        return view.subviews.lazy.compactMap { self.findRecorder($0) }.first
    }

    private func attach(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private final class Fixture: ObservableObject {
        @Published var key: HotKey? = .standard
        var saved: [HotKey?] = []
        var editing: [Bool] = []
        var reject = false

        func save(_ key: HotKey?) throws {
            if reject { throw AppFailure(code: .unexpected, detail: "このキーは登録できませんでした。別の組み合わせを選んでください。") }
            self.key = key
            saved.append(key)
        }
    }

    private struct SettingFixture: View {
        @ObservedObject var fixture: Fixture
        var header = false
        var body: some View {
            if header {
                let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("design/icon/icon-64.png")
                SettingsHeader(icon: NSImage(contentsOf: iconURL) ?? NSImage(size: NSSize(width: 40, height: 40)),
                               key: fixture.key, onSave: fixture.save,
                               onEditingChange: { fixture.editing.append($0) })
            } else {
                HotKeySetting(key: fixture.key, onSave: fixture.save,
                              onEditingChange: { fixture.editing.append($0) })
            }
        }
    }
}
