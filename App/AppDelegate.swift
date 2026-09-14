import SwiftUI
import AppKit
import Carbon
import OSLog

/// Stays alive without a window, Dock tile, or status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppModel
    private let registerLoginItem: @MainActor (AppModel) -> Void
    private let startupLog = Logger(subsystem: AppIdentity.bundleIdentifier, category: "startup")

    init(model: AppModel,
         registerLoginItem: @escaping @MainActor (AppModel) -> Void = { $0.registerLoginItem() }) {
        self.model = model
        self.registerLoginItem = registerLoginItem
        super.init()
    }

    private var settingsWindow: NSWindow?
    private var refreshTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Manual use also works when automatic background startup is disabled.
        model.startBackgroundServices()
        for eventID in [kAEOpenApplication, kAEReopenApplication] {
            NSAppleEventManager.shared().setEventHandler(self,
                andSelector: #selector(handleOpenEvent(_:withReplyEvent:)),
                forEventClass: kCoreEventClass, andEventID: eventID)
        }
        installMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startupLog.info("Initialization finished")
        registerLoginItem(model)
    }

    @objc func handleOpenEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let show = AppLaunch.requestsSettings(event)
        startupLog.info("Open event received; showSettings=\(show)")
        if show { showSettings() }
    }

    // Do not create an initial window through AppKit's default untitled-file path.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAccessibilityPermission()
    }

    @objc func showSettings() {
        guard !model.didFinishUninstallHandoff else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = AppIdentity.name
            // No separate title band; retain native close/minimize controls.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 480, height: 380)
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refreshTask == nil {
            refreshTask = Task { @MainActor in
                while !Task.isCancelled {
                    await model.refresh()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { return }
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep modal confirmations (such as uninstall) visible until dismissed.
        sender.attachedSheet == nil
    }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
        NSApp.setActivationPolicy(.accessory)
        // AppModel retains the hotkey and screen-lock monitor independently.
    }

    @objc func enterAwakeMode() {
        Task { try? await model.perform(.start) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(enterAwakeMode) {
            return !model.isBusy && !model.isUninstallPending && !model.didFinishUninstallHandoff
        }
        return true
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: AppIdentity.name)
        let start = appMenu.addItem(withTitle: L10n.text("Awake Modeに入る"), action: #selector(enterAwakeMode), keyEquivalent: "")
        start.target = self
        start.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: L10n.text("設定を開く…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(withTitle: L10n.text("ウインドウを閉じる"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: L10n.text("%@を終了", AppIdentity.name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // nil restores AppKit's automatic quit symbol; an empty image suppresses it.
        quit.image = NSImage(size: NSSize(width: 16, height: 16))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: L10n.text("編集"))
        for (title, action, key) in [(L10n.text("取り消す"), "undo:", "z"), (L10n.text("カット"), "cut:", "x"),
                                    (L10n.text("コピー"), "copy:", "c"), (L10n.text("ペースト"), "paste:", "v"), (L10n.text("すべてを選択"), "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.didFinishUninstallHandoff { return .terminateNow }
        return model.prepareToTerminate { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        } ? .terminateLater : .terminateCancel
    }
}
