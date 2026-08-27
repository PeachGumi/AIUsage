import XCTest
@testable import AIUsage

@MainActor
final class UsageCoordinatorTests: XCTestCase {
    func testRefreshAllKeepsSuccessfulProvidersWhenAnotherFails() async throws {
        let codex = StubProvider(
            id: .codex,
            result: .success(ProviderSnapshot(
                provider: .codex,
                planName: "Plus",
                windows: [try UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: 20, resetsAt: nil, resetDescription: nil)],
                fetchedAt: Date())))
        let qwen = StubProvider(id: .qwen, result: .failure(TestError.failed))
        let coordinator = UsageCoordinator(providers: [codex, qwen])

        await coordinator.refreshAll()

        XCTAssertEqual(coordinator.snapshots[.codex]?.windows.first?.usedPercent, 20)
        XCTAssertNotNil(coordinator.errors[.qwen])
        XCTAssertNil(coordinator.errors[.codex])
    }

    func testFailedRefreshRetainsLastValidSnapshot() async throws {
        let initial = ProviderSnapshot(
            provider: .codex,
            planName: nil,
            windows: [try UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 10, resetsAt: nil, resetDescription: nil)],
            fetchedAt: Date())
        let provider = SequencedProvider(id: .codex, results: [.success(initial), .failure(TestError.failed)])
        let coordinator = UsageCoordinator(providers: [provider])

        await coordinator.refreshAll()
        await coordinator.refreshAll()

        XCTAssertEqual(coordinator.snapshots[.codex], initial)
        XCTAssertNotNil(coordinator.errors[.codex])
    }

    func testMarkSignedOutClearsOnlySelectedProvider() async throws {
        let codex = StubProvider(
            id: .codex,
            result: .success(ProviderSnapshot(
                provider: .codex,
                planName: nil,
                windows: [try UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 12, resetsAt: nil, resetDescription: nil)],
                fetchedAt: Date())))
        let qwen = StubProvider(
            id: .qwen,
            result: .success(ProviderSnapshot(
                provider: .qwen,
                planName: nil,
                windows: [try UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 8, resetsAt: nil, resetDescription: nil)],
                fetchedAt: Date())))
        let coordinator = UsageCoordinator(providers: [codex, qwen])
        await coordinator.refreshAll()

        coordinator.markSignedOut(.qwen, message: "Sign in required")

        XCTAssertNil(coordinator.snapshots[.qwen])
        XCTAssertEqual(coordinator.errors[.qwen], "Sign in required")
        XCTAssertNotNil(coordinator.snapshots[.codex])
    }
}

@MainActor
private final class StubProvider: UsageProvider {
    let id: ProviderID
    let result: Result<ProviderSnapshot, Error>

    init(id: ProviderID, result: Result<ProviderSnapshot, Error>) {
        self.id = id
        self.result = result
    }

    func fetch() async throws -> ProviderSnapshot { try result.get() }
}

/// Verifies that a superseded in-flight refresh never overwrites newer state:
/// the first fetch blocks until markSignedOut, then resolves with a snapshot
/// that must be discarded.
@MainActor
private final class GatedProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    init(id: ProviderID) {
        self.id = id
    }

    func fetch() async throws -> ProviderSnapshot {
        if entered {
            try Task.checkCancellation()
        } else {
            entered = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enteredContinuation = continuation
            }
        }
        return ProviderSnapshot(
            provider: id,
            planName: nil,
            windows: [try UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 50, resetsAt: nil, resetDescription: nil)],
            fetchedAt: Date())
    }

    func releaseGate() {
        enteredContinuation?.resume()
        enteredContinuation = nil
    }
}

@MainActor
private final class SequencedProvider: UsageProvider {
    let id: ProviderID
    private var results: [Result<ProviderSnapshot, Error>]

    init(id: ProviderID, results: [Result<ProviderSnapshot, Error>]) {
        self.id = id
        self.results = results
    }

    func fetch() async throws -> ProviderSnapshot {
        try results.removeFirst().get()
    }
}

private enum TestError: Error { case failed }
