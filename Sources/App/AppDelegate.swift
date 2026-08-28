import AppKit
import Combine
import Foundation
@preconcurrency import Network
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
    private var antigravityLoginTasks: [UUID: Task<Void, Never>] = [:]
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
        antigravityLoginTasks.values.forEach { $0.cancel() }
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
        antigravityLoginTasks.removeValue(forKey: instanceID)?.cancel()
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
            // Preserve the old ambient local Antigravity session only for the
            // migrated original card. Every newly added Antigravity card is
            // account-scoped and must have its own Google OAuth credentials;
            // it never silently duplicates the ambient local account.
            if instance.isLegacyMigratedInstance,
               (try? ProviderInstanceAccountStore.antigravityCredentials(for: instance)) == nil {
                return AntigravityProvider()
            }
            return InstanceAntigravityProvider(instance: instance)
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
            configureAntigravityAccount(instance)
        }
    }

    private func configureAntigravityAccount(_ instance: ProviderInstance) {
        if let credentials = try? ProviderInstanceAccountStore.antigravityCredentials(for: instance),
           let credentials {
            let alert = NSAlert()
            alert.messageText = "Antigravity account"
            alert.informativeText = credentials.email.map { "Connected as \($0)." }
                ?? "A Google account is connected to this Antigravity card."
            alert.addButton(withTitle: "Replace account…")
            alert.addButton(withTitle: "Disconnect")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                startAntigravityLogin(instance)
            } else if response == .alertSecondButtonReturn {
                disconnectAntigravityAccount(instance)
            }
            return
        }
        startAntigravityLogin(instance)
    }

    private func startAntigravityLogin(_ instance: ProviderInstance) {
        antigravityLoginTasks.removeValue(forKey: instance.id)?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await AntigravityOAuthLogin.run()
                guard !Task.isCancelled, self.settings.instance(instance.id) != nil else { return }
                try ProviderInstanceAccountStore.saveAntigravityCredentials(credentials, for: instance)
                if let email = credentials.email,
                   Self.isAutomaticAccountLabel(self.settings.instance(instance.id)?.accountLabel) {
                    self.settings.renameProvider(instance.id, accountLabel: email)
                }
                self.coordinator.rebuildProvider(instance.id)
                await self.coordinator.refresh(instance.id)
            } catch is CancellationError {
                // Removing the card or starting another login intentionally
                // cancels the old browser callback session.
            } catch {
                self.showError(title: "Antigravity sign-in failed", error: error)
            }
            self.antigravityLoginTasks.removeValue(forKey: instance.id)
        }
        antigravityLoginTasks[instance.id] = task
    }

    private func disconnectAntigravityAccount(_ instance: ProviderInstance) {
        do {
            try ProviderInstanceAccountStore.deleteAntigravityCredentials(for: instance)
            coordinator.rebuildProvider(instance.id)
            if instance.isLegacyMigratedInstance {
                Task { await coordinator.refresh(instance.id) }
            } else {
                coordinator.markSignedOut(instance.id, message: "Sign in with a Google account for this Antigravity card.")
            }
        } catch {
            showError(title: "Could not disconnect Antigravity account", error: error)
        }
    }

    private static func isAutomaticAccountLabel(_ label: String?) -> Bool {
        guard let label else { return true }
        return label.range(of: #"^Account [0-9]+$"#, options: .regularExpression) != nil
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
        case .antigravity:
            disconnectAntigravityAccount(instance)
        case .codex, .claude, .copilot, .cursor, .kimi:
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

struct AntigravityOAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiryDate: Date?
    var idToken: String?
    var email: String?
    var projectID: String?
    var clientID: String
    var clientSecret: String
}

@MainActor
enum ProviderInstanceAccountStore {
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

    static func antigravityCredentials(for instance: ProviderInstance) throws -> AntigravityOAuthCredentials? {
        guard let raw = try AIUsageSecretStore.load(account: antigravityAccount(for: instance)),
              let data = raw.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
        } catch {
            throw MajorProviderError.local("Antigravity account credentials in Keychain could not be decoded.")
        }
    }

    static func saveAntigravityCredentials(
        _ credentials: AntigravityOAuthCredentials,
        for instance: ProviderInstance) throws
    {
        let data = try JSONEncoder().encode(credentials)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw MajorProviderError.local("Antigravity account credentials could not be encoded.")
        }
        try AIUsageSecretStore.save(raw, account: antigravityAccount(for: instance))
    }

    static func deleteAntigravityCredentials(for instance: ProviderInstance) throws {
        try AIUsageSecretStore.delete(account: antigravityAccount(for: instance))
    }

    static func credentialPath(for instanceID: UUID) -> String? {
        let value = UserDefaults.standard.string(forKey: credentialPathKey(instanceID))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func saveCredentialPath(_ path: String, for instanceID: UUID) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        if value.isEmpty {
            defaults.removeObject(forKey: credentialPathKey(instanceID))
        } else {
            defaults.set(value, forKey: credentialPathKey(instanceID))
        }
    }

    private static func antigravityAccount(for instance: ProviderInstance) -> String {
        "provider.antigravity.\(instance.id.uuidString).oauth"
    }

    private static func credentialPathKey(_ id: UUID) -> String {
        "providerInstance.\(id.uuidString).credentialPath"
    }
}

