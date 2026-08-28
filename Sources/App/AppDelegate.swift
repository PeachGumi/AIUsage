import AppKit
import Combine
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var coordinator = UsageCoordinator(
        instances: settings.registeredProviders,
        providerFactory: { [unowned self] instance in self.makeProvider(for: instance) })
    private lazy var settingsController = SettingsWindowController(settings: settings)
    private var statusController: StatusItemController?
    private var loginControllers: [UUID: WebLoginWindowController] = [:]
    private var qwenRepositories: [UUID: QwenCookieRepository] = [:]
    private var openCodeStores: [UUID: OpenCodeWorkspaceStore] = [:]
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
        for instance in settings.registeredProviders {
            coordinator.provider(instance.id)?.cancelActiveFetch()
        }
    }

    private func makeActions() -> AppActions {
        AppActions(
            addProvider: { [weak self] provider in self?.addProvider(provider) },
            removeProvider: { [weak self] id in self?.removeProvider(id) },
            renameProvider: { [weak self] id in self?.renameProvider(id) },
            refreshAll: { [weak self] in Task { await self?.coordinator.refreshAll() } },
            refresh: { [weak self] id in Task { await self?.coordinator.refresh(id) } },
            login: { [weak self] id in self?.configureOrLogin(id) },
            logout: { [weak self] id in Task { await self?.logout(id) } },
            openDashboard: { [weak self] id in self?.openDashboard(id) },
            showSettings: { [weak self] in self?.settingsController.show() },
            quit: { NSApp.terminate(nil) })
    }

    // MARK: Provider instances

    private func addProvider(_ provider: ProviderID) {
        guard let instance = settings.addProvider(provider) else { return }
        coordinator.setEnabledProviders(settings.registeredProviders)
        Task { await coordinator.refresh(instance.id) }
    }

    private func removeProvider(_ instanceID: UUID) {
        loginControllers[instanceID]?.close()
        loginControllers.removeValue(forKey: instanceID)
        qwenRepositories.removeValue(forKey: instanceID)
        openCodeStores.removeValue(forKey: instanceID)
        settings.removeProvider(instanceID)
        coordinator.setEnabledProviders(settings.registeredProviders)
    }

    private func renameProvider(_ instanceID: UUID) {
        guard let instance = settings.instance(instanceID) else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = instance.accountLabel ?? ""
        field.placeholderString = "e.g. Personal, Work, user@example.com"
        let alert = NSAlert()
        alert.messageText = "Name this account"
        alert.informativeText = "This label is local to AIUsage and helps distinguish multiple \(instance.provider.displayName) accounts."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.renameProvider(instanceID, accountLabel: field.stringValue)
        coordinator.setEnabledProviders(settings.registeredProviders)
    }

    // MARK: Runtime factory

    private func makeProvider(for instance: ProviderInstance) -> any UsageProvider {
        switch instance.provider {
        case .openCodeGo:
            return OpenCodeGoProvider(
                workspaceStore: openCodeStore(for: instance),
                dataStore: websiteDataStore(for: instance))
        case .qwen:
            let repository = qwenRepository(for: instance)
            return QwenProvider(cookieSource: { [repository] url in
                try await repository.header(for: url)
            })
        case .codex:
            if let path = ProviderInstanceAccountStore.credentialPath(for: instance.id) {
                return CodexProvider(authLoader: {
                    try CodexAuth.load(fileURL: URL(fileURLWithPath: path))
                })
            }
            return CodexProvider()
        case .claude:
            if let path = ProviderInstanceAccountStore.credentialPath(for: instance.id) {
                return ClaudeProvider(credentialLoader: {
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
                        throw MajorProviderError.authentication("Claude credential file could not be read.")
                    }
                    return try ClaudeCredential.parse(data: data)
                })
            }
            return ClaudeProvider()
        case .antigravity:
            // The current Antigravity integration consumes the ambient local
            // session. Multiple cards are structurally supported, but distinct
            // Antigravity accounts require distinct upstream sessions/source
            // support before they can return different data.
            return AntigravityProvider()
        case .copilot:
            if let token = try? ProviderInstanceAccountStore.secret(for: instance) {
                return InstanceCopilotProvider(token: token)
            }
            return CopilotProvider()
        case .cursor:
            if let token = try? ProviderInstanceAccountStore.secret(for: instance) {
                return CursorProvider(tokenLoader: { token })
            }
            return CursorProvider()
        case .zai:
            return ZAIProvider(keyLoader: {
                if let value = try ProviderInstanceAccountStore.secret(for: instance) { return value }
                if instance.isLegacyMigratedInstance {
                    return try AIUsageSecretStore.load(account: ZAIProvider.keychainAccount)
                        ?? ProcessInfo.processInfo.environment["Z_AI_API_KEY"]?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            })
        case .kimi:
            if let token = try? ProviderInstanceAccountStore.secret(for: instance) {
                return KimiProvider(credentialLoader: {
                    KimiCredential(token: token, isCLI: false, identityHeaders: [:])
                })
            }
            return KimiProvider()
        }
    }

    // MARK: Account configuration

    private func configureOrLogin(_ instanceID: UUID) {
        guard let instance = settings.instance(instanceID) else { return }
        switch instance.provider {
        case .openCodeGo, .qwen:
            showWebLogin(instance)
        case .zai:
            promptForSecret(
                instance,
                title: "Set Z.AI Coding Plan API key",
                placeholder: "Z_AI_API_KEY",
                explanation: "Stored only in macOS Keychain for this account slot and sent only to api.z.ai.")
        case .kimi:
            promptForSecret(
                instance,
                title: "Set Kimi Code API key",
                placeholder: "KIMI_CODE_API_KEY",
                explanation: "Use a different API key for each Kimi account. The key is stored only in macOS Keychain.")
        case .copilot:
            promptForSecret(
                instance,
                title: "Set GitHub token for this Copilot account",
                placeholder: "GitHub token",
                explanation: "The token is stored only in macOS Keychain for this account slot. Leave this unconfigured to use the ambient GitHub CLI login.")
        case .cursor:
            promptForSecret(
                instance,
                title: "Set Cursor access token for this account",
                placeholder: "Cursor JWT access token",
                explanation: "The token is stored only in macOS Keychain for this account slot. Leave this unconfigured to use Cursor.app's current login.")
        case .codex:
            chooseCredentialFile(
                instance,
                title: "Choose this Codex account's auth.json",
                message: "Select an auth.json from a separate Codex profile. AIUsage reads it in place and never modifies it.")
        case .claude:
            chooseCredentialFile(
                instance,
                title: "Choose this Claude account's credentials file",
                message: "Select a Claude Code .credentials.json for this account. AIUsage reads it in place and never modifies it.")
        case .antigravity:
            let alert = NSAlert()
            alert.messageText = "Antigravity account source"
            alert.informativeText = "AIUsage can add multiple Antigravity cards, but the current Antigravity integration reads the ambient local Antigravity session. Distinct simultaneous Antigravity accounts need an account-scoped remote source; this card will currently follow whichever Antigravity account the local service exposes."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func promptForSecret(
        _ instance: ProviderInstance,
        title: String,
        placeholder: String,
        explanation: String)
    {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = placeholder
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = explanation
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Use default")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        do {
            if response == .alertFirstButtonReturn {
                try ProviderInstanceAccountStore.saveSecret(field.stringValue, for: instance)
            } else if response == .alertSecondButtonReturn {
                try ProviderInstanceAccountStore.deleteSecret(for: instance)
            } else {
                return
            }
            coordinator.rebuildProvider(instance.id)
            Task { await coordinator.refresh(instance.id) }
        } catch {
            showError(title: "Could not update account credential", error: error)
        }
    }

    private func chooseCredentialFile(_ instance: ProviderInstance, title: String, message: String) {
        let choice = NSAlert()
        choice.messageText = title
        choice.informativeText = message
        choice.addButton(withTitle: "Choose file…")
        choice.addButton(withTitle: "Use default")
        choice.addButton(withTitle: "Cancel")

        let response = choice.runModal()
        if response == .alertSecondButtonReturn {
            ProviderInstanceAccountStore.saveCredentialPath("", for: instance.id)
            coordinator.rebuildProvider(instance.id)
            Task { await coordinator.refresh(instance.id) }
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use for this account"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProviderInstanceAccountStore.saveCredentialPath(url.path, for: instance.id)
        coordinator.rebuildProvider(instance.id)
        Task { await coordinator.refresh(instance.id) }
    }

    // MARK: Web account profiles

    private func websiteDataStore(for instance: ProviderInstance) -> WKWebsiteDataStore {
        if instance.isLegacyMigratedInstance { return .default() }
        return WKWebsiteDataStore(forIdentifier: instance.id)
    }

    private func openCodeStore(for instance: ProviderInstance) -> OpenCodeWorkspaceStore {
        if let existing = openCodeStores[instance.id] { return existing }
        let store = OpenCodeWorkspaceStore(
            namespace: instance.isLegacyMigratedInstance ? "default" : instance.id.uuidString,
            allowsLegacyMigration: instance.isLegacyMigratedInstance)
        openCodeStores[instance.id] = store
        return store
    }

    private func qwenRepository(for instance: ProviderInstance) -> QwenCookieRepository {
        if let existing = qwenRepositories[instance.id] { return existing }
        let repository = QwenCookieRepository(
            dataStore: websiteDataStore(for: instance),
            namespace: instance.isLegacyMigratedInstance ? "default" : instance.id.uuidString,
            allowsLegacyMigration: instance.isLegacyMigratedInstance)
        qwenRepositories[instance.id] = repository
        return repository
    }

    private func showWebLogin(_ instance: ProviderInstance) {
        if let controller = loginControllers[instance.id] {
            controller.show()
            return
        }
        let controller = WebLoginWindowController(
            provider: instance.provider,
            accountLabel: instance.accountLabel,
            startURL: loginURL(instance),
            dataStore: websiteDataStore(for: instance)) { [weak self] url in
                guard let self else { return }
                if instance.provider == .openCodeGo, let id = Self.workspaceID(from: url) {
                    self.openCodeStore(for: instance).save(id)
                }
                if instance.provider == .qwen {
                    self.qwenRepository(for: instance).markLoginSucceeded()
                }
                Task { await self.coordinator.refresh(instance.id) }
            }
        loginControllers[instance.id] = controller
        controller.show()
    }

    private static func workspaceID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "workspace"),
              parts.indices.contains(index + 1) else { return nil }
        let candidate = parts[index + 1]
        return candidate.hasPrefix("wrk_") ? candidate : nil
    }

    private func logout(_ instanceID: UUID) async {
        guard let instance = settings.instance(instanceID) else { return }
        switch instance.provider {
        case .qwen:
            let repository = qwenRepository(for: instance)
            await repository.logout()
            await removeWebsiteData(
                matching: ["qwencloud.com", "qianwenai.com"],
                dataStore: repository.dataStore)
            coordinator.markSignedOut(instanceID, message: "Qwen Cloud login is required.")
        case .openCodeGo:
            openCodeStore(for: instance).clear()
            await removeWebsiteData(
                matching: ["opencode.ai"],
                dataStore: websiteDataStore(for: instance))
            coordinator.markSignedOut(instanceID, message: "OpenCode login is required.")
        case .zai:
            try? ProviderInstanceAccountStore.deleteSecret(for: instance)
            if instance.isLegacyMigratedInstance {
                try? AIUsageSecretStore.delete(account: ZAIProvider.keychainAccount)
            }
            coordinator.rebuildProvider(instanceID)
            coordinator.markSignedOut(instanceID, message: "Z.AI API key is required.")
        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi:
            break
        }
    }

    // MARK: Dashboard URLs

    private func openDashboard(_ instanceID: UUID) {
        guard let instance = settings.instance(instanceID) else { return }
        NSWorkspace.shared.open(dashboardURL(instance))
    }

    private func loginURL(_ instance: ProviderInstance) -> URL {
        switch instance.provider {
        case .openCodeGo:
            URL(string: "https://opencode.ai/auth")!
        case .qwen:
            dashboardURL(instance)
        case .codex, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            dashboardURL(instance)
        }
    }

    private func dashboardURL(_ instance: ProviderInstance) -> URL {
        switch instance.provider {
        case .openCodeGo:
            openCodeStore(for: instance).usageURL
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

    private func removeWebsiteData(matching domains: [String], dataStore: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let matched = records.filter { record in
            domains.contains { domain in
                Self.websiteDataRecordName(record.displayName, matches: domain)
            }
        }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: types, for: matched) { continuation.resume() }
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

// MARK: - Per-instance account configuration

@MainActor
enum ProviderInstanceAccountStore {
    private static let defaults = UserDefaults.standard

    static func secretAccount(for instance: ProviderInstance) -> String {
        "provider.\(instance.provider.rawValue).\(instance.id.uuidString).credential"
    }

    static func secret(for instance: ProviderInstance) throws -> String? {
        try AIUsageSecretStore.load(account: secretAccount(for: instance))
    }

    static func saveSecret(_ value: String, for instance: ProviderInstance) throws {
        try AIUsageSecretStore.save(value, account: secretAccount(for: instance))
    }

    static func deleteSecret(for instance: ProviderInstance) throws {
        try AIUsageSecretStore.delete(account: secretAccount(for: instance))
    }

    static func credentialPath(for instanceID: UUID) -> String? {
        let value = defaults.string(forKey: credentialPathKey(instanceID))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func saveCredentialPath(_ path: String, for instanceID: UUID) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.removeObject(forKey: credentialPathKey(instanceID))
        } else {
            defaults.set(value, forKey: credentialPathKey(instanceID))
        }
    }

    private static func credentialPathKey(_ id: UUID) -> String {
        "providerInstance.\(id.uuidString).credentialPath"
    }
}

/// Account-scoped Copilot token runtime. The standard CopilotProvider remains
/// the fallback for the ambient GitHub CLI/environment login.
@MainActor
private final class InstanceCopilotProvider: UsageProvider {
    let id: ProviderID = .copilot
    private let token: String
    private let session = MajorProviderHTTP.session()

    init(token: String) { self.token = token }

    func fetch() async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/copilot_internal/user")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        let data = try await MajorProviderHTTP.checkedData(
            for: request, session: session, provider: "GitHub Copilot")
        return try CopilotProvider.parseUsage(data: data)
    }
}
