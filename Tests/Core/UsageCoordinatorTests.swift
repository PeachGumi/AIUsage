import XCTest
@testable import AIUsage

@MainActor
final class UsageCoordinatorTests: XCTestCase {
    func testDuplicateProviderInstancesFetchAndStoreIndependentSnapshots() async throws {
        let personal = ProviderInstance(provider: .codex, accountLabel: "Personal")
        let work = ProviderInstance(provider: .codex, accountLabel: "Work")
        let personalRuntime = StubProvider(
            id: .codex,
            result: .success(try snapshot(provider: .codex, used: 20)))
        let workRuntime = StubProvider(
            id: .codex,
            result: .success(try snapshot(provider: .codex, used: 70)))
        let runtimes: [UUID: any UsageProvider] = [
            personal.id: personalRuntime,
            work.id: workRuntime
        ]
        let coordinator = UsageCoordinator(instances: [personal, work]) { runtimes[$0.id]! }

        await coordinator.refreshAll()

        XCTAssertEqual(coordinator.snapshots[personal.id]?.windows.first?.usedPercent, 20)
        XCTAssertEqual(coordinator.snapshots[work.id]?.windows.first?.usedPercent, 70)
        XCTAssertEqual(coordinator.authenticationStates[personal.id], .authenticated)
        XCTAssertEqual(coordinator.authenticationStates[work.id], .authenticated)
    }

    func testRefreshingOneDuplicateDoesNotTouchSibling() async throws {
        let first = ProviderInstance(provider: .qwen)
        let second = ProviderInstance(provider: .qwen)
        let firstRuntime = SequencedProvider(
            id: .qwen,
            results: [
                .success(try snapshot(provider: .qwen, used: 10)),
                .success(try snapshot(provider: .qwen, used: 30))
            ])
        let secondRuntime = CountingProvider(id: .qwen, used: 80)
        let runtimes: [UUID: any UsageProvider] = [first.id: firstRuntime, second.id: secondRuntime]
        let coordinator = UsageCoordinator(instances: [first, second]) { runtimes[$0.id]! }

        await coordinator.refreshAll()
        XCTAssertEqual(secondRuntime.fetchCount, 1)
        await coordinator.refresh(first.id)

        XCTAssertEqual(coordinator.snapshots[first.id]?.windows.first?.usedPercent, 30)
        XCTAssertEqual(coordinator.snapshots[second.id]?.windows.first?.usedPercent, 80)
        XCTAssertEqual(secondRuntime.fetchCount, 1)
    }

    func testRemovingOneDuplicateClearsOnlyThatAccountState() async throws {
        let first = ProviderInstance(provider: .codex)
        let second = ProviderInstance(provider: .codex)
        let runtimes: [UUID: any UsageProvider] = [
            first.id: CountingProvider(id: .codex, used: 15),
            second.id: CountingProvider(id: .codex, used: 55)
        ]
        let coordinator = UsageCoordinator(instances: [first, second]) { runtimes[$0.id]! }
        await coordinator.refreshAll()

        coordinator.setEnabledProviders([second])

        XCTAssertNil(coordinator.snapshots[first.id])
        XCTAssertNil(coordinator.authenticationStates[first.id])
        XCTAssertNotNil(coordinator.snapshots[second.id])
        XCTAssertEqual(coordinator.authenticationStates[second.id], .authenticated)
    }

    func testFailureAndAuthenticationStateAreScopedToOneAccount() async throws {
        let healthy = ProviderInstance(provider: .qwen)
        let signedOut = ProviderInstance(provider: .qwen)
        let runtimes: [UUID: any UsageProvider] = [
            healthy.id: StubProvider(id: .qwen, result: .success(try snapshot(provider: .qwen, used: 25))),
            signedOut.id: StubProvider(id: .qwen, result: .failure(TestAuthenticationError.required))
        ]
        let coordinator = UsageCoordinator(instances: [healthy, signedOut]) { runtimes[$0.id]! }

        await coordinator.refreshAll()

        XCTAssertEqual(coordinator.authenticationStates[healthy.id], .authenticated)
        XCTAssertNil(coordinator.errors[healthy.id])
        XCTAssertEqual(coordinator.authenticationStates[signedOut.id], .required)
        XCTAssertNotNil(coordinator.errors[signedOut.id])
        XCTAssertNil(coordinator.snapshots[signedOut.id])
    }

    func testFailedRefreshRetainsOnlyThatAccountsLastValidSnapshot() async throws {
        let instance = ProviderInstance(provider: .codex)
        let initial = try snapshot(provider: .codex, used: 10)
        let runtime = SequencedProvider(id: .codex, results: [.success(initial), .failure(TestError.failed)])
        let coordinator = UsageCoordinator(instances: [instance]) { _ in runtime }

        await coordinator.refresh(instance.id)
        await coordinator.refresh(instance.id)

        XCTAssertEqual(coordinator.snapshots[instance.id], initial)
        XCTAssertNotNil(coordinator.errors[instance.id])
        XCTAssertEqual(coordinator.authenticationStates[instance.id], .authenticated)
    }

