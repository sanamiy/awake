import Carbon

/// Models collisions within one test, independent of shortcuts on the host Mac.
@MainActor
final class FakeHotKeyRegistry {
    private var occupied: Set<UInt64> = []

    func register(_ key: HotKey, _ identifier: EventHotKeyID) throws -> (() -> Void) {
        let combination = UInt64(key.modifiers) << 32 | UInt64(key.keyCode)
        guard occupied.insert(combination).inserted else {
            throw AppFailure(code: .shortcut, detail: "Fixture shortcut already registered")
        }
        return { self.occupied.remove(combination) }
    }
}
