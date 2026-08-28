import AppKit
import Foundation
import Security
import SQLite3

// MARK: - Shared provider infrastructure

enum MajorProviderError: LocalizedError, ProviderAuthenticationError, Equatable {
    case authentication(String)
    case unavailable(String)
    case invalidResponse(String)
    case http(provider: String, status: Int)
    case local(String)

    var requiresAuthentication: Bool {
        if case .authentication = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case let .authentication(message), let .unavailable(message), let .invalidResponse(message), let .local(message):
            message
        case let .http(provider, status) where status == 429:
            "\(provider) is rate limiting usage requests. Try Refresh again later."
        case let .http(provider, status) where (500...599).contains(status):
            "\(provider) usage service is temporarily unavailable (HTTP \(status))."
        case let .http(provider, status):
            "\(provider) usage request failed (HTTP \(status))."
        }
    }
}

enum AIUsageSecretStore {
    private static let service = "app.aiusage.AIUsage.credentials"

    static func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MajorProviderError.local("Keychain credential could not be read (OSStatus \(status)).")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ value: String, account: String) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MajorProviderError.local("Credential must not be empty.") }
        try delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(cleaned.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MajorProviderError.local("Keychain credential could not be saved (OSStatus \(status)).")
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MajorProviderError.local("Keychain credential could not be removed (OSStatus \(status)).")
        }
    }
}

enum MajorProviderHTTP {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RejectRedirectDelegate(), delegateQueue: nil)
    }

    static func checkedData(
        for request: URLRequest,
        session: URLSession,
        provider: String) async throws -> Data
    {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MajorProviderError.invalidResponse("\(provider) returned a non-HTTP response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MajorProviderError.authentication("\(provider) authentication is required or has expired.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MajorProviderError.http(provider: provider, status: http.statusCode)
        }
        return data
    }

    static func isoDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        if let value = formatter.date(from: raw) { return value }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }
}

enum MajorProviderCommand {
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw MajorProviderError.local(message?.isEmpty == false ? message! : "Command failed: \(executable)")
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}

// MARK: - Claude / Claude Code

@MainActor
final class ClaudeProvider: UsageProvider {
    let id: ProviderID = .claude
    private let session: URLSession
    private let credentialLoader: () throws -> ClaudeCredential

    init(
        session: URLSession = MajorProviderHTTP.session(),
        credentialLoader: @escaping () throws -> ClaudeCredential = { try ClaudeCredential.load() })
    {
        self.session = session
        self.credentialLoader = credentialLoader
    }

    func fetch() async throws -> ProviderSnapshot {
        let credential = try credentialLoader()
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "Claude")
        return try Self.parseUsage(data: data, credential: credential)
    }

    static func parseUsage(data: Data, credential: ClaudeCredential, now: Date = Date()) throws -> ProviderSnapshot {
        let response: ClaudeUsageResponse
        do { response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data) }
        catch { throw MajorProviderError.invalidResponse("Claude returned unexpected usage data. The usage API may have changed.") }

        var windows: [UsageWindow] = []
        if let value = response.fiveHour {
            windows.append(try value.window(
                id: "claude-five-hour",
                kind: .fiveHour,
                label: "5-hour",
                compactLabel: "5h"))
        }
        if let value = response.sevenDay {
            windows.append(try value.window(
                id: "claude-weekly",
                kind: .weekly,
                label: "Weekly",
                compactLabel: "W"))
        }
        guard !windows.isEmpty else {
            throw MajorProviderError.invalidResponse("Claude returned no recognized 5-hour or weekly usage windows.")
        }
        return ProviderSnapshot(
            provider: .claude,
            planName: credential.planName,
            windows: windows,
            fetchedAt: now)
    }
}