    func testMarkSignedOutClearsOnlySelectedAccount() async throws {
        let first = ProviderInstance(provider: .qwen)
        let second = ProviderInstance(provider: .qwen)
        let runtimes: [UUID: any UsageProvider] = [
            first.id: CountingProvider(id: .qwen, used: 12),
            second.id: CountingProvider(id: .qwen, used: 8)
        ]
        let coordinator = UsageCoordinator(instances: [first, second]) { runtimes[$0.id]! }
        await coordinator.refreshAll()

        coordinator.markSignedOut(first.id, message: "Sign in required")

        XCTAssertNil(coordinator.snapshots[first.id])
        XCTAssertEqual(coordinator.errors[first.id], "Sign in required")
        XCTAssertEqual(coordinator.authenticationStates[first.id], .required)
        XCTAssertNotNil(coordinator.snapshots[second.id])
        XCTAssertEqual(coordinator.authenticationStates[second.id], .authenticated)
    }

    func testCoordinatorIgnoresDuplicateInstanceIdentityInsteadOfTrapping() async {
        let id = UUID()
        let first = ProviderInstance(id: id, provider: .codex, accountLabel: "First")
        let duplicate = ProviderInstance(id: id, provider: .qwen, accountLabel: "Duplicate")
        var factoryCalls = 0
        let coordinator = UsageCoordinator(instances: [first, duplicate]) { instance in
            factoryCalls += 1
            return CountingProvider(id: instance.provider, used: 44)
        }

        await coordinator.refreshAll()

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(coordinator.instance(id)?.provider, .codex)
        XCTAssertEqual(coordinator.snapshots[id]?.provider, .codex)
    }

    func testExplicitlyEmptyRegistrationCreatesNoProviderRuntime() async {
        var factoryCalls = 0
        let coordinator = UsageCoordinator(instances: []) { instance in
            factoryCalls += 1
            return CountingProvider(id: instance.provider, used: 1)
        }

        await coordinator.refreshAll()

        XCTAssertEqual(factoryCalls, 0)
        XCTAssertTrue(coordinator.snapshots.isEmpty)
        XCTAssertTrue(coordinator.authenticationStates.isEmpty)
    }

    func testAddingDuplicateAfterInitializationCreatesSecondRuntime() async {
        let first = ProviderInstance(provider: .kimi)
        let second = ProviderInstance(provider: .kimi)
        var runtimes: [UUID: CountingProvider] = [:]
        let coordinator = UsageCoordinator(instances: [first]) { instance in
            let runtime = CountingProvider(id: instance.provider, used: instance.id == first.id ? 10 : 90)
            runtimes[instance.id] = runtime
            return runtime
        }

        coordinator.setEnabledProviders([first, second])
        await coordinator.refreshAll()

        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(runtimes[first.id]?.fetchCount, 1)
        XCTAssertEqual(runtimes[second.id]?.fetchCount, 1)
        XCTAssertEqual(coordinator.snapshots[first.id]?.windows.first?.usedPercent, 10)
        XCTAssertEqual(coordinator.snapshots[second.id]?.windows.first?.usedPercent, 90)
    }

    func testRebuildProviderReplacesOnlySelectedAccountRuntime() async {
        let first = ProviderInstance(provider: .cursor)
        let second = ProviderInstance(provider: .cursor)
        var buildCounts: [UUID: Int] = [:]
        var latest: [UUID: CountingProvider] = [:]
        let coordinator = UsageCoordinator(instances: [first, second]) { instance in
            buildCounts[instance.id, default: 0] += 1
            let runtime = CountingProvider(id: instance.provider, used: Double(buildCounts[instance.id]!) * 10)
            latest[instance.id] = runtime
            return runtime
        }

        await coordinator.refreshAll()
        coordinator.rebuildProvider(first.id)
        await coordinator.refresh(first.id)

        XCTAssertEqual(buildCounts[first.id], 2)
        XCTAssertEqual(buildCounts[second.id], 1)
        XCTAssertEqual(coordinator.snapshots[first.id]?.windows.first?.usedPercent, 20)
        XCTAssertEqual(coordinator.snapshots[second.id]?.windows.first?.usedPercent, 10)
        XCTAssertEqual(latest[second.id]?.fetchCount, 1)
    }

