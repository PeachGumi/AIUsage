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

final class QuotaRecoveryDetectorTests: XCTestCase {
    func testDoesNotNotifyOnInitialFullQuota() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let snapshot = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0)])

        let events = detector.observe(
            snapshots: [instance.id: snapshot],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertTrue(events.isEmpty)
    }

    func testNotifiesForRequestedNinetyNinePointNineToOneHundredTransition() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let ninetyNinePointNineRemaining = try quotaSnapshot(
            provider: .openCodeGo,
            windows: [(.fiveHour, 0.1)])
        let full = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0)])

        let remaining = try XCTUnwrap(ninetyNinePointNineRemaining.windows.first?.remainingPercent)
        XCTAssertEqual(remaining, 99.9, accuracy: 0.000_001)
        XCTAssertTrue(detector.observe(
            snapshots: [instance.id: ninetyNinePointNineRemaining],
            instanceLookup: { $0 == instance.id ? instance : nil }).isEmpty)

        let events = detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.accountTitle, "OpenCode Go")
        XCTAssertEqual(events.first?.windowKind, .fiveHour)
        XCTAssertEqual(events.first?.message, "5時間利用量が回復しました！")
    }

    func testDoesNotNotifyUntilQuotaActuallyReachesFull() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let first = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0.2)])
        let second = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0.1)])

        _ = detector.observe(
            snapshots: [instance.id: first],
            instanceLookup: { $0 == instance.id ? instance : nil })
        let events = detector.observe(
            snapshots: [instance.id: second],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertTrue(events.isEmpty)
    }

    func testDoesNotRepeatWhileQuotaStaysFull() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 25)])
        let full = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0)])

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

    func testCanNotifyAgainAfterQuotaIsConsumedAgain() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 10)])
        let full = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0)])

        _ = detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil })
        XCTAssertEqual(detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil }).count, 1)
        XCTAssertTrue(detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil }).isEmpty)

        let secondRecovery = detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertEqual(secondRecovery.count, 1)
        XCTAssertEqual(secondRecovery.first?.windowKind, .fiveHour)
    }

    func testTracksQuotaWindowsIndependentlyAndInStableOrder() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(
            provider: .openCodeGo,
            windows: [(.monthly, 0), (.weekly, 1), (.fiveHour, 0.1)])
        let recovered = try quotaSnapshot(
            provider: .openCodeGo,
            windows: [(.monthly, 0), (.weekly, 0), (.fiveHour, 0)])

        _ = detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil })
        let events = detector.observe(
            snapshots: [instance.id: recovered],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertEqual(events.map(\.windowKind), [.fiveHour, .weekly])
        XCTAssertEqual(events.map(\.message), [
            "5時間利用量が回復しました！",
            "週間利用量が回復しました！",
        ])
    }

    func testTracksDuplicateAccountsIndependently() throws {
        let personal = ProviderInstance(provider: .openCodeGo, accountLabel: "Personal")
        let work = ProviderInstance(provider: .openCodeGo, accountLabel: "Work")
        let partial = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0.1)])
        let full = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0)])
        let instances = [personal.id: personal, work.id: work]
        var detector = QuotaRecoveryDetector()

        _ = detector.observe(
            snapshots: [personal.id: partial, work.id: full],
            instanceLookup: { instances[$0] })
        let events = detector.observe(
            snapshots: [personal.id: full, work.id: full],
            instanceLookup: { instances[$0] })

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.instanceID, personal.id)
        XCTAssertEqual(events.first?.accountTitle, "OpenCode Go · Personal")
    }

    func testResetsBaselineAfterAccountDisappears() throws {
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()
        let partial = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 50)])
        let full = try quotaSnapshot(provider: .openCodeGo, windows: [(.fiveHour, 0)])

        _ = detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil })
        _ = detector.observe(snapshots: [:], instanceLookup: { _ in nil })

        let events = detector.observe(
            snapshots: [instance.id: full],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertTrue(events.isEmpty)
    }

    private func quotaSnapshot(
        provider: ProviderID,
        windows: [(UsageWindowKind, Double)]
    ) throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: try windows.map { kind, usedPercent in
                try UsageWindow(
                    kind: kind,
                    label: label(for: kind),
                    usedPercent: usedPercent,
                    resetsAt: nil,
                    resetDescription: nil)
            },
            fetchedAt: Date())
    }

    private func label(for kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}
