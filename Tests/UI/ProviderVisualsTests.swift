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

    func testQuotaRecoveryDetectorDoesNotNotifyOnInitialFullQuota() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let snapshot = try quotaSnapshot(provider: .openCodeGo, usedPercent: 0)

        let events = detector.observe(
            snapshots: [instance.id: snapshot],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertTrue(events.isEmpty)
    }

    func testQuotaRecoveryDetectorNotifiesOnTransitionToFull() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(provider: .openCodeGo, usedPercent: 0.1)
        let full = try quotaSnapshot(provider: .openCodeGo, usedPercent: 0)

        XCTAssertTrue(detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil }).isEmpty)

        let events = detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.accountTitle, "OpenCode Go")
        XCTAssertEqual(events.first?.windowKind, .fiveHour)
        XCTAssertEqual(events.first?.message, "5時間利用量が回復しました！")
    }

    func testQuotaRecoveryDetectorDoesNotRepeatWhileQuotaStaysFull() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(provider: .openCodeGo, usedPercent: 25)
        let full = try quotaSnapshot(provider: .openCodeGo, usedPercent: 0)

        _ = detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil })
        XCTAssertEqual(detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil }).count, 1)

        let repeated = detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertTrue(repeated.isEmpty)
    }

    func testQuotaRecoveryDetectorResetsBaselineAfterAccountDisappears() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(provider: .openCodeGo, usedPercent: 50)
        let full = try quotaSnapshot(provider: .openCodeGo, usedPercent: 0)

        _ = detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil })
        _ = detector.observe(snapshots: [:], instanceLookup: { _ in nil })

        let events = detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertTrue(events.isEmpty)
    }

    private func quotaSnapshot(provider: ProviderID, usedPercent: Double) throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [try UsageWindow(
                kind: .fiveHour,
                label: "5-hour",
                usedPercent: usedPercent,
                resetsAt: nil,
                resetDescription: nil)],
            fetchedAt: Date())
    }
}
