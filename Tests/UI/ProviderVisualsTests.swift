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
        let expected: [ProviderID: VisualRGB] = [
            .openCodeGo: VisualRGB(red: 0.00, green: 0.42, blue: 0.48),
            .qwen: VisualRGB(red: 0.38, green: 0.22, blue: 0.72),
            .codex: VisualRGB(red: 0.22, green: 0.27, blue: 0.68),
            .claude: VisualRGB(red: 0.61, green: 0.31, blue: 0.18),
            .antigravity: VisualRGB(red: 0.12, green: 0.39, blue: 0.74),
            .copilot: VisualRGB(red: 0.35, green: 0.25, blue: 0.66),
            .cursor: VisualRGB(red: 0.25, green: 0.25, blue: 0.25),
            .zai: VisualRGB(red: 0.04, green: 0.46, blue: 0.34),
            .kimi: VisualRGB(red: 0.69, green: 0.23, blue: 0.49),
        ]

        XCTAssertEqual(Set(expected.keys), Set(ProviderID.implemented))
        for (provider, rgb) in expected {
            XCTAssertEqual(ProviderVisuals.accentRGB(provider), rgb, provider.displayName)
        }
    }

    func testEveryProviderHasTheExpectedAccountAction() {
        let expected: [ProviderID: ProviderAccountAction] = [
            .openCodeGo: .signInOut,
            .qwen: .signInOut,
            .zai: .apiKey,
            .codex: .account,
            .claude: .account,
            .antigravity: .account,
            .copilot: .account,
            .cursor: .account,
            .kimi: .account,
        ]

        XCTAssertEqual(Set(expected.keys), Set(ProviderID.implemented))
        for (provider, action) in expected {
            XCTAssertEqual(provider.accountAction, action, provider.displayName)
        }
    }
}
