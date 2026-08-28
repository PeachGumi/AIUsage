import AppKit
import Combine
import CryptoKit
import Foundation
import Security
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
    private lazy var antigravityProvider = AntigravityBackgroundProvider()
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

// MARK: - Antigravity closed-app refresh

/// Uses the running Antigravity language server when available, then falls back
/// to Antigravity's persisted Keychain OAuth credential and Google's quota
/// backend. The fallback never modifies Antigravity's Keychain item.
@MainActor
final class AntigravityBackgroundProvider: UsageProvider {
    let id: ProviderID = .antigravity

    private let localProvider: any UsageProvider
    private let remoteProvider: any UsageProvider

    init(
        localProvider: any UsageProvider = AntigravityProvider(),
        remoteProvider: any UsageProvider = AntigravityRemoteProvider()
    ) {
        self.localProvider = localProvider
        self.remoteProvider = remoteProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        do {
            return try await localProvider.fetch()
        } catch {
            return try await remoteProvider.fetch()
        }
    }

    func cancelActiveFetch() {
        localProvider.cancelActiveFetch()
        remoteProvider.cancelActiveFetch()
    }
}

struct AntigravityStoredCredential: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?
}

struct AntigravityOAuthClient: Equatable, Sendable {
    let clientID: String
    let clientSecret: String
}

enum AntigravityCredentialStore {
    static let service = "gemini"
    static let account = "antigravity"
    static let cacheAccount = "antigravity.refreshedOAuthToken"
    static let refreshBuffer: TimeInterval = 60

    struct CachedAccessToken: Codable, Equatable, Sendable {
        let accessToken: String
        let expiresAt: TimeInterval
        let refreshFingerprint: String
    }

