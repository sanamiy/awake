import XCTest
import SwiftUI

/// Shared native control fixture for input and header/row layout tests.
@MainActor
class HotKeySettingTestCase: XCTestCase {
    var candidate: HotKey { HotKey(keyCode: 0, modifiers: 4352, label: "⌃⌘A") }

    func sendKey(_ type: NSEvent.EventType, to button: NSButton, code: UInt16 = 0) {
        NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.control, .command],
            timestamp: 0, windowNumber: button.window!.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!)
    }

    func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func withSetting(header: Bool = false, width: CGFloat = 560, colorScheme: ColorScheme = .light,
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

    func findRecorder(_ view: NSView) -> HotKeyRecorder.RecorderButton? {
        if let button = view as? HotKeyRecorder.RecorderButton { return button }
        return view.subviews.lazy.compactMap { self.findRecorder($0) }.first
    }

    func attach(_ host: NSView, name: String) throws {
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

    final class Fixture: ObservableObject {
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

    struct SettingFixture: View {
        @ObservedObject var fixture: Fixture
        var header = false
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                if header {
                    let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("design/icon/icon-64.png")
                    SettingsHeader(icon: NSImage(contentsOf: iconURL) ?? NSImage(size: NSSize(width: 40, height: 40)))
                }
                HotKeySetting(key: fixture.key, onSave: fixture.save,
                              onEditingChange: { fixture.editing.append($0) })
            }
        }
    }
}