// MARK: - Antigravity account-scoped remote usage

@MainActor
final class InstanceAntigravityProvider: UsageProvider {
    let id: ProviderID = .antigravity
    private let instance: ProviderInstance
    private let session: URLSession

    init(instance: ProviderInstance, session: URLSession = MajorProviderHTTP.session()) {
        self.instance = instance
        self.session = session
    }

    func fetch() async throws -> ProviderSnapshot {
        guard var credentials = try ProviderInstanceAccountStore.antigravityCredentials(for: instance) else {
            throw MajorProviderError.authentication(
                "Sign in with a Google account for this Antigravity card. Each Antigravity card has an independent account.")
        }

        var refreshed = false
        if Self.shouldRefresh(credentials.expiryDate) {
            credentials = try await refresh(credentials)
            refreshed = true
        }

        do {
            return try await fetchSnapshot(credentials: &credentials)
        } catch let error as MajorProviderError where error.requiresAuthentication && !refreshed {
            guard credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw error
            }
            credentials = try await refresh(credentials)
            return try await fetchSnapshot(credentials: &credentials)
        }
    }

    private func fetchSnapshot(credentials: inout AntigravityOAuthCredentials) async throws -> ProviderSnapshot {
        if credentials.projectID == nil {
            if let project = try? await loadProjectID(accessToken: credentials.accessToken) {
                credentials.projectID = project
                try ProviderInstanceAccountStore.saveAntigravityCredentials(credentials, for: instance)
            }
        }

        let endpoints = [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ]
        var lastError: Error?

        for endpoint in endpoints {
            do {
                let data = try await quotaSummary(
                    endpoint: endpoint,
                    accessToken: credentials.accessToken,
                    projectID: credentials.projectID)
                let normalized = try Self.normalizeRemoteQuotaSummary(data)
                var snapshot = try AntigravityProvider.parseQuotaSummary(data: normalized)
                if snapshot.planName == nil, let email = credentials.email {
                    snapshot = ProviderSnapshot(
                        provider: snapshot.provider,
                        planName: email,
                        windows: snapshot.windows,
                        fetchedAt: snapshot.fetchedAt)
                }
                return snapshot
            } catch let error as MajorProviderError {
                if error.requiresAuthentication { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw MajorProviderError.unavailable("Antigravity remote quota service could not be reached.")
    }

    private func quotaSummary(
        endpoint: String,
        accessToken: String,
        projectID: String?) async throws -> Data
    {
        guard let url = URL(string: endpoint) else {
            throw MajorProviderError.local("Antigravity remote quota URL was invalid.")
        }

        func request(project: String?) throws -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            let body: [String: Any] = project.map { ["project": $0] } ?? [:]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }

        var currentProject = projectID
        var retriedWithoutProject = false
        while true {
            let (data, response) = try await session.data(for: request(project: currentProject))
            guard let http = response as? HTTPURLResponse else {
                throw MajorProviderError.invalidResponse("Antigravity returned a non-HTTP quota response.")
            }
            if http.statusCode == 401 {
                throw MajorProviderError.authentication("Antigravity Google authentication expired. Reconnect this account.")
            }
            if http.statusCode == 403, currentProject != nil, !retriedWithoutProject {
                currentProject = nil
                retriedWithoutProject = true
                continue
            }
            if http.statusCode == 403 {
                throw MajorProviderError.unavailable("Antigravity quota access was denied for this Google account (HTTP 403).")
            }
            guard (200...299).contains(http.statusCode) else {
                throw MajorProviderError.http(provider: "Antigravity", status: http.statusCode)
            }
            return data
        }
    }

    private func loadProjectID(accessToken: String) async throws -> String? {
        guard let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "ANTIGRAVITY"],
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 {
            throw MajorProviderError.authentication("Antigravity Google authentication expired. Reconnect this account.")
        }
        guard (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["cloudaicompanionProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh(_ credentials: AntigravityOAuthCredentials) async throws -> AntigravityOAuthCredentials {
        guard let refreshToken = credentials.refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty else {
            throw MajorProviderError.authentication("Antigravity Google sign-in expired. Reconnect this account.")
        }
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw MajorProviderError.local("Google OAuth token URL was invalid.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MajorProviderError.unavailable("Google OAuth token refresh returned a non-HTTP response.")
        }
        if (400...499).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
            throw MajorProviderError.authentication("Antigravity Google sign-in expired. Reconnect this account.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MajorProviderError.unavailable("Google OAuth token refresh is temporarily unavailable (HTTP \(http.statusCode)).")
        }
        guard let token = try? JSONDecoder().decode(AntigravityRefreshResponse.self, from: data),
              !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MajorProviderError.invalidResponse("Google OAuth returned an invalid Antigravity refresh response.")
        }

        var updated = credentials
        updated.accessToken = token.accessToken
        updated.expiryDate = Date().addingTimeInterval(token.expiresIn ?? 3600)
        if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
            updated.refreshToken = refreshToken
        }
        if let idToken = token.idToken, !idToken.isEmpty {
            updated.idToken = idToken
        }
        try ProviderInstanceAccountStore.saveAntigravityCredentials(updated, for: instance)
        return updated
    }

    nonisolated static func normalizeRemoteQuotaSummary(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawGroups = root["groups"] as? [[String: Any]] else {
            throw MajorProviderError.invalidResponse("Antigravity returned unexpected remote quota-summary data.")
        }

        root["groups"] = rawGroups.map { rawGroup -> [String: Any] in
            var group = rawGroup
            if (group["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let description = group["description"] as? String {
                group["displayName"] = description
            }
            if let rawBuckets = group["buckets"] as? [[String: Any]] {
                group["buckets"] = rawBuckets.map { rawBucket -> [String: Any] in
                    var bucket = rawBucket
                    if bucket["remaining"] == nil, let remaining = bucket["remainingFraction"] {
                        bucket["remaining"] = ["remainingFraction": remaining]
                    }
                    let hints = ["bucketId", "displayName", "window", "description"]
                        .compactMap { bucket[$0] as? String }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !hints.isEmpty {
                        bucket["displayName"] = hints.joined(separator: " ")
                    }
                    return bucket
                }
            }
            return group
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private nonisolated static func shouldRefresh(_ expiryDate: Date?) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSinceNow <= 60
    }

    private nonisolated static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

private struct AntigravityRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: TimeInterval?
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

// MARK: - Antigravity browser OAuth

private struct AntigravityOAuthClient: Sendable {
    let clientID: String
    let clientSecret: String
}

private enum AntigravityOAuthLoginError: LocalizedError, Sendable {
    case missingClient
    case invalidURL
    case browserLaunchFailed
    case timedOut
    case callback(String)
    case tokenExchange(Int)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .missingClient:
            "AIUsage could not find Antigravity's desktop OAuth client. Install Antigravity.app or set ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET."
        case .invalidURL:
            "AIUsage could not build the Antigravity Google sign-in URL."
        case .browserLaunchFailed:
            "AIUsage could not open the Antigravity Google sign-in page."
        case .timedOut:
            "Antigravity Google sign-in timed out. Try again."
        case let .callback(message):
            message
        case let .tokenExchange(status):
            "Google rejected the Antigravity OAuth token exchange (HTTP \(status))."
        case .invalidTokenResponse:
            "Google returned an invalid Antigravity OAuth token response."
        }
    }
}

private enum AntigravityOAuthLogin {
    static func run(timeout: TimeInterval = 300) async throws -> AntigravityOAuthCredentials {
        guard let client = try await AntigravityOAuthClientResolver.resolve() else {
            throw AntigravityOAuthLoginError.missingClient
        }
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = AntigravityOAuthLoopbackServer(expectedState: state)

        return try await withTaskCancellationHandler(operation: {
            let redirectURL = try await server.start()
            defer { server.stop() }
            let authURL = try authorizationURL(client: client, redirectURL: redirectURL, state: state)
            let opened = await MainActor.run { NSWorkspace.shared.open(authURL) }
            guard opened else { throw AntigravityOAuthLoginError.browserLaunchFailed }

            let callback = try await withThrowingTaskGroup(of: AntigravityOAuthCallback.self) { group in
                group.addTask { try await server.waitForCallback() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    server.cancelCallbackWait(with: AntigravityOAuthLoginError.timedOut)
                    throw AntigravityOAuthLoginError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw AntigravityOAuthLoginError.timedOut
                }
                return result
            }

            if let error = callback.error, !error.isEmpty {
                if error == "access_denied" {
                    throw AntigravityOAuthLoginError.callback("Google sign-in was cancelled.")
                }
                throw AntigravityOAuthLoginError.callback("Google OAuth failed: \(error).")
            }
            guard callback.returnedState == state else {
                throw AntigravityOAuthLoginError.callback("Antigravity OAuth state mismatch. Try again.")
            }
            guard let code = callback.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                throw AntigravityOAuthLoginError.callback("Google sign-in did not return an authorization code.")
            }

            let token = try await exchangeCode(code, redirectURL: redirectURL, client: client)
            let email = await fetchEmail(accessToken: token.accessToken)
            return AntigravityOAuthCredentials(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiryDate: Date().addingTimeInterval(token.expiresIn),
                idToken: token.idToken,
                email: email,
                projectID: nil,
                clientID: client.clientID,
                clientSecret: client.clientSecret)
        }, onCancel: {
            server.stop()
        })
    }

    private static func authorizationURL(
        client: AntigravityOAuthClient,
        redirectURL: URL,
        state: String) throws -> URL
    {
        guard let base = URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AntigravityOAuthLoginError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: [
                "https://www.googleapis.com/auth/cloud-platform",
                "https://www.googleapis.com/auth/userinfo.email",
            ].joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw AntigravityOAuthLoginError.invalidURL }
        return url
    }

    private static func exchangeCode(
        _ code: String,
        redirectURL: URL,
        client: AntigravityOAuthClient) async throws -> AntigravityTokenResponse
    {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AntigravityOAuthLoginError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "code": code,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "redirect_uri": redirectURL.absoluteString,
            "grant_type": "authorization_code",
        ])
        let session = MajorProviderHTTP.session()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthLoginError.invalidTokenResponse
        }
        guard http.statusCode == 200 else {
            throw AntigravityOAuthLoginError.tokenExchange(http.statusCode)
        }
        guard let token = try? JSONDecoder().decode(AntigravityTokenResponse.self, from: data),
              !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AntigravityOAuthLoginError.invalidTokenResponse
        }
        return token
    }

    private static func fetchEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let session = MajorProviderHTTP.session()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = (root["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else { return nil }
            return email
        } catch {
            return nil
        }
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

private struct AntigravityTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

private enum AntigravityOAuthClientResolver {
    static func resolve() async throws -> AntigravityOAuthClient? {
        if let environment = fromEnvironment() { return environment }

        let fileManager = FileManager.default
        for artifact in candidateArtifacts(fileManager: fileManager) where fileManager.fileExists(atPath: artifact.path) {
            if let text = try? String(contentsOf: artifact, encoding: .utf8),
               let client = parse(text) {
                return client
            }
            if let text = try? await MajorProviderCommand.run("/usr/bin/strings", [artifact.path]),
               let client = parse(text) {
                return client
            }
        }
        return nil
    }

    private static func fromEnvironment() -> AntigravityOAuthClient? {
        let environment = ProcessInfo.processInfo.environment
        let id = environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]
            ?? environment["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID"]
        let secret = environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]
            ?? environment["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_SECRET"]
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            return nil
        }
        return AntigravityOAuthClient(clientID: id, clientSecret: secret)
    }

    private static func candidateArtifacts(fileManager: FileManager) -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let relativePaths = [
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
            "Contents/MacOS/Gemini",
        ]

        var bundles: [URL] = []
        for root in roots {
            let antigravity = root.appendingPathComponent("Antigravity.app", isDirectory: true)
            if fileManager.fileExists(atPath: antigravity.path) { bundles.append(antigravity) }

            let gemini = root.appendingPathComponent("Gemini.app", isDirectory: true)
            if fileManager.fileExists(atPath: gemini.path),
               ["com.google.antigravity", "com.google.antigravity-ide", "com.google.GeminiMacOS"]
                .contains(Bundle(url: gemini)?.bundleIdentifier ?? "") {
                bundles.append(gemini)
            }
        }
        return bundles.flatMap { bundle in relativePaths.map { bundle.appendingPathComponent($0) } }
    }

    static func parse(_ text: String) -> AntigravityOAuthClient? {
        let ids = matches(#"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#, in: text)
        let secrets = matches(#"GOCSPX-[A-Za-z0-9_-]{28}"#, in: text)
        guard !ids.isEmpty, !secrets.isEmpty else { return nil }

        if secrets.count == 1 {
            guard let id = ids.last else { return nil }
            return AntigravityOAuthClient(clientID: id, clientSecret: secrets[0])
        }
        if ids.count == secrets.count {
            guard let secret = secrets.last else { return nil }
            return AntigravityOAuthClient(clientID: ids[0], clientSecret: secret)
        }
        return AntigravityOAuthClient(clientID: ids[0], clientSecret: secrets[0])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let value = String(text[swiftRange])
            return seen.insert(value).inserted ? value : nil
        }
    }
}

