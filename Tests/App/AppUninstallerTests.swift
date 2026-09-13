import XCTest

@MainActor
final class AppUninstallerTests: XCTestCase {
    func testFinderReceivesValidatedBundleWithoutDeletingIt() throws {
        let fixture = try TestApplicationBundle()
        defer { fixture.cleanUp() }
        var shown: [URL] = []
        let uninstaller = AppUninstaller(applicationURL: fixture.app,
            showInFinder: { shown = $0 }, terminate: { XCTFail("Reveal must not terminate") })
        try uninstaller.reveal()
        XCTAssertEqual(shown, [fixture.app])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

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

    func testInvalidTargetsAreRejectedBeforeFinderHandoff() throws {
        let fixture = try TestApplicationBundle()
        let other = try TestApplicationBundle(identifier: "example.other")
        defer { fixture.cleanUp(); other.cleanUp() }
        let link = fixture.root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.app)
        for url in [fixture.root, URL(fileURLWithPath: "/"), link, other.app,
                    fixture.root.appendingPathComponent("missing.app")] {
            let uninstaller = AppUninstaller(applicationURL: url,
                showInFinder: { _ in XCTFail("Invalid target") })
            XCTAssertThrowsError(try uninstaller.validateTarget()) {
                XCTAssertEqual(($0 as? AppFailure)?.code, .invalidTarget)
            }
            XCTAssertThrowsError(try uninstaller.reveal()) {
                XCTAssertEqual(($0 as? AppFailure)?.code, .invalidTarget)
            }
        }
    }
}