struct ClaudeCredential: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?

    var planName: String? {
        let subscription = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subscription, !subscription.isEmpty { return subscription.capitalized }
        let tier = rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return tier?.isEmpty == false ? tier : nil
    }

    static func load(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) throws -> ClaudeCredential
    {
        let root: URL
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.split(separator: ",").first,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            root = URL(fileURLWithPath: NSString(string: String(configured)).expandingTildeInPath, isDirectory: true)
        } else {
            root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        }
        let file = root.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let credential = try? parse(data: data, now: now) {
            return credential
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try parse(data: data, now: now)
        }
        if status != errSecItemNotFound {
            throw MajorProviderError.authentication(
                "Claude credentials could not be read from Keychain (OSStatus \(status)). Open Claude Code and retry from a user action.")
        }
        throw MajorProviderError.authentication("Claude login not found. Sign in with Claude Code first, then Refresh.")
    }

    static func parse(data: Data, now: Date = Date()) throws -> ClaudeCredential {
        struct Root: Decodable { let claudeAiOauth: OAuth? }
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let scopes: [String]?
            let rateLimitTier: String?
            let subscriptionType: String?
        }
        guard let root = try? JSONDecoder().decode(Root.self, from: data), let oauth = root.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else {
            throw MajorProviderError.authentication("Claude OAuth credentials are missing or unreadable. Sign in with Claude Code again.")
        }
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let expiresAt, expiresAt <= now.addingTimeInterval(30) {
            throw MajorProviderError.authentication("Claude OAuth token has expired. Sign in with Claude Code again.")
        }
        let scopes = oauth.scopes ?? []
        if !scopes.isEmpty && !scopes.contains("user:profile") {
            throw MajorProviderError.authentication(
                "Claude OAuth credential does not include the user:profile scope required by the usage endpoint. Use a normal Claude Code subscription login.")
        }
        return ClaudeCredential(
            accessToken: token,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier)
    }
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        func window(
            id: String,
            kind: UsageWindowKind,
            label: String,
            compactLabel: String) throws -> UsageWindow
        {
            guard let utilization, utilization.isFinite, (0...100).contains(utilization) else {
                throw MajorProviderError.invalidResponse("Claude returned an invalid \(label) utilization value.")
            }
            return try UsageWindow(
                id: id,
                kind: kind,
                label: label,
                compactLabel: compactLabel,
                usedPercent: utilization,
                resetsAt: MajorProviderHTTP.isoDate(resetsAt),
                resetDescription: nil)
        }
    }
}

// MARK: - Google Antigravity

@MainActor
final class AntigravityProvider: UsageProvider {
    let id: ProviderID = .antigravity

    func fetch() async throws -> ProviderSnapshot {
        let endpoints = try await Self.discoverEndpoints()
        guard !endpoints.isEmpty else {
            throw MajorProviderError.authentication("Antigravity local session not found. Open Antigravity, sign in, and try Refresh again.")
        }

        var lastError: Error?
        for endpoint in endpoints {
            do {
                let data = try await Self.fetchQuotaSummary(endpoint: endpoint)
                return try Self.parseQuotaSummary(data: data)
            } catch {
                lastError = error
            }
        }
        if let error = lastError { throw error }
        throw MajorProviderError.unavailable("Antigravity local usage service could not be reached.")
    }

    struct Endpoint: Equatable, Sendable {
        let port: Int
        let csrfToken: String
    }