private struct AntigravityOAuthCallback: Sendable {
    let code: String?
    let returnedState: String?
    let error: String?
}

private final class AntigravityOAuthLoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "app.aiusage.antigravity.oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<AntigravityOAuthCallback, Error>?
    private var pendingCallbackResult: Result<AntigravityOAuthCallback, Error>?
    private var callbackCompleted = false

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue,
                          let url = URL(string: "http://127.0.0.1:\(port)/callback") else {
                        self.finishReady(.failure(AntigravityOAuthLoginError.invalidURL))
                        return
                    }
                    self.finishReady(.success(url))
                case let .failed(error):
                    self.finishReady(.failure(error))
                    self.finishCallback(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> AntigravityOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let pending = pendingCallbackResult {
                pendingCallbackResult = nil
                switch pending {
                case let .success(callback): continuation.resume(returning: callback)
                case let .failure(error): continuation.resume(throwing: error)
                }
            } else {
                callbackContinuation = continuation
            }
        }
    }

    func stop() {
        lock.lock()
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
    }

    func cancelCallbackWait(with error: Error) {
        stop()
        finishCallback(.failure(error))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                self.finishCallback(.failure(error))
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete {
                self.receive(on: connection, accumulated: buffer)
                return
            }

            guard let callback = self.parseCallback(from: buffer) else {
                self.sendResponse(connection, success: false, status: "404 Not Found")
                return
            }
            let valid = callback.error == nil && callback.code?.isEmpty == false && callback.returnedState == self.expectedState
            self.sendResponse(connection, success: valid, status: valid ? "200 OK" : "400 Bad Request")
            self.finishCallback(.success(callback))
        }
    }

    private func parseCallback(from data: Data) -> AntigravityOAuthCallback? {
        guard let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/callback" else { return nil }
        let items = components.queryItems ?? []
        return AntigravityOAuthCallback(
            code: items.first(where: { $0.name == "code" })?.value,
            returnedState: items.first(where: { $0.name == "state" })?.value,
            error: items.first(where: { $0.name == "error" })?.value)
    }

    private func sendResponse(_ connection: NWConnection, success: Bool, status: String) {
        let title = success ? "Antigravity account connected" : "Antigravity sign-in failed"
        let detail = success
            ? "You can close this window and return to AIUsage."
            : "You can close this window and try again from AIUsage."
        let html = """
        <html><body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:32px;text-align:center">
        <h1>\(title)</h1><p>\(detail)</p></body></html>
        """
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finishReady(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case let .success(url): continuation.resume(returning: url)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func finishCallback(_ result: Result<AntigravityOAuthCallback, Error>) {
        lock.lock()
        guard !callbackCompleted else {
            lock.unlock()
            return
        }
        callbackCompleted = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        if continuation == nil { pendingCallbackResult = result }
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case let .success(callback): continuation.resume(returning: callback)
        case let .failure(error): continuation.resume(throwing: error)
        }
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
