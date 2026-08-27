import XCTest
@testable import AIUsage

final class ProviderVisualsTests: XCTestCase {
    func testSeverityPaletteUsesMutedGoUsageColors() {
        XCTAssertEqual(ProviderVisuals.severityRGB(.healthy),
                       VisualRGB(red: 0.05, green: 0.45, blue: 0.18))
        XCTAssertEqual(ProviderVisuals.severityRGB(.warning),
                       VisualRGB(red: 0.70, green: 0.42, blue: 0.00))
        XCTAssertEqual(ProviderVisuals.severityRGB(.critical),
                       VisualRGB(red: 0.75, green: 0.08, blue: 0.08))
    }

    func testProviderPaletteUsesConsistentMutedBrightness() {
        XCTAssertEqual(ProviderVisuals.accentRGB(.openCodeGo),
                       VisualRGB(red: 0.00, green: 0.42, blue: 0.48))
        XCTAssertEqual(ProviderVisuals.accentRGB(.qwen),
                       VisualRGB(red: 0.38, green: 0.22, blue: 0.72))
        XCTAssertEqual(ProviderVisuals.accentRGB(.codex),
                       VisualRGB(red: 0.22, green: 0.27, blue: 0.68))
    }
}
