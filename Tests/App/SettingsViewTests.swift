import XCTest
import AppKit
import SwiftUI

@MainActor
final class SettingsViewTests: AppModelTestCase {
    func testSettingsRenderAtMinimumWidthWithLocalizedError() throws {
        try render(failure: AppFailure(code: .installation), name: "localized-error")
    }

    func testNoticeChangesKeepSettingsGeometryStable() throws {
        let normal = try render(failure: nil, name: "normal")
        let battery = try render(failure: AppFailure(code: .batteryLow, detail: "exit 86"), name: "battery-limit")
        let longError = try render(failure: AppFailure(code: .powerRestore,
            detail: String(repeating: "Diagnostic detail\n", count: 40)), name: "long-error")
        XCTAssertEqual(normal, battery)
        XCTAssertEqual(normal, longError)
    }

    @discardableResult
    private func render(failure: AppFailure?, name: String) throws -> CGRect {
        _ = NSApplication.shared
        model.failure = failure
        let host = NSHostingView(rootView: ContentView(model: model)
            .frame(width: 480, height: 440)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let controls = descendants(host).filter {
            $0 is HotKeyRecorder.RecorderButton || ($0 as? NSTextField)?.isEditable == true
        }
        XCTAssertEqual(controls.count, 1)
        XCTAssertFalse(descendants(host).contains { ($0 as? NSTextField)?.isEditable == true })
        for control in controls {
            let bounds = control.convert(control.bounds, to: host)
            XCTAssertGreaterThanOrEqual(bounds.minX, 24)
            XCTAssertLessThanOrEqual(bounds.maxX, host.bounds.width - 24)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "settings-480-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(host.bounds.width, 480)
        XCTAssertTrue(lifecycleCalls.isEmpty)
        let recorder = try XCTUnwrap(controls.first)
        return recorder.convert(recorder.bounds, to: host)
    }

}
