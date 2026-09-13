import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    enum Suspension: Hashable { case editing, locking, uninstalling }
    typealias Registration = (HotKey, EventHotKeyID) throws -> (() -> Void)

    private(set) var key: HotKey?
    private var suspensions: Set<Suspension> = []
    private var isSuspended: Bool { !suspensions.isEmpty }
    private let registerHotKey: Registration
    private var unregisterHotKey: (() -> Void)?
    private var handler: EventHandlerRef?
    private(set) var registrationID: UInt32 = 0
    var onPress: (() async -> Void)?

    init(register: Registration? = nil) {
        registerHotKey = register ?? Self.registerSystemHotKey
        // Injected registrars are driven by tests directly, without OS events.
        guard register == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in await hotKey.handlePress(identifier) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replace only after capture has ended. Suspensions never probe/reserve keys.
    /// A rejected replacement keeps the old assignment.
    func setKey(_ key: HotKey?) throws {
        guard !isSuspended else { throw AppFailure(code: .busy) }
        do {
            try register(key)
            self.key = key
        } catch {
            let failure = error
            do { try register(self.key) }
            catch {
                throw AppFailure(code: .shortcut, detail: L10n.text("%@ 元のショートカットの復元にも失敗しました：%@", failure.localizedDescription, error.localizedDescription))
            }
            throw failure
        }
    }

    /// Resume only after every owner has finished, regardless of completion order.
    func setSuspended(_ suspended: Bool, for reason: Suspension) throws {
        let wasSuspended = isSuspended
        if suspended { suspensions.insert(reason) }
        else { suspensions.remove(reason) }
        guard wasSuspended != isSuspended else { return }
        try register(isSuspended ? nil : key)
    }

    private func register(_ key: HotKey?) throws {
        // Invalidate events already queued by the old registration, including
        // those delivered after recording has finished and the key is restored.
        registrationID &+= 1
        unregisterHotKey?()
        unregisterHotKey = nil
        guard let key else { return }
        let identifier = EventHotKeyID(signature: 0x4C494441, id: registrationID)
        unregisterHotKey = try registerHotKey(key, identifier)
    }

    private static func registerSystemHotKey(_ key: HotKey, _ identifier: EventHotKeyID) throws -> (() -> Void) {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(key.keyCode, key.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
            throw AppFailure(code: .shortcut, detail: "OSStatus: \(result)")
        }
        return { UnregisterEventHotKey(reference) }
    }

    func handlePress(_ identifier: EventHotKeyID) async {
        guard !isSuspended, unregisterHotKey != nil, identifier.signature == 0x4C494441,
              identifier.id == registrationID else { return }
        await onPress?()
    }

    deinit {
        unregisterHotKey?()
        if let handler { RemoveEventHandler(handler) }
    }
}
