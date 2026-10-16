import AppKit
import XCTest
@testable import AIUsage

final class StatusItemControllerTests: XCTestCase {
    @MainActor
    func testMenuBarTextUsesSystemTemplateForEveryDisplayState() throws {
        for title in ["GO 96%", "CX 5h 20% W 40%", "GO …", "GO !", "AI +"] {
            let image = StatusItemController.renderImage(title: title)
            XCTAssertTrue(image.isTemplate, title)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertEqual(image.size.height, 18)
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

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
