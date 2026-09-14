import XCTest

@MainActor
final class UninstallSystemActionsTests: XCTestCase {
    func testFinderReceivesValidatedBundleWithoutDeletingIt() throws {
        let fixture = try TestApplicationBundle()
        defer { fixture.cleanUp() }
        var shown: [URL] = []
        let uninstaller = UninstallSystemActions(applicationURL: fixture.app,
            showInFinder: { shown = $0 }, terminate: { XCTFail("Reveal must not terminate") })
        try uninstaller.reveal()
        XCTAssertEqual(shown, [fixture.app])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testInvalidTargetsAreRejectedBeforeFinderHandoff() throws {
        let fixture = try TestApplicationBundle()
        let other = try TestApplicationBundle(identifier: "example.other")
        defer { fixture.cleanUp(); other.cleanUp() }
        let link = fixture.root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.app)
        for url in [fixture.root, URL(fileURLWithPath: "/"), link, other.app,
                    fixture.root.appendingPathComponent("missing.app")] {
            let uninstaller = UninstallSystemActions(applicationURL: url,
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
