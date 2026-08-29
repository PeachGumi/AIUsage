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

protocol ProviderAuthenticationError: Error {
    var requiresAuthentication: Bool { get }
}

enum ProviderAuthenticationState: Equatable, Sendable {
    case unknown
    case authenticated
    case required
}

private struct ProviderFailure: Error, Equatable, Sendable {
    let message: String
    let requiresAuthentication: Bool
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

    func setEnabledProviders(_ nextInstances: [ProviderInstance]) {
        let nextByID = Self.uniqueInstances(nextInstances)
        let currentIDs = Set(instances.keys)
        let nextIDs = Set(nextByID.keys)

        for id in currentIDs.subtracting(nextIDs) {
            removeRuntime(id)
        }

        for id in currentIDs.intersection(nextIDs) {
            guard let next = nextByID[id] else { continue }
            if instances[id]?.provider != next.provider {
                replaceRuntime(id, with: next)
            } else {
                instances[id] = next
            }
        }

        for id in nextIDs.subtracting(currentIDs) {
            guard let instance = nextByID[id] else { continue }
            installRuntime(instance)
        }
    }

    func rebuildProvider(_ instanceID: UUID) {
        guard let instance = instances[instanceID] else { return }
        replaceRuntime(instanceID, with: instance)
    }

    func refreshAll() async {
        guard !refreshAllInProgress else { return }
        refreshAllInProgress = true
        defer {
            refreshAllInProgress = false
            lastRefreshAllAt = Date()
        }

        let tasks = instances.keys.map { id in
            Task { @MainActor [weak self] in await self?.refresh(id) }
        }
        for task in tasks { await task.value }
    }

    func refresh(_ instanceID: UUID) async {
        guard let provider = providers[instanceID] else { return }

        let generation = beginFetch(instanceID)
        let result: Result<ProviderSnapshot, ProviderFailure>
        do {
            result = .success(try await provider.fetch())
        } catch is CancellationError {
            result = .failure(ProviderFailure(message: "Cancelled", requiresAuthentication: false))
        } catch {
            result = .failure(Self.failure(from: error))
        }

        guard generations[instanceID] == generation,
              instances[instanceID] != nil else { return }
        apply(result, to: instanceID)
        refreshing.remove(instanceID)
    }

    func instance(_ instanceID: UUID) -> ProviderInstance? { instances[instanceID] }

    func cancelAll() {
        for id in instances.keys { invalidateFetch(id) }
    }

    func markSignedOut(_ instanceID: UUID, message: String) {
        invalidateFetch(instanceID)
        snapshots.removeValue(forKey: instanceID)
        errors[instanceID] = message
        if instances[instanceID] != nil {
            authenticationStates[instanceID] = .required
        }
    }

    func refreshIfStale(olderThan interval: TimeInterval) async {
        guard !refreshAllInProgress else { return }
        if let lastRefreshAllAt,
           Date().timeIntervalSince(lastRefreshAllAt) < interval { return }
        await refreshAll()
    }

    private func installRuntime(_ instance: ProviderInstance) {
        instances[instance.id] = instance
        providers[instance.id] = providerFactory(instance)
        authenticationStates[instance.id] = .unknown
    }

    private func replaceRuntime(_ id: UUID, with instance: ProviderInstance) {
        invalidateFetch(id)
        instances[id] = instance
        providers[id] = providerFactory(instance)
        snapshots.removeValue(forKey: id)
        errors.removeValue(forKey: id)
        authenticationStates[id] = .unknown
    }

    private func removeRuntime(_ id: UUID) {
        invalidateFetch(id)
        providers.removeValue(forKey: id)
        instances.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        errors.removeValue(forKey: id)
        authenticationStates.removeValue(forKey: id)
    }

    private func beginFetch(_ id: UUID) -> Int {
        invalidateFetch(id)
        refreshing.insert(id)
        return generations[id, default: 0]
    }

    private func invalidateFetch(_ id: UUID) {
        generations[id, default: 0] += 1
        providers[id]?.cancelActiveFetch()
        refreshing.remove(id)
    }

    private func apply(
        _ result: Result<ProviderSnapshot, ProviderFailure>,
        to instanceID: UUID
    ) {
        switch result {
        case let .success(snapshot):
            snapshots[instanceID] = snapshot
            errors.removeValue(forKey: instanceID)
            authenticationStates[instanceID] = .authenticated
        case let .failure(error):
            errors[instanceID] = error.message
            if error.requiresAuthentication {
                authenticationStates[instanceID] = .required
            }
        }
    }

    private static func failure(from error: Error) -> ProviderFailure {
        ProviderFailure(
            message: error.localizedDescription,
            requiresAuthentication: (error as? any ProviderAuthenticationError)?.requiresAuthentication == true)
    }

    private static func uniqueInstances(_ values: [ProviderInstance]) -> [UUID: ProviderInstance] {
        values.reduce(into: [:]) { result, instance in
            if result[instance.id] == nil { result[instance.id] = instance }
        }
    }
}

@MainActor
final class FailingUsageProvider: UsageProvider {
    let id: ProviderID
    private let failure: Error

    init(id: ProviderID, failure: Error) {
        self.id = id
        self.failure = failure
    }

    func fetch() async throws -> ProviderSnapshot {
        throw failure
    }
}