    func testRefreshAllStartsDuplicateAccountsWithoutWaitingForEachOther() async {
        let first = ProviderInstance(provider: .codex)
        let second = ProviderInstance(provider: .codex)
        let firstRuntime = GatedProvider(id: .codex)
        let secondRuntime = GatedProvider(id: .codex)
        let runtimes: [UUID: any UsageProvider] = [first.id: firstRuntime, second.id: secondRuntime]
        let coordinator = UsageCoordinator(instances: [first, second]) { runtimes[$0.id]! }

        let refresh = Task { @MainActor in await coordinator.refreshAll() }
        await yieldUntil { firstRuntime.hasEntered && secondRuntime.hasEntered }
        XCTAssertTrue(firstRuntime.hasEntered && secondRuntime.hasEntered)

        firstRuntime.releaseGate()
        secondRuntime.releaseGate()
        await refresh.value
    }

    func testOverlappingRefreshAllRequestsAreCoalesced() async {
        let instance = ProviderInstance(provider: .codex)
        let runtime = GatedProvider(id: .codex)
        let coordinator = UsageCoordinator(instances: [instance]) { _ in runtime }

        let firstRefresh = Task { @MainActor in await coordinator.refreshAll() }
        await yieldUntil { runtime.hasEntered }
        await coordinator.refreshAll()
        XCTAssertEqual(runtime.fetchCount, 1)

        runtime.releaseGate()
        await firstRefresh.value
    }

    func testSignedOutAccountCannotBeRestoredByOlderInflightRefresh() async {
        let instance = ProviderInstance(provider: .qwen)
        let runtime = GatedProvider(id: .qwen)
        let coordinator = UsageCoordinator(instances: [instance]) { _ in runtime }

        let refresh = Task { @MainActor in await coordinator.refresh(instance.id) }
        await yieldUntil { runtime.hasEntered }

        coordinator.markSignedOut(instance.id, message: "Sign in required")
        runtime.releaseGate()
        await refresh.value

        XCTAssertNil(coordinator.snapshots[instance.id])
        XCTAssertEqual(coordinator.errors[instance.id], "Sign in required")
        XCTAssertEqual(coordinator.authenticationStates[instance.id], .required)
        XCTAssertFalse(coordinator.refreshing.contains(instance.id))
    }

    func testReaddedDefaultSlotCannotBeRestoredByOlderInflightRefresh() async {
        let instance = ProviderInstance(
            id: ProviderInstance.legacyID(for: .codex),
            provider: .codex)
        let staleRuntime = GatedProvider(id: .codex)
        let freshRuntime = CountingProvider(id: .codex, used: 90)
        var buildCount = 0
        let coordinator = UsageCoordinator(instances: [instance]) { _ in
            buildCount += 1
            if buildCount == 1 { return staleRuntime }
            return freshRuntime
        }

        let staleRefresh = Task { @MainActor in await coordinator.refresh(instance.id) }
        await yieldUntil { staleRuntime.hasEntered }

        coordinator.setEnabledProviders([])
        coordinator.setEnabledProviders([instance])
        await coordinator.refresh(instance.id)

        staleRuntime.releaseGate()
        await staleRefresh.value

        XCTAssertEqual(buildCount, 2)
        XCTAssertEqual(freshRuntime.fetchCount, 1)
        XCTAssertEqual(coordinator.snapshots[instance.id]?.windows.first?.usedPercent, 90)
        XCTAssertEqual(coordinator.authenticationStates[instance.id], .authenticated)
    }

    private func snapshot(provider: ProviderID, used: Double) throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [try UsageWindow(
                kind: .weekly,
                label: "Weekly",
                usedPercent: used,
                resetsAt: nil,
                resetDescription: nil)],
            fetchedAt: Date())
    }

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
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

@MainActor
private final class CountingProvider: UsageProvider {
    let id: ProviderID
    let used: Double
    private(set) var fetchCount = 0

    init(id: ProviderID, used: Double) {
        self.id = id
        self.used = used
    }

    func fetch() async throws -> ProviderSnapshot {
        fetchCount += 1
        return ProviderSnapshot(
            provider: id,
            planName: nil,
            windows: [try UsageWindow(
                kind: .weekly,
                label: "Weekly",
                usedPercent: used,
                resetsAt: nil,
                resetDescription: nil)],
            fetchedAt: Date())
    }
}

@MainActor
private final class GatedProvider: UsageProvider {
    let id: ProviderID
    private(set) var hasEntered = false
    private(set) var fetchCount = 0
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    init(id: ProviderID) { self.id = id }

    func fetch() async throws -> ProviderSnapshot {
        fetchCount += 1
        if !hasEntered {
            hasEntered = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enteredContinuation = continuation
            }
        }
        return ProviderSnapshot(
            provider: id,
            planName: nil,
            windows: [try UsageWindow(
                kind: .weekly,
                label: "Weekly",
                usedPercent: 50,
                resetsAt: nil,
                resetDescription: nil)],
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

private enum TestAuthenticationError: Error, ProviderAuthenticationError {
    case required
    var requiresAuthentication: Bool { true }
}
