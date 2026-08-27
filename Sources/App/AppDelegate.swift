import AppKit
import Combine
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let qwenCookies = QwenCookieRepository.shared
    private let workspaceStore = OpenCodeWorkspaceStore()
    private lazy var openCodeProvider = OpenCodeGoProvider(workspaceStore: workspaceStore)
    private lazy var qwenProvider = QwenProvider(cookieSource: { [qwenCookies] url in
        try await qwenCookies.header(for: url)
    })
    private lazy var codexProvider = CodexProvider()

    /// Concrete provider implementations live in one registry. The UI catalog
    /// is ProviderID.allCases, while SettingsStore decides which of these the
    /// user has explicitly registered. Future providers should plug in here
    /// without requiring dashboard-specific branching.
    private lazy var providerImplementations: [any UsageProvider] = [
        codexProvider,
        qwenProvider,
        openCodeProvider,
    ]
    private lazy var coordinator = UsageCoordinator(
        providers: providerImplementations,
        enabledProviders: settings.registeredProviders)
    private lazy var settingsController = SettingsWindowController(settings: settings)
    private var statusController: StatusItemController?
    private var loginControllers: [ProviderID: WebLoginWindowController] = [:]
    private var refreshTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(
            coordinator: coordinator,
            settings: settings,
            actions: makeActions())
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.coordinator.refreshAll() }
        }
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.coordinator.refreshIfStale(olderThan: 120) }
            }
            .store(in: &subscriptions)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.coordinator.refreshIfStale(olderThan: 120) }
            }
            .store(in: &subscriptions)
        Task { await coordinator.refreshAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        for provider in providerImplementations {
            provider.cancelActiveFetch()
        }
    }

    private func makeActions() -> AppActions {
        AppActions(
            addProvider: { [weak self] provider in self?.addProvider(provider) },
            removeProvider: { [weak self] provider in self?.removeProvider(provider) },
            refreshAll: { [weak self] in Task { await self?.coordinator.refreshAll() } },
            refresh: { [weak self] provider in Task { await self?.coordinator.refresh(provider) } },
            login: { [weak self] provider in self?.showLogin(provider) },
            logout: { [weak self] provider in Task { await self?.logout(provider) } },
            openDashboard: { [weak self] provider in self?.openDashboard(provider) },
            showSettings: { [weak self] in self?.settingsController.show() },
            quit: { NSApp.terminate(nil) })
    }

    private func addProvider(_ provider: ProviderID) {
        settings.addProvider(provider)
        coordinator.setEnabledProviders(settings.registeredProviders)
        Task { await coordinator.refresh(provider) }
    }

    private func removeProvider(_ provider: ProviderID) {
        settings.removeProvider(provider)
        coordinator.setEnabledProviders(settings.registeredProviders)
    }

    private func showLogin(_ provider: ProviderID) {
        guard provider != .codex else { openDashboard(.codex); return }
        if let controller = loginControllers[provider] {
            controller.show()
            return
        }
        let controller = WebLoginWindowController(
            provider: provider,
            startURL: loginURL(provider)) { [weak self] url in
                guard let self else { return }
                if provider == .openCodeGo, let id = Self.workspaceID(from: url) {
                    self.workspaceStore.save(id)
                }
                if provider == .qwen { self.qwenCookies.markLoginSucceeded() }
                Task { await self.coordinator.refresh(provider) }
            }
        loginControllers[provider] = controller
        controller.show()
    }

    private static func workspaceID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "workspace"),
              parts.indices.contains(index + 1)
        else { return nil }
        let candidate = parts[index + 1]
        return candidate.hasPrefix("wrk_") ? candidate : nil
    }

    private func logout(_ provider: ProviderID) async {
        switch provider {
        case .qwen:
            await qwenCookies.logout()
            await removeWebsiteData(matching: ["qwencloud.com", "qianwenai.com"])
            coordinator.markSignedOut(.qwen, message: "Qwen Cloud login is required.")
        case .openCodeGo:
            workspaceStore.clear()
            await removeWebsiteData(matching: ["opencode.ai"])
            coordinator.markSignedOut(.openCodeGo, message: "OpenCode login is required.")
        case .codex:
            break
        }
    }

    private func openDashboard(_ provider: ProviderID) {
        NSWorkspace.shared.open(dashboardURL(provider))
    }

    private func loginURL(_ provider: ProviderID) -> URL {
        switch provider {
        case .openCodeGo: URL(string: "https://opencode.ai/auth")!
        case .qwen: dashboardURL(.qwen)
        case .codex: dashboardURL(.codex)
        }
    }

    private func dashboardURL(_ provider: ProviderID) -> URL {
        switch provider {
        case .openCodeGo: workspaceStore.usageURL
        case .qwen: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }

    nonisolated static func websiteDataRecordName(_ recordName: String, matches domain: String) -> Bool {
        let name = recordName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, !domain.isEmpty else { return false }
        return name == domain || name.hasSuffix(".\(domain)")
    }

    private func removeWebsiteData(matching domains: [String]) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let matched = records.filter { record in
            domains.contains { domain in
                Self.websiteDataRecordName(record.displayName, matches: domain)
            }
        }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: matched) { continuation.resume() }
        }
    }
}
