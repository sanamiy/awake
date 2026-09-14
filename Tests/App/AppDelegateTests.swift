import XCTest
import AppKit
import Carbon

@MainActor
final class AppDelegateTests: AppModelTestCase {
    func testMenuStartsAwakeModeThroughTheModelAndDisablesWhileBusy() async throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        let delegate = AppDelegate(model: model, registerLoginItem: { _ in XCTFail("Unexpected registration") })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        let menu = try XCTUnwrap(app.mainMenu?.items.first?.submenu)
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.enterAwakeMode) })
        XCTAssertEqual(item.title, L10n.text("Awake Modeに入る"))
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertNotNil(item.image)
        let quit = try XCTUnwrap(menu.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        XCTAssertTrue(try XCTUnwrap(quit.image).representations.isEmpty)
        menu.update()
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(try XCTUnwrap(quit.image).representations.isEmpty)
        let locked = expectation(description: "Menu requested screen lock")
        session.requestLock = {
            menu.update()
            XCTAssertFalse(item.isEnabled)
            locked.fulfill()
        }
        XCTAssertTrue(app.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await fulfillment(of: [locked], timeout: 2)
        XCTAssertEqual(session.phase, .locked)
        let actions = await runner.actions
        XCTAssertEqual(actions, ["_start"])
    }

    func testStartMenuIsDisabledDuringUninstall() throws {
        try progress.save(.cleaning)
        model = makeModel()
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        let delegate = AppDelegate(model: model, registerLoginItem: { _ in XCTFail("Unexpected registration") })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        let menu = try XCTUnwrap(app.mainMenu?.items.first?.submenu)
        menu.update()
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.enterAwakeMode) })
        XCTAssertFalse(item.isEnabled)
    }

    override func tearDownWithError() throws {
        for id in [kAEOpenApplication, kAEReopenApplication] {
            NSAppleEventManager.shared().removeEventHandler(forEventClass: kCoreEventClass, andEventID: id)
        }
        try super.tearDownWithError()
    }

    func testBackgroundLaunchStaysHiddenAndExplicitReopenShowsSettings() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let originalWindows = Set(app.windows.map(\.windowNumber))
        defer {
            for window in app.windows where !originalWindows.contains(window.windowNumber) { window.close() }
            app.setActivationPolicy(previousPolicy)
        }
        app.setActivationPolicy(.accessory) // AppEntry / LSUIElement startup policy.
        let hotKey = GlobalHotKey(register: FakeHotKeyRegistry().register)
        let preferences = Preferences()
        preferences.save(to: defaults)
        model = makeModel(hotKey: hotKey)
        XCTAssertNil(hotKey.key, "Construction alone must not start background services")
        var registrations = 0
        let delegate = AppDelegate(model: model, registerLoginItem: { _ in
            registrations += 1
        })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        deliverOpenEvent(kAEOpenApplication, reason: NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem))
        XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
        XCTAssertEqual(hotKey.key, preferences.hotKey)
        let firstRegistration = hotKey.registrationID
        model.startBackgroundServices()
        XCTAssertEqual(hotKey.registrationID, firstRegistration, "Startup is idempotent")
        // Exercise the real callback before did-finish-launching. Only the OS
        // registrar, screen lock and power commands are replaced by fixtures.
        await hotKey.handlePress(EventHotKeyID(signature: 0x4C494441, id: hotKey.registrationID))
        XCTAssertEqual(session.phase, .locked)
        XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
        try await model.perform(.stop)
        // No launch event is available when initialization completes.
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(registrations, 1, "Startup checks the login registration without opening settings")
        for id in [kAEOpenApplication, kAEReopenApplication] {
            for reason in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
                deliverOpenEvent(id, reason: NSAppleEventDescriptor(enumCode: reason))
                XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
                XCTAssertEqual(app.activationPolicy(), .accessory)
            }
        }
        XCTAssertEqual(app.activationPolicy(), .accessory)
        XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(app))

        // Failed background recovery remains visible as state, not a window.
        await hotKey.handlePress(EventHotKeyID(signature: 0x4C494441, id: hotKey.registrationID))
        session.readState = { .unlocked }
        await runner.setExit(80, for: "stop")
        await model.monitorSession()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertNotNil(model.failure)
        XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
        await runner.setExit(0, for: "stop")
        await model.monitorSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(model.needsRecovery)

        deliverOpenEvent(kAEReopenApplication)
        let settings = try XCTUnwrap(app.windows.first { !originalWindows.contains($0.windowNumber) && $0.isVisible })
        XCTAssertEqual(app.activationPolicy(), .regular)
        settings.close()
        XCTAssertEqual(app.activationPolicy(), .accessory)
        deliverOpenEvent(kAEReopenApplication)
        XCTAssertTrue(settings.isVisible)
        settings.close()
        XCTAssertEqual(app.activationPolicy(), .accessory)
        session.readState = { .locked }
        await hotKey.handlePress(EventHotKeyID(signature: 0x4C494441, id: hotKey.registrationID))
        XCTAssertEqual(session.phase, .locked, "Closing settings must not stop listening")
        XCTAssertFalse(settings.isVisible)
        try await model.perform(.stop)
    }

    func testManualLaunchRegistersStartupAfterShortcutAndShowsSettings() async throws {
        let app = NSApplication.shared
        let originalWindows = Set(app.windows.map(\.windowNumber))
        let policy = app.activationPolicy()
        defer {
            for window in app.windows where !originalWindows.contains(window.windowNumber) { window.close() }
            app.setActivationPolicy(policy)
        }
        let hotKey = GlobalHotKey(register: FakeHotKeyRegistry().register)
        Preferences().save(to: defaults)
        model = makeModel(hotKey: hotKey)
        var registrations = 0
        let delegate = AppDelegate(model: model, registerLoginItem: { _ in
            XCTAssertNotNil(hotKey.key, "Hotkey must register before service setup or window creation")
            XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
            registrations += 1
        })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(Set(app.windows.map(\.windowNumber)), originalWindows)
        let firstRefresh = expectation(description: "Opening settings starts diagnostic refresh")
        await runner.onNextRegistrationCheck { firstRefresh.fulfill() }
        deliverOpenEvent(kAEOpenApplication)
        XCTAssertTrue(app.windows.contains { !originalWindows.contains($0.windowNumber) && $0.isVisible })
        await fulfillment(of: [firstRefresh], timeout: 2)
    }

    func testQuitWhileBusyPreservesTheActiveOperationResult() async throws {
        let delegate = AppDelegate(model: model, registerLoginItem: { _ in XCTFail("Unexpected registration") })
        for diagnostic in [nil, FailureCode.shortcut] {
            await runner.reset()
            session.requestLock = {
                XCTAssertTrue(self.model.isBusy)
                self.model.failure = diagnostic.map { AppFailure(code: $0) }
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
                XCTAssertEqual(self.model.failure?.code, diagnostic, "Rejected quit must preserve existing diagnostics")
            }
            try await model.perform(.start)
            XCTAssertEqual(session.phase, .locked)
            XCTAssertFalse(model.isBusy)
            XCTAssertEqual(model.failure?.code, diagnostic, "No stale busy error may remain after success")
            let calls = await runner.actions
            XCTAssertEqual(calls, ["_start"], "Rejected quit must not start a second power operation")
        }
    }

    // Route through the registered handler rather than calling the delegate directly.
    private func deliverOpenEvent(_ id: AEEventID, reason: NSAppleEventDescriptor? = nil) {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let reason { event.setParam(reason, forKeyword: keyAEPropData) }
        var reply = AppleEvent()
        defer { AEDisposeDesc(&reply) }
        var context = 0
        withUnsafeMutablePointer(to: &context) { pointer in
            XCTAssertEqual(NSAppleEventManager.shared().dispatchRawAppleEvent(event.aeDesc!,
                withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(pointer)), 0)
        }
    }

}
