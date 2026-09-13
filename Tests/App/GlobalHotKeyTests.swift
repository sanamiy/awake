import XCTest
import Carbon

/// Registration/state tests use an in-memory registry, never the macOS hotkey service.
@MainActor
final class GlobalHotKeyTests: XCTestCase {
    func testSuspendedAndStaleGlobalEventsCannotTriggerTheAction() async throws {
        let hotKey = GlobalHotKey(register: FakeHotKeyRegistry().register)
        let key = HotKey(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "test")
        try hotKey.setKey(key)
        var presses = 0
        hotKey.onPress = { presses += 1 }
        let old = EventHotKeyID(signature: 0x4C494441, id: hotKey.registrationID)
        await hotKey.handlePress(old)
        XCTAssertEqual(presses, 1)
        try hotKey.setSuspended(true, for: .editing)
        await hotKey.handlePress(old)
        XCTAssertEqual(presses, 1)
        try hotKey.setSuspended(false, for: .editing)
        await hotKey.handlePress(old)
        await hotKey.handlePress(EventHotKeyID(signature: 0, id: hotKey.registrationID))
        XCTAssertEqual(presses, 1)
        await hotKey.handlePress(EventHotKeyID(signature: 0x4C494441, id: hotKey.registrationID))
        XCTAssertEqual(presses, 2)
    }

    func testOverlappingSuspensionsResumeOnlyAfterBothOwnersFinish() async throws {
        for first in [GlobalHotKey.Suspension.editing, .locking] {
            let second: GlobalHotKey.Suspension = first == .editing ? .locking : .editing
            let hotKey = GlobalHotKey(register: FakeHotKeyRegistry().register)
            try hotKey.setKey(testKey())
            var presses = 0
            hotKey.onPress = { presses += 1 }
            try hotKey.setSuspended(true, for: first)
            let suspendedID = hotKey.registrationID
            try hotKey.setSuspended(true, for: second)
            try hotKey.setSuspended(true, for: first)
            try hotKey.setSuspended(false, for: first)
            XCTAssertEqual(hotKey.registrationID, suspendedID, "A remaining owner must keep registration suspended")
            await press(hotKey)
            XCTAssertEqual(presses, 0)
            try hotKey.setSuspended(false, for: second)
            await press(hotKey)
            XCTAssertEqual(presses, 1)
            let resumedID = hotKey.registrationID
            try hotKey.setSuspended(false, for: first)
            XCTAssertEqual(hotKey.registrationID, resumedID, "Repeated lifecycle callbacks must be harmless")
        }
    }

    func testSuspendedKeyChangesAreRejectedWithoutProbingOrChangingTheAssignment() throws {
        var registrations = 0
        let registry = FakeHotKeyRegistry()
        let hotKey = GlobalHotKey(register: { key, identifier in
            registrations += 1
            return try registry.register(key, identifier)
        })
        let original = testKey()
        try hotKey.setKey(original)
        for reason in [GlobalHotKey.Suspension.editing, .locking, .uninstalling] {
            try hotKey.setSuspended(true, for: reason)
            let count = registrations
            XCTAssertThrowsError(try hotKey.setKey(testKey(code: kVK_F19))) {
                XCTAssertEqual(($0 as? AppFailure)?.code, .busy)
            }
            XCTAssertThrowsError(try hotKey.setKey(nil))
            XCTAssertEqual(registrations, count)
            XCTAssertEqual(hotKey.key, original)
            try hotKey.setSuspended(false, for: reason)
        }
    }

    func testRejectedReplacementPreservesOldAssignment() async throws {
        let registry = FakeHotKeyRegistry()
        let owner = GlobalHotKey(register: registry.register)
        let occupied = testKey(code: kVK_F19)
        try owner.setKey(occupied)
        let hotKey = GlobalHotKey(register: registry.register)
        let original = testKey()
        try hotKey.setKey(original)
        var presses = 0
        hotKey.onPress = { presses += 1 }
        XCTAssertThrowsError(try hotKey.setKey(occupied))
        XCTAssertEqual(hotKey.key, original)
        await press(hotKey)
        XCTAssertEqual(presses, 1)
        try hotKey.setKey(nil)
        await press(hotKey)
        XCTAssertNil(hotKey.key)
        XCTAssertEqual(presses, 1)
    }

    func testUninstallSuspensionSurvivesRecordingAndLockCompletion() async throws {
        let hotKey = GlobalHotKey(register: FakeHotKeyRegistry().register)
        try hotKey.setKey(testKey())
        hotKey.onPress = { XCTFail("No action is allowed after uninstall") }
        try hotKey.setSuspended(true, for: .editing)
        try hotKey.setSuspended(true, for: .locking)
        try hotKey.setSuspended(true, for: .uninstalling)
        try hotKey.setSuspended(false, for: .editing)
        try hotKey.setSuspended(false, for: .locking)
        await press(hotKey)
    }

    private func testKey(code: Int = kVK_F18) -> HotKey {
        HotKey(keyCode: UInt32(code), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "test")
    }

    private func press(_ hotKey: GlobalHotKey) async {
        await hotKey.handlePress(EventHotKeyID(signature: 0x4C494441, id: hotKey.registrationID))
    }}
