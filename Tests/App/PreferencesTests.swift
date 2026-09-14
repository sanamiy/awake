import XCTest

final class PreferencesTests: XCTestCase {
    func testUnlimitedDurationAndDefaults() throws {
        var value = Preferences()
        XCTAssertEqual(value.minutes, 120)
        XCTAssertEqual(value.minimumBattery, 30)
        XCTAssertEqual(value.hotKey, .standard)
        XCTAssertFalse(value.unlimitedDuration)
        value.unlimitedDuration = true
        XCTAssertEqual(try value.startArguments(), ["_start", "--minutes", "0", "--min-battery", "30"])
        value.unlimitedDuration = false
        XCTAssertEqual(value.minutes, 120)
    }
    func testSavedSettingsAndDisabledKeySurviveReload() throws {
        let name = "dev.lid-awake.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var value = Preferences()
        value.minutes = 45
        value.minimumBattery = 40
        value.hotKey = nil
        value.save(to: defaults)
        XCTAssertEqual(Preferences.load(from: defaults), value)
        XCTAssertNotNil(defaults.data(forKey: Preferences.storageKey))
        XCTAssertEqual(try value.startArguments(), ["_start", "--minutes", "45", "--min-battery", "40"])
    }

    func testCorruptPreferencesFallBackToSafeDefaults() {
        let name = "dev.lid-awake.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not-json".utf8), forKey: Preferences.storageKey)
        XCTAssertEqual(Preferences.load(from: defaults), Preferences())
        defaults.set(Data("{\"minutes\":-10,\"minimumBattery\":101}".utf8), forKey: Preferences.storageKey)
        XCTAssertEqual(Preferences.load(from: defaults), Preferences())
    }

    func testInputBounds() throws {
        let name = "dev.lid-awake.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        // Independent expectations, also exercised against the CLI by test-lid-awake.zsh.
        XCTAssertEqual(Preferences.minutesRange, 1...1440)
        XCTAssertEqual(Preferences.batteryRange, 5...95)
        let cases: [(minutes: Int, battery: Int, valid: Bool)] = [
            (0, 30, true), (-1, 30, false),
            (1, 5, true), (1, 95, true), (1440, 5, true), (1440, 95, true),
            (1441, 30, false), (120, 4, false), (120, 96, false)
        ]
        for input in cases {
            let original = Preferences()
            original.save(to: defaults)
            var value = Preferences()
            value.minutes = input.minutes
            value.minimumBattery = input.battery
            if input.valid {
                XCTAssertNoThrow(try value.startArguments(), "\(input)")
                value.save(to: defaults)
                XCTAssertEqual(Preferences.load(from: defaults), value, "\(input)")
            } else {
                XCTAssertThrowsError(try value.startArguments(), "\(input)") {
                    XCTAssertEqual(($0 as? AppFailure)?.code, .invalidInput)
                }
                value.save(to: defaults)
                XCTAssertEqual(Preferences.load(from: defaults), original, "Invalid saves must preserve settings")
                // Simulate out-of-range data written outside the save boundary.
                defaults.set(try JSONEncoder().encode(value), forKey: Preferences.storageKey)
                XCTAssertEqual(Preferences.load(from: defaults), Preferences(), "\(input)")
            }
        }
    }
}
