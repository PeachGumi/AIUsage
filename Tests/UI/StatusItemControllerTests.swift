import AppKit
import XCTest
@testable import AIUsage

final class StatusItemControllerTests: XCTestCase {
    @MainActor
    func testAppearanceObservationTargetsApplicationInsteadOfStatusButton() {
        let application = NSApplication.shared
        let button = NSButton()

        let target = StatusItemController.appearanceObservationTarget(
            application: application)

        XCTAssertTrue(target === application)
        XCTAssertFalse(target === button)
    }
}
