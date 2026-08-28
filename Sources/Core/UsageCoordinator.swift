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

/// Provider-specific errors can opt into this protocol without making Core
/// depend on concrete provider error enums. Authentication state therefore
/// survives ordinary network/upstream failures instead of being inferred from
/// the presence of any error string.
protocol ProviderAuthenticationError: Error {
    var requiresAuthentication: Bool { get }
}

enum ProviderAuthenticationState: Equatable, Sendable {
    case unknown
    case authenticated
    case required
}

struct ProviderFailure: Error, Equatable, Sendable {
    let message: String
    let requiresAuthentication: Bool
}

struct ProviderFetchOutcome: Sendable {
    let instanceID: UUID
    let result: Result<ProviderSnapshot, ProviderFailure>
}

@MainActor
final class UsageCoordinator: ObservableObject {
    @Published private(set) var snapshots: [UUID: ProviderSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var authenticationStates: [UUID: ProviderAuthenticationState] = [:]

    private let providerFactory: (ProviderInstance) -> any UsageProvider
    private var providers: [UUID: any UsageProvider] = [:]
    private var instances: [UUID: ProviderInstance] = [:]
    private var enabledInstanceIDs: Set<UUID> = []
    private var generations: [UUID: Int] = [:]
    private var lastRefreshAllAt: Date?
    private var refreshAllInProgress = false

    init(
        instances: [ProviderInstance],
        providerFactory: @escaping (ProviderInstance) -> any UsageProvider
    ) {
        self.providerFactory = providerFactory
        setEnabledProviders(instances)
    }

    /// Test/backward-compatible initializer for one runtime per provider type.
    /// It creates synthetic instance IDs and should not be used by the app.
    convenience init(providers: [any UsageProvider], enabledProviders: [ProviderID]? = nil) {
        let allowed = enabledProviders.map(Set.init)
        let pairs = providers.compactMap { provider -> (ProviderInstance, any UsageProvider)? in
            if let allowed, !allowed.contains(provider.id) { return nil }
            return (ProviderInstance(provider: provider.id), provider)
        }
        let runtimes = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
        self.init(instances: pairs.map(\.0)) { instance in
            guard let runtime = runtimes[instance.id] else {
                preconditionFailure("Missing test provider runtime for \(instance.id)")
            }
            return runtime
        }
    }

    /// Reconciles the live runtime set with the user's account/card instances.
    /// Removing one duplicate only cancels and clears that UUID; sibling
    /// instances of the same ProviderID remain completely independent.
    func setEnabledProviders(_ nextInstances: [ProviderInstance]) {
        let nextByID = Dictionary(uniqueKeysWithValues: nextInstances.map { ($0.id, $0) })
        let nextIDs = Set(nextByID.keys)
        let removed = enabledInstanceIDs.subtracting(nextIDs)
        let added = nextIDs.subtracting(enabledInstanceIDs)
        let retained = enabledInstanceIDs.intersection(nextIDs)

        for id in removed {
            generations[id, default: 0] += 1
            providers[id]?.cancelActiveFetch()
            providers.removeValue(forKey: id)
            instances.removeValue(forKey: id)
            snapshots.removeValue(forKey: id)
            errors.removeValue(forKey: id)
            refreshing.remove(id)
            authenticationStates.removeValue(forKey: id)
        }

        for id in retained {
            guard let next = nextByID[id] else { continue }
            // Provider type is immutable for normal instances. Defensively
            // rebuild if persisted/corrupt state ever changes it for a UUID.
            if instances[id]?.provider != next.provider {
                generations[id, default: 0] += 1
                providers[id]?.cancelActiveFetch()
                providers[id] = providerFactory(next)
                snapshots.removeValue(forKey: id)
                errors.removeValue(forKey: id)
                refreshing.remove(id)
                authenticationStates[id] = .unknown
            }
            instances[id] = next
        }

        for id in added {
            guard let instance = nextByID[id] else { continue }
            instances[id] = instance
            providers[id] = providerFactory(instance)
            authenticationStates[id] = .unknown
        }

        enabledInstanceIDs = nextIDs
    }

    /// Starts every registered account independently so a slow provider/account
    /// cannot delay any sibling, including another account of the same service.
    func refreshAll() async {
        guard !refreshAllInProgress else { return }
        refreshAllInProgress = true
        defer {
            refreshAllInProgress = false
            lastRefreshAllAt = Date()
        }

        let tasks = enabledInstanceIDs.map { id in
            Task { @MainActor [weak self] in
                await self?.refresh(id)
            }
        }
        for task in tasks {
            await task.value
        }
    }

    func refresh(_ instanceID: UUID) async {
        guard enabledInstanceIDs.contains(instanceID),
              let provider = providers[instanceID] else { return }
        generations[instanceID, default: 0] += 1
        let generation = generations[instanceID]!
        refreshing.insert(instanceID)
        provider.cancelActiveFetch()

        let outcome: ProviderFetchOutcome
        do {
            outcome = ProviderFetchOutcome(
                instanceID: instanceID,
                result: .success(try await provider.fetch()))
        } catch is CancellationError {
            outcome = ProviderFetchOutcome(
                instanceID: instanceID,
                result: .failure(ProviderFailure(message: "Cancelled", requiresAuthentication: false)))
        } catch {
            let authError = error as? any ProviderAuthenticationError
            outcome = ProviderFetchOutcome(
                instanceID: instanceID,
                result: .failure(ProviderFailure(
                    message: error.localizedDescription,
                    requiresAuthentication: authError?.requiresAuthentication == true)))
        }

        // A newer refresh, removal, or sign-out superseded this account fetch.
        guard generations[instanceID] == generation,
              enabledInstanceIDs.contains(instanceID) else { return }
        apply(outcome)
        refreshing.remove(instanceID)
    }

    func provider(_ instanceID: UUID) -> (any UsageProvider)? {
        providers[instanceID]
    }

    func instance(_ instanceID: UUID) -> ProviderInstance? {
        instances[instanceID]
    }

    func markSignedOut(_ instanceID: UUID, message: String) {
        generations[instanceID, default: 0] += 1
        providers[instanceID]?.cancelActiveFetch()
        snapshots.removeValue(forKey: instanceID)
        errors[instanceID] = message
        refreshing.remove(instanceID)
        if enabledInstanceIDs.contains(instanceID) {
            authenticationStates[instanceID] = .required
        }
    }

    func refreshIfStale(olderThan interval: TimeInterval) async {
        guard !refreshAllInProgress else { return }
        if let last = lastRefreshAllAt, Date().timeIntervalSince(last) < interval { return }
        await refreshAll()
    }

    private func apply(_ outcome: ProviderFetchOutcome) {
        switch outcome.result {
        case let .success(snapshot):
            snapshots[outcome.instanceID] = snapshot
            errors.removeValue(forKey: outcome.instanceID)
            authenticationStates[outcome.instanceID] = .authenticated
        case let .failure(error):
            errors[outcome.instanceID] = error.message
            if error.requiresAuthentication {
                authenticationStates[outcome.instanceID] = .required
            }
            // Transient failures intentionally leave the previous auth state
            // untouched. A timeout/429/5xx must not turn a Sign out control into
            // a misleading Sign in control while stale usage is still visible.
        }
    }
}
