import SwiftUI
import AppKit

/// Stays alive without a window, Dock tile, or status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel? = nil) {
        self.model = model ?? .shared
        super.init()
    }

    private var settingsWindow: NSWindow?
    private var refreshTask: Task<Void, Never>?
    private var didLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.showSettings = { [weak self] in self?.showSettings() }
        installMenu()
        model.registerLoginItem()
        didLaunch = true
        let event = NSAppleEventManager.shared().currentAppleEvent
        if model.isUninstallPending || !LoginStartup.isLoginLaunch(event) { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if didLaunch { showSettings() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAccessibilityPermission()
    }

    @objc func showSettings() {
        guard !model.didFinishUninstallHandoff else { return }
        model.refreshAccessibilityPermission()
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
        model.refreshLoginItemStatus()
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.deminiaturize(nil)
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

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: AppIdentity.name)
        let settings = appMenu.addItem(withTitle: L10n.text("設定を開く…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(withTitle: L10n.text("ウインドウを閉じる"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("スリープ防止を停止して終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        guard !model.isBusy else {
            model.failure = AppFailure(code: .busy)
            showSettings()
            return .terminateCancel
        }
        Task {
            do { try await model.perform(.stop); sender.reply(toApplicationShouldTerminate: true) }
            catch { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}
