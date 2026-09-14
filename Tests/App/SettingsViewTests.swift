import XCTest
import AppKit
import SwiftUI

@MainActor
final class SettingsViewTests: AppModelTestCase {
    func testSettingsRenderAtMinimumWidthWithLocalizedError() throws {
        _ = NSApplication.shared
        model.failure = AppFailure(code: .installation)
        let host = NSHostingView(rootView: ContentView(model: model)
            .frame(width: 480, height: 700)
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
        attachment.name = "settings-480-localized-error"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(host.bounds.width, 480)
        XCTAssertTrue(lifecycleCalls.isEmpty)
    }

}