    static func discoverEndpoints() async throws -> [Endpoint] {
        let output = try await MajorProviderCommand.run("/bin/ps", ["-ax", "-o", "pid=,command="])
        var results: [Endpoint] = []
        for line in output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(where: { $0.isWhitespace }),
                  let pid = Int(text[..<space]) else { continue }
            let command = String(text[space...]).trimmingCharacters(in: .whitespaces)
            let lower = command.lowercased()
            guard lower.contains("language_server"), lower.contains("antigravity") else { continue }
            guard let token = csrfToken(from: command) else { continue }

            let ports = (try? await listeningPorts(pid: pid)) ?? []
            for port in ports where !results.contains(where: { $0.port == port && $0.csrfToken == token }) {
                results.append(Endpoint(port: port, csrfToken: token))
            }
        }
        return results
    }

    static func csrfToken(from command: String) -> String? {
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, part) in parts.enumerated() {
            if part.hasPrefix("--csrf_token=") {
                let value = String(part.dropFirst("--csrf_token=".count))
                return value.isEmpty ? nil : value
            }
            if part == "--csrf_token", parts.indices.contains(index + 1) {
                let value = parts[index + 1]
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func listeningPorts(pid: Int) async throws -> [Int] {
        let output = try await MajorProviderCommand.run(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"])
        let pattern = #"TCP\s+(?:127\.0\.0\.1|localhost|\*|\[::1\]):(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: output) else { return nil }
            return Int(output[swiftRange])
        }
    }

    private static func fetchQuotaSummary(endpoint: Endpoint) async throws -> Data {
        guard let url = URL(string:
            "https://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
        else { throw MajorProviderError.local("Antigravity local usage URL was invalid.") }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: AntigravityLoopbackDelegate(),
            delegateQueue: nil)
        return try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "Antigravity")
    }

    static func parseQuotaSummary(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["groups"] as? [[String: Any]] else {
            throw MajorProviderError.invalidResponse("Antigravity returned unexpected quota-summary data.")
        }
        var windows: [UsageWindow] = []
        for group in groups {
            let groupName = (group["displayName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let family = quotaFamily(groupName)
            guard family != nil, let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                let bucketID = (bucket["bucketId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let bucketName = (bucket["displayName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let cadence = quotaCadence(bucketID + " " + bucketName),
                      let remaining = remainingFraction(bucket["remaining"]),
                      remaining.isFinite, (0...1).contains(remaining)
                else { continue }

                let familyName = family == "gemini" ? "Gemini" : "Claude/GPT"
                let cadenceName = cadence == .fiveHour ? "5-hour" : "Weekly"
                let compact = family == "gemini"
                    ? (cadence == .fiveHour ? "G5" : "GW")
                    : (cadence == .fiveHour ? "C5" : "CW")
                let reset = resetDate(bucket)
                windows.append(try UsageWindow(
                    id: "antigravity-\(family!)-\(cadence.rawValue)",
                    kind: cadence,
                    label: "\(familyName) \(cadenceName)",
                    compactLabel: compact,
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: reset,
                    resetDescription: nil))
            }
        }
        guard !windows.isEmpty else {
            throw MajorProviderError.invalidResponse("Antigravity returned no recognized Gemini or Claude/GPT quota windows.")
        }
        return ProviderSnapshot(provider: .antigravity, planName: nil, windows: windows, fetchedAt: now)
    }

    private static func quotaFamily(_ raw: String) -> String? {
        let value = raw.lowercased()
        if value.contains("gemini") { return "gemini" }
        if value.contains("claude") || value.contains("gpt") { return "thirdparty" }
        return nil
    }

    private static func quotaCadence(_ raw: String) -> UsageWindowKind? {
        let normalized = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        let sessionPattern = #"(^|[^a-z0-9])(session|5h|5-hour|five-hour|five hour)([^a-z0-9]|$)"#
        let weeklyPattern = #"(^|[^a-z0-9])(weekly|week|7d|7-day|seven-day|seven day)([^a-z0-9]|$)"#
        if normalized.range(of: sessionPattern, options: .regularExpression) != nil { return .fiveHour }
        if normalized.range(of: weeklyPattern, options: .regularExpression) != nil { return .weekly }
        return nil
    }

    private static func remainingFraction(_ raw: Any?) -> Double? {
        guard let object = raw as? [String: Any] else { return nil }
        if let value = number(object["remainingFraction"]) { return value }
        if object["case"] as? String == "remainingFraction" { return number(object["value"]) }
        return nil
    }

    private static func resetDate(_ bucket: [String: Any]) -> Date? {
        for key in ["resetTime", "reset_time", "resetsAt", "resets_at"] {
            if let text = bucket[key] as? String, let date = MajorProviderHTTP.isoDate(text) { return date }
            if let number = number(bucket[key]) {
                return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
            }
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }
}

private final class AntigravityLoopbackDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let host = challenge.protectionSpace.host.lowercased()
        guard (host == "127.0.0.1" || host == "localhost"),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

// MARK: - GitHub Copilot

@MainActor
final class CopilotProvider: UsageProvider {
    let id: ProviderID = .copilot
    static let keychainAccount = "copilot.githubOAuthToken"
    private let session: URLSession
    private let tokenLoader: () throws -> String?

    init(
        session: URLSession = MajorProviderHTTP.session(),
        tokenLoader: @escaping () throws -> String? = { try AIUsageSecretStore.load(account: keychainAccount) })
    {
        self.session = session
        self.tokenLoader = tokenLoader
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let token = try tokenLoader(), !token.isEmpty else {
            throw MajorProviderError.authentication("GitHub Copilot login is required. Use Sign in on the Copilot card.")
        }
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
        let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "GitHub Copilot")
        return try Self.parseUsage(data: data)
    }

    static func parseUsage(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        let response: CopilotUsageResponse
        do { response = try JSONDecoder().decode(CopilotUsageResponse.self, from: data) }
        catch { throw MajorProviderError.invalidResponse("GitHub Copilot returned unexpected usage data.") }

        let reset = MajorProviderHTTP.isoDate(response.quotaResetDate)
        var windows: [UsageWindow] = []
        if let premium = response.quotaSnapshots.premiumInteractions, let used = premium.usedPercent {
            windows.append(try UsageWindow(
                id: "copilot-premium",
                kind: .monthly,
                label: "AI credits / premium",
                compactLabel: "AI",
                usedPercent: used,
                resetsAt: reset,
                resetDescription: nil))
        }
        if let chat = response.quotaSnapshots.chat, let used = chat.usedPercent {
            windows.append(try UsageWindow(
                id: "copilot-chat",
                kind: .monthly,
                label: "Chat",
                compactLabel: "Chat",
                usedPercent: used,
                resetsAt: reset,
                resetDescription: nil))
        }
        if windows.isEmpty && !response.tokenBasedBilling {
            throw MajorProviderError.invalidResponse("GitHub Copilot returned no recognized quota percentages.")
        }
        return ProviderSnapshot(
            provider: .copilot,
            planName: response.copilotPlan?.capitalized,
            windows: windows,
            fetchedAt: now)
    }
}

private struct CopilotUsageResponse: Decodable {
    let quotaSnapshots: Snapshots
    let copilotPlan: String?
    let tokenBasedBilling: Bool
    let quotaResetDate: String?

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case tokenBasedBilling = "token_based_billing"
        case quotaResetDate = "quota_reset_date"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }

    struct Snapshots: Decodable {
        let premiumInteractions: Quota?
        let chat: Quota?

        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
        }
    }

    struct Counts: Decodable {
        let chat: Double?
        let completions: Double?
    }

    struct Quota: Decodable {
        let entitlement: Double?
        let remaining: Double?
        let percentRemaining: Double?
        let unlimited: Bool?

        enum CodingKeys: String, CodingKey {
            case entitlement
            case remaining
            case percentRemaining = "percent_remaining"
            case unlimited
        }

        var usedPercent: Double? {
            if unlimited == true { return nil }
            if let percentRemaining, percentRemaining.isFinite {
                return max(0, min(100, 100 - percentRemaining))
            }
            if let entitlement, entitlement > 0, let remaining {
                return max(0, min(100, 100 - (remaining / entitlement * 100)))
            }
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let direct = try container.decodeIfPresent(Snapshots.self, forKey: .quotaSnapshots)
        let monthly = try container.decodeIfPresent(Counts.self, forKey: .monthlyQuotas)
        let limited = try container.decodeIfPresent(Counts.self, forKey: .limitedUserQuotas)

        func fallback(_ total: Double?, _ remaining: Double?) -> Quota? {
            guard let total, total > 0, let remaining else { return nil }
            return Quota(entitlement: total, remaining: remaining, percentRemaining: nil, unlimited: false)
        }
        quotaSnapshots = Snapshots(
            premiumInteractions: direct?.premiumInteractions ?? fallback(monthly?.completions, limited?.completions),
            chat: direct?.chat ?? fallback(monthly?.chat, limited?.chat))
        copilotPlan = try container.decodeIfPresent(String.self, forKey: .copilotPlan)
        tokenBasedBilling = try container.decodeIfPresent(Bool.self, forKey: .tokenBasedBilling) ?? false
        quotaResetDate = try container.decodeIfPresent(String.self, forKey: .quotaResetDate)
    }
}

extension CopilotUsageResponse.Quota {
    init(entitlement: Double?, remaining: Double?, percentRemaining: Double?, unlimited: Bool?) {
        self.entitlement = entitlement
        self.remaining = remaining
        self.percentRemaining = percentRemaining
        self.unlimited = unlimited
    }
}

enum CopilotDeviceFlowService {
    private static let clientID = "Iv1.b507a08c87ecfe98"

    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String?
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    static func requestDeviceCode(session: URLSession = MajorProviderHTTP.session()) async throws -> DeviceCode {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["client_id": clientID, "scope": "read:user"])
        let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "GitHub")
        do { return try JSONDecoder().decode(DeviceCode.self, from: data) }
        catch { throw MajorProviderError.invalidResponse("GitHub device login returned an unexpected response.") }
    }

    static func poll(
        deviceCode: DeviceCode,
        session: URLSession = MajorProviderHTTP.session()) async throws -> String
    {
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, deviceCode.expiresIn)))
        var interval = max(1, deviceCode.interval)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form([
                "client_id": clientID,
                "device_code": deviceCode.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "GitHub")
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MajorProviderError.invalidResponse("GitHub device login returned invalid JSON.")
            }
            if let token = object["access_token"] as? String, !token.isEmpty { return token }
            switch object["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw MajorProviderError.authentication("GitHub device login expired. Start Sign in again.")
            case let error?: throw MajorProviderError.authentication("GitHub device login failed: \(error)")
            case nil: throw MajorProviderError.invalidResponse("GitHub device login returned neither a token nor an error.")
            }
        }
        throw MajorProviderError.authentication("GitHub device login timed out. Start Sign in again.")
    }

    private static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let body = values.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - Cursor

