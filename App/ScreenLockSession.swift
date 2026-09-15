import Foundation
import CoreGraphics

/// Sends the system lock shortcut directly, without Apple Events or System Events.
struct DirectScreenLock {
    var hasAccess: () -> Bool = CGPreflightPostEventAccess
    var requestAccess: () -> Bool = CGRequestPostEventAccess
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    func requireAccess() throws {
        guard hasAccess() || requestAccess() else {
            throw AppFailure(code: .screenPermission)
        }
    }

    func requestLock() throws {
        try requireAccess()
        // Allocate both events before posting either. Use a private source so
        // modifiers held during the start shortcut are not inherited.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else {
            throw AppFailure(code: .screenLock, detail: L10n.text("画面ロック用のキー操作を作成できませんでした。"))
        }
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        post(down)
        post(up)
    }
}

enum ScreenLockState: Equatable {
    case locked, unlocked, unknown

    static func current() -> Self {
        decode(CGSessionCopyCurrentDictionary() as? [String: Any], userID: getuid())
    }

    static func decode(_ session: [String: Any]?, userID: uid_t) -> Self {
        guard let session, let owner = session[kCGSessionUserIDKey] as? NSNumber,
              owner.uint32Value == userID else { return .unknown }
        // CGSessionCopyCurrentDictionary is public, but this lock-state key is
        // not a documented contract. Require a positive lock observation before
        // continuing, and fail closed if the session becomes unavailable.
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return .locked }
        guard session[kCGSessionOnConsoleKey] as? Bool == true,
              session[kCGSessionLoginDoneKey] as? Bool == true else { return .unknown }
        return .unlocked
    }

}

/// The app keeps an awake session only after observing a successful screen lock.
/// Dependencies are injectable so tests never lock the screen or change power.
@MainActor
final class ScreenLockSession {
    enum Phase { case idle, awaitingLock, locked, needsStop }
    private(set) var phase: Phase = .idle
    var readState: () -> ScreenLockState = ScreenLockState.current
    var prepareLock: () throws -> Void = { try DirectScreenLock().requireAccess() }
    var requestLock: () throws -> Void = { try DirectScreenLock().requestLock() }
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }

    /// `restore` is the model's complete stop operation: it confirms power restoration
    /// and calls didStop() alongside the other recovery-state updates.
    @discardableResult
    func start(enable: () async throws -> Void, restore: () async throws -> Void) async throws -> AppFailure? {
        // Permission setup must finish before changing the power state.
        try prepareLock()
        phase = .awaitingLock
        do {
            var lockOnlyReason: AppFailure?
            do { try await enable() }
            catch let reason as AppFailure where reason.code == .batteryLow {
                // Only the runtime's battery cutoff permits lock-only fallback.
                // Verify normal sleep first, including any previous awake session.
                try await restore()
                lockOnlyReason = reason
                phase = .awaitingLock
            }
            try requestLock()
            for _ in 0..<24 {
                if readState() == .locked {
                    phase = lockOnlyReason == nil ? .locked : .idle
                    return lockOnlyReason
                }
                try await pause()
            }
            throw AppFailure(code: .screenLock)
        } catch {
            let original = error
            phase = .needsStop
            do { try await restore() }
            catch {
                throw AppFailure(code: .powerRestore, detail: L10n.text("開始時: %@\n解除時: %@", original.localizedDescription, error.localizedDescription))
            }
            throw original
        }
    }

    func didUnlock() {
        if phase == .locked { phase = .needsStop }
    }

    func observe(_ state: ScreenLockState) {
        if phase == .locked, state != .locked { phase = .needsStop }
    }

    // Pure query. Observation latches the request through errors or a rapid relock.
    var needsStop: Bool { phase == .needsStop }

    func didStop() { phase = .idle }
}
