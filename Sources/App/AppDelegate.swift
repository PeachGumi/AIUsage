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
    private lazy var claudeProvider = ClaudeProvider()
    private lazy var antigravityProvider = AntigravityProvider()
    private lazy var copilotProvider = CopilotProvider()
    private lazy var cursorProvider = CursorProvider()
    private lazy var zaiProvider = ZAIProvider()
    private lazy var kimiProvider = KimiProvider()

    /// Concrete provider implementations live in one registry. The Add
    /// Provider UI exposes ProviderID.implemented, while SettingsStore decides
    /// which implementations the user has explicitly registered.
    private lazy var providerImplementations: [any UsageProvider] = [
        codexProvider,
        qwenProvider,
        openCodeProvider,
        claudeProvider,
        antigravityProvider,
        copilotProvider,
        cursorProvider,
        zaiProvider,
        kimiProvider,
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
        // Registration removal is intentionally not sign-out, but any login
        // window opened from the removed card should no longer stay active.
        loginControllers[provider]?.close()
        settings.removeProvider(provider)
        coordinator.setEnabledProviders(settings.registeredProviders)
    }

    private func showLogin(_ provider: ProviderID) {
        switch provider {
        case .openCodeGo, .qwen:
            showWebLogin(provider)
        case .zai:
            promptForZAIKey()
        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi:
            // Authentication for these providers belongs to their official
            // local client. The card normally hides managed-auth controls, but
            // this fallback keeps the action safe if called programmatically.
            openDashboard(provider)
        }
    }

    private func showWebLogin(_ provider: ProviderID) {
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

    private func promptForZAIKey() {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Z_AI_API_KEY"
        let alert = NSAlert()
        alert.messageText = "Set Z.AI Coding Plan API key"
        alert.informativeText = "The key is stored in the macOS Keychain and is sent only to https://api.z.ai for the Coding Plan quota request."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AIUsageSecretStore.save(field.stringValue, account: ZAIProvider.keychainAccount)
            Task { await coordinator.refresh(.zai) }
        } catch {
            showError(title: "Could not save Z.AI API key", error: error)
        }
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
        case .zai:
            try? AIUsageSecretStore.delete(account: ZAIProvider.keychainAccount)
            coordinator.markSignedOut(.zai, message: "Z.AI API key is required.")
        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi:
            // External-client credentials are read-only from AIUsage's point of
            // view and must never be deleted by an AIUsage Sign out action.
            break
        }
    }

    private func openDashboard(_ provider: ProviderID) {
        NSWorkspace.shared.open(dashboardURL(provider))
    }

    private func loginURL(_ provider: ProviderID) -> URL {
        switch provider {
        case .openCodeGo:
            URL(string: "https://opencode.ai/auth")!
        case .qwen:
            dashboardURL(.qwen)
        case .codex, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            dashboardURL(provider)
        }
    }

    private func dashboardURL(_ provider: ProviderID) -> URL {
        switch provider {
        case .openCodeGo:
            workspaceStore.usageURL
        case .qwen:
            URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
        case .codex:
            URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claude:
            URL(string: "https://claude.ai/settings/usage")!
        case .antigravity:
            URL(string: "https://antigravity.google")!
        case .copilot:
            URL(string: "https://github.com/settings/billing")!
        case .cursor:
            URL(string: "https://cursor.com/dashboard?tab=usage")!
        case .zai:
            URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!
        case .kimi:
            URL(string: "https://www.kimi.com/code/console")!
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

    private func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