@MainActor
final class CursorProvider: UsageProvider {
    let id: ProviderID = .cursor
    private let session: URLSession
    private let tokenLoader: () throws -> String?

    init(
        session: URLSession = MajorProviderHTTP.session(),
        tokenLoader: @escaping () throws -> String? = { try CursorLocalAuth.loadAccessToken() })
    {
        self.session = session
        self.tokenLoader = tokenLoader
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let token = try tokenLoader(), !token.isEmpty else {
            throw MajorProviderError.authentication("Cursor.app login not found. Sign in to Cursor, then Refresh.")
        }
        let cookie = try CursorLocalAuth.cookieHeader(accessToken: token)
        var request = URLRequest(
            url: URL(string: "https://cursor.com/api/usage-summary")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "Cursor")
        return try Self.parseUsage(data: data)
    }

    static func parseUsage(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        let response: CursorUsageSummary
        do { response = try JSONDecoder().decode(CursorUsageSummary.self, from: data) }
        catch { throw MajorProviderError.invalidResponse("Cursor returned unexpected usage-summary data.") }
        guard let plan = response.individualUsage?.plan else {
            throw MajorProviderError.invalidResponse("Cursor usage-summary did not contain individual plan usage.")
        }
        let reset = MajorProviderHTTP.isoDate(response.billingCycleEnd)
        var windows: [UsageWindow] = []
        if let value = Self.validPercent(plan.totalPercentUsed) {
            windows.append(try UsageWindow(
                id: "cursor-0-total",
                kind: .monthly,
                label: "Included plan",
                compactLabel: "M",
                usedPercent: value,
                resetsAt: reset,
                resetDescription: nil))
        }
        if let value = Self.validPercent(plan.autoPercentUsed) {
            windows.append(try UsageWindow(
                id: "cursor-1-models",
                kind: .monthly,
                label: "Cursor Models",
                compactLabel: "CM",
                usedPercent: value,
                resetsAt: reset,
                resetDescription: nil))
        }
        if let value = Self.validPercent(plan.apiPercentUsed) {
            windows.append(try UsageWindow(
                id: "cursor-2-other",
                kind: .monthly,
                label: "Other Models",
                compactLabel: "OM",
                usedPercent: value,
                resetsAt: reset,
                resetDescription: nil))
        }
        if windows.isEmpty, let used = plan.used, let limit = plan.limit, limit > 0 {
            windows.append(try UsageWindow(
                id: "cursor-0-total",
                kind: .monthly,
                label: "Included plan",
                compactLabel: "M",
                usedPercent: max(0, min(100, Double(used) / Double(limit) * 100)),
                resetsAt: reset,
                resetDescription: nil))
        }
        guard !windows.isEmpty else {
            throw MajorProviderError.invalidResponse("Cursor returned no recognized monthly usage percentage.")
        }
        return ProviderSnapshot(
            provider: .cursor,
            planName: response.membershipType?.capitalized,
            windows: windows,
            fetchedAt: now)
    }

