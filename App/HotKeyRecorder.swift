import SwiftUI
import AppKit
import Carbon

struct HotKeyRecorder: NSViewRepresentable {
    let title: String
    let onSelect: (HotKey) -> Void
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.savedTitle = title
        if !button.recording { button.title = title }
        button.onSelect = onSelect
        button.onRecordingChange = onRecordingChange
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) {
        button.finishRecording()
    }

    final class RecorderButton: NSButton {
        var onSelect: ((HotKey) -> Void)?
        var onRecordingChange: ((Bool) -> Void)?
        var savedTitle = L10n.text("キーを設定")
        private enum CaptureState {
            case idle, waitingForKey, waitingForRelease(HotKey)
        }
        private var captureState: CaptureState = .idle
        var recording: Bool {
            if case .idle = captureState { return false }
            return true
        }
        private var eventMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        override var acceptsFirstResponder: Bool { true }

        @objc func beginRecording() {
            guard !recording, isEnabled else { return }
            window?.makeFirstResponder(self)
            captureState = .waitingForKey
            onRecordingChange?(true)
            title = L10n.text("キーを入力")
            // Consume app key equivalents before menus or other responders can
            // execute them. No global event tap or Accessibility permission.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleMonitoredEvent(event)
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                self?.finishRecording()
            })
            if let window {
                for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.finishRecording()
                    })
                }
            }
        }

        func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
            guard recording else { return event }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                // Clicking non-focusable SwiftUI content does not necessarily
                // resign first responder. End capture explicitly on outside clicks.
                if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                    finishRecording()
                }
                return event
            default:
                record(event)
                return nil
            }
        }

        override func resignFirstResponder() -> Bool {
            finishRecording()
            return super.resignFirstResponder()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { finishRecording() }
            super.viewWillMove(toWindow: newWindow)
        }

        func finishRecording(with key: HotKey? = nil) {
            guard recording else { return }
            captureState = .idle
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            onRecordingChange?(false)
            if let key { onSelect?(key) }
            title = savedTitle
        }

        func record(_ event: NSEvent) {
            guard recording else { return }
            if event.type == .keyUp {
                if case .waitingForRelease(let key) = captureState, key.keyCode == UInt32(event.keyCode) {
                    finishRecording(with: key)
                }
                return
            }
            guard event.type == .keyDown, !event.isARepeat else { return }
            if event.keyCode == 53 { finishRecording(); return }
            guard case .waitingForKey = captureState else { return }
            guard let key = HotKey(event: event) else {
                title = L10n.text("⌘ / ⌃ が必要")
                return
            }
            captureState = .waitingForRelease(key)
            title = key.label
        }
    }
}

extension HotKey {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { return nil }
        var modifiers: UInt32 = 0
        var prefix = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); prefix += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); prefix += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); prefix += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); prefix += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                  label: prefix + (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"))
    }
}
