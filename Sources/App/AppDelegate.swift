import AppKit
import Combine
import Foundation
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
        Publishers.Merge(
            center.publisher(for: NSApplication.didBecomeActiveNotification),
            center.publisher(for: NSWorkspace.didWakeNotification))
            .sink { [weak self] _ in
                Task { @MainActor in await self?.coordinator.refreshIfStale(olderThan: 120) }
            }
            .store(in: &subscriptions)

        Task { await coordinator.refreshAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        coordinator.cancelAll()
    }

    private func makeActions() -> AppActions {
        AppActions(
            addProvider: { [weak self] provider in self?.addProvider(provider) },
            removeProvider: { [weak self] id in Task { await self?.removeProvider(id) } },
            renameProvider: { [weak self] id in self?.renameProvider(id) },
            refreshAll: { [weak self] in Task { await self?.coordinator.refreshAll() } },
            refresh: { [weak self] id in Task { await self?.coordinator.refresh(id) } },
            configureAccount: { [weak self] id in self?.configureAccount(id) },
            logout: { [weak self] id in Task { await self?.logout(id) } },
            openDashboard: { [weak self] id in self?.openDashboard(id) },
            showSettings: { [weak self] in self?.settingsController.show() },
            quit: { NSApp.terminate(nil) })
    }

    // MARK: - Provider instances

    private func addProvider(_ provider: ProviderID) {
        guard let instance = settings.addProvider(provider) else { return }
        syncProviders()
        Task { await coordinator.refresh(instance.id) }
    }

    private func removeProvider(_ instanceID: UUID) async {
        guard let instance = settings.instance(instanceID) else { return }

        do {
            try ProviderInstanceCredentialStore.deleteSecret(for: instance)
        } catch {
            showError(title: "Could not remove account credential", error: error)
            return
        }

        loginControllers.removeValue(forKey: instanceID)?.close()
        await removeDedicatedWebState(
            for: instance,
            qwenRepository: qwenRepositories.removeValue(forKey: instanceID),
            openCodeStore: openCodeStores.removeValue(forKey: instanceID))
        ProviderInstanceCredentialStore.clearCredentialPath(for: instanceID)
        settings.removeProvider(instanceID)
        syncProviders()
    }

    private func removeDedicatedWebState(
        for instance: ProviderInstance,
        qwenRepository: QwenCookieRepository?,
        openCodeStore: OpenCodeWorkspaceStore?
    ) async {
        guard !instance.isDefaultSlot else { return }

        switch instance.provider {
        case .qwen:
            await removeAllWebsiteData(
                dataStore: qwenRepository?.dataStore ?? websiteDataStore(for: instance))
        case .openCodeGo:
            (openCodeStore ?? OpenCodeWorkspaceStore(
                namespace: instance.id.uuidString,
                allowsLegacyMigration: false)).clear()
            await removeAllWebsiteData(dataStore: websiteDataStore(for: instance))
        case .codex, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            break
        }
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
        syncProviders()
    }

    private func syncProviders() {
        coordinator.setEnabledProviders(settings.registeredProviders)
    }

    // MARK: - Runtime factory

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
            return fileBackedProvider(
                instance,
                missingMessage: "Choose this Codex account's auth.json with Account… before refreshing this card.",
                defaultProvider: { CodexProvider() },
                configuredProvider: { url in
                    CodexProvider(authLoader: { try CodexAuth.load(fileURL: url) })
                })

        case .claude:
            return fileBackedProvider(
                instance,
                missingMessage: "Choose this Claude account's credentials file with Account… before refreshing this card.",
                defaultProvider: { ClaudeProvider() },
                configuredProvider: { url in
                    ClaudeProvider(credentialLoader: {
                        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                            throw MajorProviderError.authentication(
                                "Claude credential file could not be read. Choose it again with Account…")
                        }
                        return try ClaudeCredential.parse(data: data)
                    })
                })

        case .antigravity:
            return AntigravityStatusLineProvider(fallback: AntigravityProvider())

        case .copilot:
            return secretBackedProvider(
                instance,
                missingMessage: "Set a GitHub token with Account… before refreshing this Copilot account.",
                defaultProvider: { CopilotProvider() },
                configuredProvider: { token in
                    CopilotProvider(tokenLoader: { () async throws -> String in token })
                })

        case .cursor:
            return secretBackedProvider(
                instance,
                missingMessage: "Set this Cursor account's access token with Account… before refreshing this card.",
                defaultProvider: { CursorProvider() },
                configuredProvider: { token in CursorProvider(tokenLoader: { token }) })

        case .zai:
            return secretBackedProvider(
                instance,
                missingMessage: "Set a Z.AI Coding Plan API key with Account… before refreshing this account.",
                defaultProvider: { ZAIProvider() },
                configuredProvider: { token in ZAIProvider(keyLoader: { token }) })

        case .kimi:
            return secretBackedProvider(
                instance,
                missingMessage: "Set a Kimi Code API key with Account… before refreshing this account.",
                defaultProvider: { KimiProvider() },
                configuredProvider: { token in
                    KimiProvider(credentialLoader: {
                        KimiCredential(token: token, isCLI: false, identityHeaders: [:])
                    })
                })
        }
    }

    private func fileBackedProvider(
        _ instance: ProviderInstance,
        missingMessage: String,
        defaultProvider: () -> any UsageProvider,
        configuredProvider: (URL) -> any UsageProvider
    ) -> any UsageProvider {
        if let path = ProviderInstanceCredentialStore.credentialPath(for: instance.id) {
            return configuredProvider(URL(fileURLWithPath: path))
        }
        return instance.isDefaultSlot
            ? defaultProvider()
            : missingAccountProvider(instance, message: missingMessage)
    }

    private func secretBackedProvider(
        _ instance: ProviderInstance,
        missingMessage: String,
        defaultProvider: () -> any UsageProvider,
        configuredProvider: (String) -> any UsageProvider
    ) -> any UsageProvider {
        do {
            if let secret = try ProviderInstanceCredentialStore.secret(for: instance) {
                return configuredProvider(secret)
            }
            return instance.isDefaultSlot
                ? defaultProvider()
                : missingAccountProvider(instance, message: missingMessage)
        } catch {
            return FailingUsageProvider(id: instance.provider, failure: error)
        }
    }

    private func missingAccountProvider(
        _ instance: ProviderInstance,
        message: String
    ) -> any UsageProvider {
        FailingUsageProvider(
            id: instance.provider,
            failure: MajorProviderError.authentication(message))
    }

    // MARK: - Account configuration

    private func configureAccount(_ instanceID: UUID) {
        guard let instance = settings.instance(instanceID) else { return }
        let isDefault = instance.isDefaultSlot

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
                explanation: isDefault
                    ? "The key is stored only in macOS Keychain. Clear it to use the normal Kimi CLI/environment login."
                    : "This duplicate card requires its own API key, stored only in macOS Keychain.")
        case .copilot:
            promptForSecret(
                instance,
                title: "Set GitHub token for this Copilot account",
                placeholder: "GitHub token",
                explanation: isDefault
                    ? "The token is stored only in macOS Keychain. Clear it to use the normal GitHub CLI/environment login."
                    : "This duplicate card requires its own GitHub token, stored only in macOS Keychain.")
        case .cursor:
            promptForSecret(
                instance,
                title: "Set Cursor access token for this account",
                placeholder: "Cursor JWT access token",
                explanation: isDefault
                    ? "The token is stored only in macOS Keychain. Clear it to use Cursor.app's current login."
                    : "This duplicate card requires its own Cursor access token, stored only in macOS Keychain.")
        case .codex:
            chooseCredentialFile(
                instance,
                title: "Choose this Codex account's auth.json",
                message: isDefault
                    ? "Choose an auth.json for this card, or use the normal Codex profile. AIUsage reads the file in place and never modifies it."
                    : "This duplicate card requires an auth.json from a separate Codex profile. AIUsage reads it in place and never modifies it.")
        case .claude:
            chooseCredentialFile(
                instance,
                title: "Choose this Claude account's credentials file",
                message: isDefault
                    ? "Choose a Claude Code credentials file for this card, or use the normal Claude profile. AIUsage reads the file in place and never modifies it."
                    : "This duplicate card requires a separate Claude Code credentials file. AIUsage reads it in place and never modifies it.")
        case .antigravity:
            showAntigravityAccountInfo()
        }
    }

    private func showAntigravityAccountInfo() {
        let alert = NSAlert()
        alert.messageText = "Antigravity uses official local interfaces"
        alert.informativeText = "AIUsage first reads the Antigravity CLI custom status-line cache when configured. Otherwise it falls back to the running Antigravity desktop local session. AIUsage does not create Google OAuth credentials or call Google's remote quota endpoint. See README for the /statusline setup command."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Antigravity")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = ProviderID.antigravity.staticDashboardURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func promptForSecret(
        _ instance: ProviderInstance,
        title: String,
        placeholder: String,
        explanation: String
    ) {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = placeholder

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = explanation
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: instance.isDefaultSlot ? "Use default" : "Clear")
        alert.addButton(withTitle: "Cancel")

        do {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try ProviderInstanceCredentialStore.saveSecret(field.stringValue, for: instance)
            case .alertSecondButtonReturn:
                try ProviderInstanceCredentialStore.deleteSecret(for: instance)
            default:
                return
            }
            refreshAfterCredentialChange(instance.id)
        } catch {
            showError(title: "Could not update account credential", error: error)
        }
    }

    private func chooseCredentialFile(_ instance: ProviderInstance, title: String, message: String) {
        let choice = NSAlert()
        choice.messageText = title
        choice.informativeText = message
        choice.addButton(withTitle: "Choose file…")
        choice.addButton(withTitle: instance.isDefaultSlot ? "Use default" : "Clear selection")
        choice.addButton(withTitle: "Cancel")

        switch choice.runModal() {
        case .alertSecondButtonReturn:
            ProviderInstanceCredentialStore.clearCredentialPath(for: instance.id)
            refreshAfterCredentialChange(instance.id)
            return
        case .alertFirstButtonReturn:
            break
        default:
            return
        }

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use for this account"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        ProviderInstanceCredentialStore.saveCredentialPath(url.path, for: instance.id)
        refreshAfterCredentialChange(instance.id)
    }

    private func refreshAfterCredentialChange(_ instanceID: UUID) {
        coordinator.rebuildProvider(instanceID)
        Task { await coordinator.refresh(instanceID) }
    }

    // MARK: - Web account profiles

    private func websiteDataStore(for instance: ProviderInstance) -> WKWebsiteDataStore {
        instance.isDefaultSlot ? .default() : WKWebsiteDataStore(forIdentifier: instance.id)
    }

    private func openCodeStore(for instance: ProviderInstance) -> OpenCodeWorkspaceStore {
        if let existing = openCodeStores[instance.id] { return existing }
        let store = OpenCodeWorkspaceStore(
            namespace: instance.isDefaultSlot ? "default" : instance.id.uuidString,
            allowsLegacyMigration: instance.isDefaultSlot)
        openCodeStores[instance.id] = store
        return store
    }

    private func qwenRepository(for instance: ProviderInstance) -> QwenCookieRepository {
        if let existing = qwenRepositories[instance.id] { return existing }
        let repository = QwenCookieRepository(
            dataStore: websiteDataStore(for: instance),
            namespace: instance.isDefaultSlot ? "default" : instance.id.uuidString,
            allowsLegacyMigration: instance.isDefaultSlot)
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
                switch instance.provider {
                case .openCodeGo:
                    if let id = Self.workspaceID(from: url) {
                        self.openCodeStore(for: instance).save(id)
                    }
                case .qwen:
                    self.qwenRepository(for: instance).markLoginSucceeded()
                case .codex, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
                    break
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
            await clearWebData(
                for: instance,
                dataStore: repository.dataStore,
                sharedDomains: ["qwencloud.com", "qianwenai.com"])
            coordinator.markSignedOut(instanceID, message: "Qwen Cloud login is required.")

        case .openCodeGo:
            openCodeStore(for: instance).clear()
            await clearWebData(
                for: instance,
                dataStore: websiteDataStore(for: instance),
                sharedDomains: ["opencode.ai"])
            coordinator.markSignedOut(instanceID, message: "OpenCode login is required.")

        case .zai:
            do {
                try ProviderInstanceCredentialStore.deleteSecret(for: instance)
                if instance.isDefaultSlot {
                    try AIUsageSecretStore.delete(account: ZAIProvider.keychainAccount)
                }
            } catch {
                showError(title: "Could not sign out of Z.AI", error: error)
                return
            }
            coordinator.rebuildProvider(instanceID)
            coordinator.markSignedOut(instanceID, message: "Z.AI API key is required.")

        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi:
            break
        }
    }

    private func clearWebData(
        for instance: ProviderInstance,
        dataStore: WKWebsiteDataStore,
        sharedDomains: [String]
    ) async {
        if instance.isDefaultSlot {
            await removeWebsiteData(matching: sharedDomains, dataStore: dataStore)
        } else {
            await removeAllWebsiteData(dataStore: dataStore)
        }
    }

    // MARK: - External URLs

    private func openDashboard(_ instanceID: UUID) {
        guard let instance = settings.instance(instanceID) else { return }
        NSWorkspace.shared.open(dashboardURL(instance))
    }

    private func loginURL(_ instance: ProviderInstance) -> URL {
        instance.provider == .openCodeGo
            ? URL(string: "https://opencode.ai/auth")!
            : dashboardURL(instance)
    }

    private func dashboardURL(_ instance: ProviderInstance) -> URL {
        instance.provider.staticDashboardURL ?? openCodeStore(for: instance).usageURL
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
            domains.contains { Self.websiteDataRecordName(record.displayName, matches: $0) }
        }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: types, for: matched) { continuation.resume() }
        }
    }

    private func removeAllWebsiteData(dataStore: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast) { continuation.resume() }
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

