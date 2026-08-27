import Combine
import Foundation

@MainActor
protocol UsageProvider: AnyObject {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
    func cancelActiveFetch()
}

extension UsageProvider {
    func cancelActiveFetch() {}
}

struct ProviderFailure: Error, Equatable, Sendable {
    let message: String
}

struct ProviderFetchOutcome: Sendable {
    let provider: ProviderID
    let result: Result<ProviderSnapshot, ProviderFailure>
}

@MainActor
final class UsageCoordinator: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var errors: [ProviderID: String] = [:]
    @Published private(set) var refreshing: Set<ProviderID> = []

    private let providers: [ProviderID: any UsageProvider]
    private var generations: [ProviderID: Int] = [:]
    private var lastRefreshAllAt: Date?

    init(providers: [any UsageProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    func refreshAll() async {
        for id in providers.keys {
            await refresh(id)
        }
        lastRefreshAllAt = Date()
    }

    func refresh(_ id: ProviderID) async {
        guard let provider = providers[id] else { return }
        generations[id, default: 0] += 1
        let generation = generations[id]!
        refreshing.insert(id)
        provider.cancelActiveFetch()
        let outcome: ProviderFetchOutcome
        do {
            outcome = ProviderFetchOutcome(provider: id, result: .success(try await provider.fetch()))
        } catch is CancellationError {
            outcome = ProviderFetchOutcome(provider: id, result: .failure(ProviderFailure(message: "Cancelled")))
        } catch {
            outcome = ProviderFetchOutcome(provider: id, result: .failure(ProviderFailure(message: error.localizedDescription)))
        }
        // A newer refresh or a sign-out superseded this request: drop it so
        // stale results never overwrite newer state.
        guard generations[id] == generation else { return }
        apply(outcome)
        refreshing.remove(id)
    }

    func provider(_ id: ProviderID) -> (any UsageProvider)? {
        providers[id]
    }

    func markSignedOut(_ id: ProviderID, message: String) {
        generations[id, default: 0] += 1
        providers[id]?.cancelActiveFetch()
        snapshots.removeValue(forKey: id)
        errors[id] = message
        refreshing.remove(id)
    }

    func refreshIfStale(olderThan interval: TimeInterval) async {
        if let last = lastRefreshAllAt, Date().timeIntervalSince(last) < interval { return }
        await refreshAll()
    }

    private func apply(_ outcome: ProviderFetchOutcome) {
        switch outcome.result {
        case let .success(snapshot):
            snapshots[outcome.provider] = snapshot
            errors.removeValue(forKey: outcome.provider)
        case let .failure(error):
            errors[outcome.provider] = error.message
        }
    }
}
