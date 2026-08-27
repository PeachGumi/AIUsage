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
    let provider: ProviderID
    let result: Result<ProviderSnapshot, ProviderFailure>
}

@MainActor
final class UsageCoordinator: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var errors: [ProviderID: String] = [:]
    @Published private(set) var refreshing: Set<ProviderID> = []
    @Published private(set) var authenticationStates: [ProviderID: ProviderAuthenticationState] = [:]

    private let providers: [ProviderID: any UsageProvider]
    private var enabledProviderIDs: Set<ProviderID>
    private var generations: [ProviderID: Int] = [:]
    private var lastRefreshAllAt: Date?
    private var refreshAllInProgress = false

    /// `enabledProviders == nil` keeps the historical/test behavior of enabling
    /// every supplied implementation. The app passes the user's explicit
    /// registrations so a fresh install performs no provider requests.
    init(providers: [any UsageProvider], enabledProviders: [ProviderID]? = nil) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let implementedIDs = Set(self.providers.keys)
        if let enabledProviders {
            enabledProviderIDs = Set(enabledProviders).intersection(implementedIDs)
        } else {
            enabledProviderIDs = implementedIDs
        }
        authenticationStates = Dictionary(
            uniqueKeysWithValues: enabledProviderIDs.map { ($0, ProviderAuthenticationState.unknown) })
    }

    /// Applies the user's current registration set. Removing a provider also
    /// cancels in-flight work and drops its cached presentation state without
    /// touching provider credentials/session storage.
    func setEnabledProviders(_ ids: [ProviderID]) {
        let next = Set(ids).intersection(Set(providers.keys))
        let removed = enabledProviderIDs.subtracting(next)
        let added = next.subtracting(enabledProviderIDs)
        for id in removed {
            generations[id, default: 0] += 1
            providers[id]?.cancelActiveFetch()
            snapshots.removeValue(forKey: id)
            errors.removeValue(forKey: id)
            refreshing.remove(id)
            authenticationStates.removeValue(forKey: id)
        }
        for id in added {
            authenticationStates[id] = .unknown
        }
        enabledProviderIDs = next
    }

    /// Starts every registered provider independently so a slow WebView/network
    /// provider cannot delay the others. Re-entrant full refresh requests are
    /// coalesced; individual provider refreshes can still supersede their own
    /// in-flight request through the generation mechanism below.
    func refreshAll() async {
        guard !refreshAllInProgress else { return }
        refreshAllInProgress = true
        defer {
            refreshAllInProgress = false
            lastRefreshAllAt = Date()
        }

        let tasks = enabledProviderIDs.map { id in
            Task { @MainActor [weak self] in
                await self?.refresh(id)
            }
        }
        for task in tasks {
            await task.value
        }
    }

    func refresh(_ id: ProviderID) async {
        guard enabledProviderIDs.contains(id), let provider = providers[id] else { return }
        generations[id, default: 0] += 1
        let generation = generations[id]!
        refreshing.insert(id)
        provider.cancelActiveFetch()
        let outcome: ProviderFetchOutcome
        do {
            outcome = ProviderFetchOutcome(provider: id, result: .success(try await provider.fetch()))
        } catch is CancellationError {
            outcome = ProviderFetchOutcome(
                provider: id,
                result: .failure(ProviderFailure(message: "Cancelled", requiresAuthentication: false)))
        } catch {
            let authError = error as? any ProviderAuthenticationError
            outcome = ProviderFetchOutcome(
                provider: id,
                result: .failure(ProviderFailure(
                    message: error.localizedDescription,
                    requiresAuthentication: authError?.requiresAuthentication == true)))
        }
        // A newer refresh, provider removal, or sign-out superseded this
        // request: drop it so stale results never overwrite newer state.
        guard generations[id] == generation, enabledProviderIDs.contains(id) else { return }
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
        if enabledProviderIDs.contains(id) {
            authenticationStates[id] = .required
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
            snapshots[outcome.provider] = snapshot
            errors.removeValue(forKey: outcome.provider)
            authenticationStates[outcome.provider] = .authenticated
        case let .failure(error):
            errors[outcome.provider] = error.message
            if error.requiresAuthentication {
                authenticationStates[outcome.provider] = .required
            }
            // Transient failures intentionally leave the previous auth state
            // untouched. A timeout/429/5xx must not turn a Sign out control into
            // a misleading Sign in control while stale usage is still visible.
        }
    }
}