    private static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

private enum CursorLocalAuth {
    static func loadAccessToken(fileManager: FileManager = .default) throws -> String? {
        let path = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard fileManager.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(db)
            throw MajorProviderError.local("Cursor auth database could not be opened read-only: \(message)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MajorProviderError.local("Cursor auth database query could not be prepared.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func cookieHeader(accessToken: String, now: Date = Date()) throws -> String {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw MajorProviderError.authentication("Cursor.app access token is not a valid JWT.") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty else {
            throw MajorProviderError.authentication("Cursor.app access token is missing its user identity.")
        }
        if let expiration = object["exp"] as? NSNumber,
           Date(timeIntervalSince1970: expiration.doubleValue) <= now.addingTimeInterval(60) {
            throw MajorProviderError.authentication("Cursor.app login has expired. Sign in to Cursor again.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MajorProviderError.authentication("Cursor.app access token contains an invalid user identity.")
        }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }
}

private struct CursorUsageSummary: Decodable {
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: Individual?

    struct Individual: Decodable { let plan: Plan? }
    struct Plan: Decodable {
        let used: Int?
        let limit: Int?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }
}

// MARK: - Z.AI GLM Coding Plan

@MainActor
final class ZAIProvider: UsageProvider {
    let id: ProviderID = .zai
    static let keychainAccount = "zai.apiKey"
    private let session: URLSession
    private let keyLoader: () throws -> String?

    init(
        session: URLSession = MajorProviderHTTP.session(),
        keyLoader: @escaping () throws -> String? = {
            try AIUsageSecretStore.load(account: keychainAccount)
                ?? ProcessInfo.processInfo.environment["Z_AI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    {
        self.session = session
        self.keyLoader = keyLoader
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let key = try keyLoader(), !key.isEmpty else {
            throw MajorProviderError.authentication("Z.AI API key is required. Use Set API key on the Z.AI card.")
        }
        var request = URLRequest(
            url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "Z.AI")
        return try Self.parseUsage(data: data)
    }

    static func parseUsage(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              Self.integer(root["code"]) == 200,
              let body = root["data"] as? [String: Any],
              let rawLimits = body["limits"] as? [[String: Any]] else {
            throw MajorProviderError.invalidResponse("Z.AI returned unexpected Coding Plan quota data.")
        }

        var windows: [UsageWindow] = []
        for raw in rawLimits {
            guard let type = raw["type"] as? String, type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT",
                  let unit = Self.integer(raw["unit"]),
                  let number = Self.integer(raw["number"]),
                  number > 0,
                  let minutes = Self.windowMinutes(unit: unit, number: number),
                  let percent = Self.usedPercent(raw),
                  let kind = Self.kind(windowMinutes: minutes) else { continue }
            let reset = Self.integer(raw["nextResetTime"]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            windows.append(try UsageWindow(
                id: kind == .fiveHour ? "zai-five-hour" : "zai-weekly",
                kind: kind,
                label: kind == .fiveHour ? "5-hour" : "Weekly",
                compactLabel: kind == .fiveHour ? "5h" : "W",
                usedPercent: percent,
                resetsAt: reset,
                resetDescription: nil))
        }
        let unique = Dictionary(grouping: windows, by: \.id).compactMap { _, values in values.first }
        guard !unique.isEmpty else {
            throw MajorProviderError.invalidResponse("Z.AI returned no recognized 5-hour or weekly Coding Plan quota.")
        }
        let plan = ["planName", "plan", "plan_type", "packageName", "level"]
            .compactMap { body[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ProviderSnapshot(provider: .zai, planName: plan, windows: unique, fetchedAt: now)
    }

    private static func usedPercent(_ raw: [String: Any]) -> Double? {
        guard let fallback = number(raw["percentage"]), fallback.isFinite else { return nil }
        if let usage = number(raw["usage"]), usage > 0 {
            let current = number(raw["currentValue"])
            let remaining = number(raw["remaining"])
            let used: Double?
            if let remaining { used = max(0, min(usage, max(usage - remaining, current ?? usage - remaining))) }
            else { used = current.map { max(0, min(usage, $0)) } }
            if let used { return max(0, min(100, used / usage * 100)) }
        }
        return max(0, min(100, fallback))
    }

    private static func windowMinutes(unit: Int, number: Int) -> Int? {
        let multiplier: Int
        switch unit {
        case 1: multiplier = 1440
        case 3: multiplier = 60
        case 5: multiplier = 1
        case 6: multiplier = 10080
        default: return nil
        }
        return number * multiplier
    }

    private static func kind(windowMinutes: Int) -> UsageWindowKind? {
        switch windowMinutes {
        case 300: .fiveHour
        case 10080: .weekly
        default: nil
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let value = number(raw), value.isFinite, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }
}

// MARK: - Kimi Code

@MainActor
final class KimiProvider: UsageProvider {
    let id: ProviderID = .kimi
    private let session: URLSession
    private let credentialLoader: () throws -> KimiCredential

    init(
        session: URLSession = MajorProviderHTTP.session(),
        credentialLoader: @escaping () throws -> KimiCredential = { try KimiCredential.load() })
    {
        self.session = session
        self.credentialLoader = credentialLoader
    }

    func fetch() async throws -> ProviderSnapshot {
        let credential = try credentialLoader()
        var request = URLRequest(
            url: URL(string: "https://api.kimi.com/coding/v1/usages")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credential.isCLI {
            for (name, value) in credential.identityHeaders { request.setValue(value, forHTTPHeaderField: name) }
        }
        let data = try await MajorProviderHTTP.checkedData(for: request, session: session, provider: "Kimi Code")
        return try Self.parseUsage(data: data)
    }

    static func parseUsage(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        let response: KimiUsageResponse
        do { response = try JSONDecoder().decode(KimiUsageResponse.self, from: data) }
        catch { throw MajorProviderError.invalidResponse("Kimi Code returned unexpected usage data.") }
        var windows: [UsageWindow] = []
        if let weekly = try response.usage?.usedPercent(label: "Weekly") {
            windows.append(try UsageWindow(
                id: "kimi-weekly",
                kind: .weekly,
                label: "Weekly",
                compactLabel: "W",
                usedPercent: weekly,
                resetsAt: MajorProviderHTTP.isoDate(response.usage?.resetTime),
                resetDescription: nil))
        }
        for limit in response.limits ?? [] {
            guard limit.window.duration == 300,
                  limit.window.timeUnit.uppercased() == "TIME_UNIT_MINUTE",
                  let used = try limit.detail.usedPercent(label: "5-hour") else { continue }
            windows.append(try UsageWindow(
                id: "kimi-five-hour",
                kind: .fiveHour,
                label: "5-hour",
                compactLabel: "5h",
                usedPercent: used,
                resetsAt: MajorProviderHTTP.isoDate(limit.detail.resetTime),
                resetDescription: nil))
        }
        guard !windows.isEmpty else {
            throw MajorProviderError.invalidResponse("Kimi Code returned no recognized 5-hour or weekly quota.")
        }
        return ProviderSnapshot(provider: .kimi, planName: "Kimi Code", windows: windows, fetchedAt: now)
    }
}

struct KimiCredential: Equatable, Sendable {
    let token: String
    let isCLI: Bool
    let identityHeaders: [String: String]

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: Date = Date()) throws -> KimiCredential
    {
        if let key = environment["KIMI_CODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return KimiCredential(token: key, isCLI: false, identityHeaders: [:])
        }
        let home: URL
        if let override = environment["KIMI_CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            home = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            home = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
        }
        let credentialURL = home.appendingPathComponent("credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: credentialURL),
              let document = try? JSONDecoder().decode(KimiCLICredential.self, from: data),
              !document.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MajorProviderError.authentication(
                "Kimi Code credentials not found. Sign in with Kimi Code CLI or set KIMI_CODE_API_KEY, then Refresh.")
        }
        guard let expiration = document.expiresAt, expiration > now.addingTimeInterval(60).timeIntervalSince1970 else {
            throw MajorProviderError.authentication("Kimi Code CLI token has expired. Sign in with Kimi Code CLI again.")
        }
        let deviceURL = home.appendingPathComponent("device_id")
        guard let deviceID = try? String(contentsOf: deviceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceID.isEmpty else {
            throw MajorProviderError.authentication("Kimi Code CLI device identity is missing. Sign in with the official Kimi Code CLI again.")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let headers = [
            "User-Agent": "AIUsage/1.0",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": "1.0",
            "X-Msh-Device-Name": ascii(ProcessInfo.processInfo.hostName),
            "X-Msh-Device-Model": ascii("macOS \(osVersion)"),
            "X-Msh-Os-Version": ascii(osVersion),
            "X-Msh-Device-Id": ascii(deviceID),
        ]
        return KimiCredential(token: document.accessToken, isCLI: true, identityHeaders: headers)
    }

    private static func ascii(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { (0x20...0x7e).contains($0.value) }
        let value = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unknown" : value
    }
}

private struct KimiCLICredential: Decodable {
    let accessToken: String
    let expiresAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
        if let value = try? container.decode(Double.self, forKey: .expiresAt) { expiresAt = value }
        else if let value = try? container.decode(Int64.self, forKey: .expiresAt) { expiresAt = TimeInterval(value) }
        else if let value = try? container.decode(String.self, forKey: .expiresAt) { expiresAt = TimeInterval(value) }
        else { expiresAt = nil }
    }
}

private struct KimiUsageResponse: Decodable {
    let usage: Detail?
    let limits: [Limit]?

    struct Limit: Decodable {
        let window: Window
        let detail: Detail
    }
    struct Window: Decodable {
        let duration: Int
        let timeUnit: String
    }
    struct Detail: Decodable {
        let limit: String?
        let used: String?
        let remaining: String?
        let resetTime: String?

        func usedPercent(label: String) throws -> Double? {
            guard let limit, let total = Double(limit), total > 0 else { return nil }
            let usedValue: Double?
            if let used, let parsed = Double(used) { usedValue = parsed }
            else if let remaining, let parsed = Double(remaining) { usedValue = total - parsed }
            else { return nil }
            guard let usedValue, usedValue.isFinite, usedValue >= 0 else {
                throw MajorProviderError.invalidResponse("Kimi Code returned an invalid \(label) usage value.")
            }
            return max(0, min(100, usedValue / total * 100))
        }
    }
}