    static func loadSourceCredential() throws -> AntigravityStoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            try? AIUsageSecretStore.delete(account: cacheAccount)
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8) else {
            throw MajorProviderError.authentication(
                "Antigravity credentials could not be read from macOS Keychain (OSStatus \(status)).")
        }
        guard let credential = parse(raw: raw) else {
            throw MajorProviderError.authentication(
                "Antigravity credentials in macOS Keychain are not in a recognized format.")
        }
        return credential
    }

    static func parse(raw: String) -> AntigravityStoredCredential? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let decoded: String
        let prefix = "go-keyring-base64:"
        if trimmed.hasPrefix(prefix) {
            let payload = String(trimmed.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: payload),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            decoded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            decoded = trimmed
        }
        guard !decoded.isEmpty else { return nil }

        if let data = decoded.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = object as? [String: Any] {
                return credential(from: dictionary)
            }
            if let token = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return AntigravityStoredCredential(accessToken: token, refreshToken: nil, expiresAt: nil)
            }
            return nil
        }

        // Never reinterpret malformed structured material as a bearer token.
        if decoded.hasPrefix("{") || decoded.hasPrefix("[") { return nil }
        if decoded.hasPrefix("Bearer ") {
            let token = String(decoded.dropFirst("Bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : AntigravityStoredCredential(
                accessToken: token, refreshToken: nil, expiresAt: nil)
        }
        return AntigravityStoredCredential(accessToken: decoded, refreshToken: nil, expiresAt: nil)
    }

    static func accessTokenIsUsable(
        _ source: AntigravityStoredCredential,
        now: Date = Date()
    ) -> Bool {
        guard source.accessToken?.isEmpty == false else { return false }
        guard let expiresAt = source.expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(refreshBuffer)
    }

    static func loadCachedAccessToken(
        matching source: AntigravityStoredCredential,
        now: Date = Date()
    ) throws -> String? {
        guard let refreshToken = source.refreshToken,
              let fingerprint = fingerprint(refreshToken) else {
            try? AIUsageSecretStore.delete(account: cacheAccount)
            return nil
        }
        guard let raw = try AIUsageSecretStore.load(account: cacheAccount),
              let data = raw.data(using: .utf8),
              let cached = try? JSONDecoder().decode(CachedAccessToken.self, from: data),
              cached.refreshFingerprint == fingerprint,
              cached.expiresAt > now.addingTimeInterval(refreshBuffer).timeIntervalSince1970,
              !cached.accessToken.isEmpty else {
            try? AIUsageSecretStore.delete(account: cacheAccount)
            return nil
        }
        return cached.accessToken
    }

    static func saveCachedAccessToken(
        _ token: String,
        expiresIn: TimeInterval,
        sourceRefreshToken: String,
        now: Date = Date()
    ) throws {
        guard let fingerprint = fingerprint(sourceRefreshToken), !token.isEmpty else { return }
        let cached = CachedAccessToken(
            accessToken: token,
            expiresAt: now.addingTimeInterval(max(60, expiresIn)).timeIntervalSince1970,
            refreshFingerprint: fingerprint)
        let data = try JSONEncoder().encode(cached)
        try AIUsageSecretStore.save(
            String(decoding: data, as: UTF8.self),
            account: cacheAccount)
    }

    private static func credential(from object: [String: Any]) -> AntigravityStoredCredential? {
        let source = (object["token"] as? [String: Any]) ?? object
        let access = firstString(source, keys: [
            "access_token", "accessToken", "token", "id_token", "idToken",
            "bearerToken", "auth_token", "authToken",
        ])
        let refresh = firstString(source, keys: ["refresh_token", "refreshToken"])
        let expiry = expiryDate(source["expiry"] ?? source["expires_at"] ?? source["expiresAt"])

        if access == nil, refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any],
                   let credential = credential(from: nested) {
                    return credential
                }
            }
            return nil
        }
        return AntigravityStoredCredential(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiry)
    }

    private static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func expiryDate(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let date = MajorProviderHTTP.isoDate(text) { return date }
            if let number = Double(text) {
                return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
            }
        }
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        return nil
    }

    private static func fingerprint(_ refreshToken: String) -> String? {
        let token = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AntigravityOAuthClientDiscovery {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AntigravityOAuthClient? {
        if let clientID = environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let clientSecret = environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !clientID.isEmpty,
           !clientSecret.isEmpty {
            return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
        }

        for url in candidateArtifactURLs(fileManager: fileManager)
            where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let client = parseClient(from: data) else { continue }
            return client
        }
        return nil
    }

    static func parseClient(from data: Data) -> AntigravityOAuthClient? {
        if let text = String(data: data, encoding: .utf8),
           let client = parseClient(fromText: text) {
            return client
        }

        let clientIDs = oauthClientIDs(in: data)
        let clientSecrets = oauthClientSecrets(in: data)
        guard !clientIDs.isEmpty, !clientSecrets.isEmpty else { return nil }

        if clientSecrets.count == 1, clientIDs.count > 1 {
            return AntigravityOAuthClient(
                clientID: clientIDs[clientIDs.count - 1],
                clientSecret: clientSecrets[0])
        }
        let secret: String
        if clientSecrets.count == clientIDs.count, clientSecrets.count > 1 {
            secret = clientSecrets[clientSecrets.count - 1]
        } else {
            secret = clientSecrets[0]
        }
        return AntigravityOAuthClient(clientID: clientIDs[0], clientSecret: secret)
    }

    static func parseClient(fromText text: String) -> AntigravityOAuthClient? {
        let marker = "vs/platform/cloudCode/common/oauthClient.js"
        let start = text.range(of: marker)?.lowerBound ?? text.startIndex
        let end = text.index(start, offsetBy: 4000, limitedBy: text.endIndex) ?? text.endIndex
        let haystack = String(text[start..<end])
        guard let clientID = firstMatch(
            pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#,
            in: haystack),
              let clientSecret = firstMatch(
            pattern: #"GOCSPX-[A-Za-z0-9_-]{28}"#,
            in: haystack) else { return nil }
        return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
    }

    private static func candidateArtifactURLs(fileManager: FileManager) -> [URL] {
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
            let direct = root.appendingPathComponent("Antigravity.app", isDirectory: true)
            bundles.append(direct)

            let contents = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in contents where url.pathExtension.lowercased() == "app" {
                guard isAntigravityBundle(url),
                      !bundles.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else {
                    continue
                }
                bundles.append(url)
            }
        }
        return bundles.flatMap { bundle in
            relativePaths.map { bundle.appendingPathComponent($0) }
        }
    }

    private static func isAntigravityBundle(_ url: URL) -> Bool {
        switch Bundle(url: url)?.bundleIdentifier {
        case "com.google.antigravity", "com.google.antigravity-ide", "com.google.GeminiMacOS":
            true
        default:
            false
        }
    }

    private static func oauthClientIDs(in data: Data) -> [String] {
        let suffix = Data(".apps.googleusercontent.com".utf8)
        var searchStart = data.startIndex
        var values: [String] = []
        while searchStart < data.endIndex,
              let range = data.range(of: suffix, in: searchStart..<data.endIndex) {
            var start = range.lowerBound
            while start > data.startIndex {
                let previous = data.index(before: start)
                guard isOAuthByte(data[previous]) else { break }
                start = previous
            }
            if let candidate = String(data: data[start..<range.upperBound], encoding: .ascii),
               let value = firstMatch(
                pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#,
                in: candidate) {
                values.append(value)
            }
            searchStart = range.upperBound
        }
        return unique(values)
    }

    private static func oauthClientSecrets(in data: Data) -> [String] {
        let prefix = Data("GOCSPX-".utf8)
        let secretLength = 35
        var searchStart = data.startIndex
        var values: [String] = []
        while searchStart < data.endIndex,
              let range = data.range(of: prefix, in: searchStart..<data.endIndex) {
            if let end = data.index(range.lowerBound, offsetBy: secretLength, limitedBy: data.endIndex) {
                let candidateData = data[range.lowerBound..<end]
                if candidateData.dropFirst(prefix.count).allSatisfy(isOAuthByte),
                   let candidate = String(data: candidateData, encoding: .ascii) {
                    values.append(candidate)
                }
            }
            searchStart = range.upperBound
        }
        return unique(values)
    }

    private static func isOAuthByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || byte == 45
            || byte == 95
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class AntigravityRemoteProvider: UsageProvider {
    let id: ProviderID = .antigravity

    private static let quotaBaseURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ]
    private static let quotaPath = "/v1internal:retrieveUserQuotaSummary"
    private static let tokenURL = "https://oauth2.googleapis.com/token"

    private let session: URLSession

    init(session: URLSession = MajorProviderHTTP.session()) {
        self.session = session
    }

    func fetch() async throws -> ProviderSnapshot {
        let source = try await Task.detached(priority: .utility) {
            try AntigravityCredentialStore.loadSourceCredential()
        }.value
        guard let source else {
            throw MajorProviderError.authentication(
                "Antigravity login was not found. Sign in once with Antigravity or agy, then Refresh.")
        }

        var tokens: [String] = []
        if AntigravityCredentialStore.accessTokenIsUsable(source),
           let accessToken = source.accessToken {
            tokens.append(accessToken)
        }
        if let cached = try await Task.detached(priority: .utility, operation: {
            try AntigravityCredentialStore.loadCachedAccessToken(matching: source)
        }).value,
           !tokens.contains(cached) {
            tokens.append(cached)
        }

        var sawAuthFailure = false
        for token in tokens {
            switch await fetchRemoteSnapshot(token: token) {
            case .success(let snapshot):
                return snapshot
            case .authFailed:
                sawAuthFailure = true
            case .invalid(let error):
                throw error
            case .unavailable:
                break
            }
        }

        if (sawAuthFailure || tokens.isEmpty), let refreshToken = source.refreshToken {
            guard let client = await Task.detached(priority: .utility, operation: {
                AntigravityOAuthClientDiscovery.resolve()
            }).value else {
                throw MajorProviderError.unavailable(
                    "Antigravity OAuth client metadata could not be read from the installed app. Keep Antigravity installed, or set ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET.")
            }

            switch await refreshAccessToken(refreshToken, client: client) {
            case .success(let accessToken, let expiresIn):
                try await Task.detached(priority: .utility, operation: {
                    try AntigravityCredentialStore.saveCachedAccessToken(
                        accessToken,
                        expiresIn: expiresIn,
                        sourceRefreshToken: refreshToken)
                }).value
                switch await fetchRemoteSnapshot(token: accessToken) {
                case .success(let snapshot):
                    return snapshot
                case .authFailed:
                    throw MajorProviderError.authentication(
                        "Antigravity login has expired. Sign in again with Antigravity or agy.")
                case .invalid(let error):
                    throw error
                case .unavailable:
                    throw MajorProviderError.unavailable(
                        "Antigravity quota service is temporarily unavailable.")
                }
            case .authFailed:
                throw MajorProviderError.authentication(
                    "Antigravity login has expired. Sign in again with Antigravity or agy.")
            case .unavailable:
                throw MajorProviderError.unavailable(
                    "Antigravity OAuth service is temporarily unavailable.")
            }
        }

        if sawAuthFailure {
            throw MajorProviderError.authentication(
                "Antigravity login has expired. Sign in again with Antigravity or agy.")
        }
        if !tokens.isEmpty || source.refreshToken?.isEmpty == false {
            throw MajorProviderError.unavailable(
                "Antigravity quota service is temporarily unavailable.")
        }
        throw MajorProviderError.authentication(
            "Antigravity credentials do not contain a usable access or refresh token.")
    }

    /// Parses both the local Connect-RPC envelope used by Antigravity.app and
    /// the bare Cloud Code quota-summary shape returned by Google OAuth.
    /// Remote buckets are matched by exact IDs so future model-specific lanes
    /// are never silently folded into an existing quota.
    static func parseRemoteQuotaSummary(
        data: Data,
        now: Date = Date()
    ) throws -> ProviderSnapshot {
        if let snapshot = try? AntigravityProvider.parseQuotaSummary(data: data, now: now) {
            return snapshot
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MajorProviderError.invalidResponse(
                "Antigravity returned invalid remote quota-summary JSON.")
        }
        let root = (json["response"] as? [String: Any]) ?? json
        guard let groups = root["groups"] as? [[String: Any]] else {
            throw MajorProviderError.invalidResponse(
                "Antigravity remote quota summary did not contain groups.")
        }

        struct Spec {
            let kind: UsageWindowKind
            let label: String
            let compactLabel: String
            let windowID: String
        }
        let specs: [String: Spec] = [
            "gemini-5h": Spec(
                kind: .fiveHour,
                label: "Gemini 5-hour",
                compactLabel: "G5",
                windowID: "antigravity-gemini-fiveHour"),
            "gemini-weekly": Spec(
                kind: .weekly,
                label: "Gemini Weekly",
                compactLabel: "GW",
                windowID: "antigravity-gemini-weekly"),
            "3p-5h": Spec(
                kind: .fiveHour,
                label: "Claude/GPT 5-hour",
                compactLabel: "C5",
                windowID: "antigravity-thirdparty-fiveHour"),
            "3p-weekly": Spec(
                kind: .weekly,
                label: "Claude/GPT Weekly",
                compactLabel: "CW",
                windowID: "antigravity-thirdparty-weekly"),
        ]

        var seen = Set<String>()
        var windows: [UsageWindow] = []
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                guard let bucketID = bucket["bucketId"] as? String,
                      let spec = specs[bucketID],
                      seen.insert(bucketID).inserted,
                      let remaining = fraction(bucket["remainingFraction"])
                        ?? fraction((bucket["remaining"] as? [String: Any])?["remainingFraction"]),
                      (0...1).contains(remaining) else {
                    continue
                }
                let reset = resetDate(bucket)
                windows.append(try UsageWindow(
                    id: spec.windowID,
                    kind: spec.kind,
                    label: spec.label,
                    compactLabel: spec.compactLabel,
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: reset,
                    resetDescription: nil))
            }
        }

        guard !windows.isEmpty else {
            throw MajorProviderError.invalidResponse(
                "Antigravity remote quota summary contained no recognized quota buckets.")
        }
        return ProviderSnapshot(
            provider: .antigravity,
            planName: nil,
            windows: windows,
            fetchedAt: now)
    }

    private static func fraction(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func resetDate(_ bucket: [String: Any]) -> Date? {
        for key in ["resetTime", "reset_time", "resetsAt", "resets_at"] {
            if let text = bucket[key] as? String,
               let date = MajorProviderHTTP.isoDate(text) {
                return date
            }
            if let number = fraction(bucket[key]) {
                return Date(timeIntervalSince1970:
                    number > 10_000_000_000 ? number / 1000 : number)
            }
        }
        return nil
    }

    private enum RemoteSnapshotResult {
        case success(ProviderSnapshot)
        case authFailed
        case invalid(Error)
        case unavailable
    }

    private func fetchRemoteSnapshot(token: String) async -> RemoteSnapshotResult {
        for baseURL in Self.quotaBaseURLs {
            guard let url = URL(string: baseURL + Self.quotaPath) else { continue }
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 401 || http.statusCode == 403 { return .authFailed }
                guard (200...299).contains(http.statusCode) else { continue }
                do {
                    return .success(try Self.parseRemoteQuotaSummary(data: data))
                } catch {
                    return .invalid(error)
                }
            } catch {
                continue
            }
        }
        return .unavailable
    }

    private enum TokenRefreshResult {
        case success(accessToken: String, expiresIn: TimeInterval)
        case authFailed
        case unavailable
    }

    private func refreshAccessToken(
        _ refreshToken: String,
        client: AntigravityOAuthClient
    ) async -> TokenRefreshResult {
        guard let url = URL(string: Self.tokenURL) else { return .unavailable }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "client_secret", value: client.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            return .unavailable
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200...299:
                struct Response: Decodable {
                    let accessToken: String
                    let expiresIn: TimeInterval?

                    enum CodingKeys: String, CodingKey {
                        case accessToken = "access_token"
                        case expiresIn = "expires_in"
                    }
                }
                guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
                      !decoded.accessToken.isEmpty else { return .unavailable }
                return .success(
                    accessToken: decoded.accessToken,
                    expiresIn: decoded.expiresIn ?? 3600)
            case 400...499 where http.statusCode != 408 && http.statusCode != 429:
                return .authFailed
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}
