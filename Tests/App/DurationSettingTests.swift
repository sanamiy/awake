import XCTest

final class DurationSettingTests: XCTestCase {
    func testSliderPresetsAndUnlimitedEndpoint() {
        XCTAssertEqual(DurationSetting.presets, [15, 30, 60, 120, 240, 480, 1440, 0])
        for (index, minutes) in DurationSetting.presets.enumerated() {
            XCTAssertEqual(DurationSetting.position(for: minutes), Double(index))
        }
        XCTAssertEqual(DurationSetting.position(for: 1), 0)
        XCTAssertEqual(DurationSetting.position(for: 90), 2)
        XCTAssertEqual(DurationSetting.position(for: 1400), 6)
    }
}