@MainActor
final class AntigravityStatusLineProvider: UsageProvider {
    let id: ProviderID = .antigravity

    private let fallback: any UsageProvider
    private let fileManager: FileManager

    init(fallback: any UsageProvider, fileManager: FileManager = .default) {
        self.fallback = fallback
        self.fileManager = fileManager
    }

    func fetch() async throws -> ProviderSnapshot {
        if let cached = try? Self.loadCachedSnapshot(fileManager: fileManager) {
            return cached
        }

        do {
            return try await fallback.fetch()
        } catch {
            throw MajorProviderError.authentication(
                "Antigravity usage is unavailable. Configure the official CLI /statusline bridge or open and sign in to the Antigravity desktop app, then Refresh.")
        }
    }

    func cancelActiveFetch() {
        fallback.cancelActiveFetch()
    }

    static func loadCachedSnapshot(
        fileManager: FileManager = .default
    ) throws -> ProviderSnapshot? {
        let url = cacheURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? Date()
        return try parseStatusLinePayload(data: data, fetchedAt: modifiedAt)
    }

    static func parseStatusLinePayload(
        data: Data,
        fetchedAt: Date = Date()
    ) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["product"] as? String)?.lowercased() == "antigravity",
              let quota = root["quota"] as? [String: Any] else {
            throw MajorProviderError.invalidResponse(
                "Antigravity status-line cache did not contain a recognized quota payload.")
        }

        var windows: [UsageWindow] = []
        for (key, rawValue) in quota {
            guard let value = rawValue as? [String: Any],
                  let remaining = number(value["remaining_fraction"]),
                  remaining.isFinite,
                  (0...1).contains(remaining),
                  let descriptor = quotaDescriptor(key) else { continue }

            let resetTime = value["reset_time"] as? String
            let resetSeconds = number(value["reset_in_seconds"])
            let resetsAt = MajorProviderHTTP.isoDate(resetTime)
                ?? resetSeconds.map { fetchedAt.addingTimeInterval($0) }
            windows.append(try UsageWindow(
                id: "antigravity-statusline-\(key)",
                kind: descriptor.kind,
                label: descriptor.label,
                compactLabel: descriptor.compactLabel,
                usedPercent: (1 - remaining) * 100,
                resetsAt: resetsAt,
                resetDescription: nil))
        }

        guard !windows.isEmpty else {
            throw MajorProviderError.invalidResponse(
                "Antigravity status-line cache contained no recognized quota windows.")
        }

        let plan = (root["plan_tier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderSnapshot(
            provider: .antigravity,
            planName: plan?.isEmpty == false ? plan : nil,
            windows: windows,
            fetchedAt: fetchedAt)
    }

    private static func cacheURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage", isDirectory: true)
            .appendingPathComponent("antigravity-status.json")
    }

    private static func quotaDescriptor(
        _ key: String
    ) -> (kind: UsageWindowKind, label: String, compactLabel: String)? {
        let normalized = key.lowercased()
        let kind: UsageWindowKind
        let cadenceLabel: String
        let cadenceCompact: String
        if normalized.contains("weekly") || normalized.contains("week") {
            kind = .weekly
            cadenceLabel = "Weekly"
            cadenceCompact = "W"
        } else if normalized.contains("5h") || normalized.contains("5-hour") || normalized.contains("session") {
            kind = .fiveHour
            cadenceLabel = "5-hour"
            cadenceCompact = "5"
        } else {
            return nil
        }

        if normalized.contains("gemini") {
            return (kind, "Gemini \(cadenceLabel)", "G\(cadenceCompact)")
        }
        if normalized.contains("claude") || normalized.contains("gpt")
            || normalized.contains("third") || normalized.contains("3p") {
            return (kind, "Claude / GPT \(cadenceLabel)", "C\(cadenceCompact)")
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }
}
