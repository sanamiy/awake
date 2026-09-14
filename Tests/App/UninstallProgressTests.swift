import XCTest

@MainActor
final class UninstallProgressTests: XCTestCase {
    func testProgressSurvivesReopenAndMalformedRecordDoesNotEnableApp() throws {
        let fixture = try TestApplicationBundle()
        defer { fixture.cleanUp() }
        let url = fixture.root.appendingPathComponent("state/progress")
        let progress = UninstallProgress(url: url)
        XCTAssertNil(progress.load())
        for stage in [UninstallProgress.Stage.cleaning, .readyForFinder] {
            try progress.save(stage)
            XCTAssertEqual(UninstallProgress(url: url).load(), stage)
        }
        try Data("invalid".utf8).write(to: url)
        XCTAssertEqual(progress.load(), .cleaning)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(progress.load())
    }

}
