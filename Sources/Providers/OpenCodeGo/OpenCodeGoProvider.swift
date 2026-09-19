import AppKit
import Foundation
import WebKit

enum OpenCodeGoNavigationDecision: Equatable {
    case allow
    case cancelSubframe
    case rejectMainFrame
}

/// GoUsage-compatible OpenCode Go fetcher. Each provider instance can receive a
/// distinct persistent WKWebsiteDataStore, allowing simultaneous accounts.
@MainActor
final class OpenCodeGoProvider: NSObject, UsageProvider {
    let id: ProviderID = .openCodeGo

    private let workspaceStore: OpenCodeWorkspaceStore
    private let webView: WKWebView
    private let hiddenWindow: NSWindow
    private let consoleSnapshotLoader: (() async throws -> ProviderSnapshot)?
    private var continuation: CheckedContinuation<ProviderSnapshot, Error>?
    private var activeGeneration = 0
    private var activeNavigation: WKNavigation?
    private var scrapeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var scrapeRetries = 0
    private var hasRetriedConsoleAfterDashboardLoad = false
    private(set) var lastObservedURL: URL?

    private var startURL: URL {
        workspaceStore.workspaceID == nil ? Self.discoveryURL : workspaceStore.usageURL
    }

    private static let discoveryURL = URL(string: "https://opencode.ai/console/")!

    init(
        workspaceStore: OpenCodeWorkspaceStore = OpenCodeWorkspaceStore(),
        dataStore: WKWebsiteDataStore = .default(),
        injectedWebView: WKWebView? = nil,
        consoleSnapshotLoader: (() async throws -> ProviderSnapshot)? = nil)
    {
        self.workspaceStore = workspaceStore
        if let consoleSnapshotLoader {
            self.consoleSnapshotLoader = consoleSnapshotLoader
        } else if injectedWebView == nil {
            let client = OpenCodeGoConsoleClient(
                workspaceStore: workspaceStore,
                dataStore: dataStore)
            self.consoleSnapshotLoader = { try await client.fetch() }
        } else {
            self.consoleSnapshotLoader = nil
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = injectedWebView ?? WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            configuration: configuration)
        hiddenWindow = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 1000, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        super.init()
        hiddenWindow.contentView = webView
        webView.navigationDelegate = self
    }

    func fetch() async throws -> ProviderSnapshot {
        if let consoleSnapshotLoader {
            do {
                return try await consoleSnapshotLoader()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OpenCodeGoError where error == .notSubscribed {
                throw error
            } catch {
                // The console JSON endpoint is preferred because it is the data
                // source used by the dashboard. Keep the DOM path as a fallback
                // for transient endpoint or schema failures.
            }
        }
        return try await fetchDashboard()
    }

    private func fetchDashboard() async throws -> ProviderSnapshot {
        guard continuation == nil else { throw OpenCodeGoError.navigation("refresh already in progress") }
        activeGeneration += 1
        scrapeRetries = 0
        hasRetriedConsoleAfterDashboardLoad = false
        let generation = activeGeneration
        defer { Task { @MainActor in self.lastObservedURL = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.startTimeout(generation: generation)
            self.activeNavigation = self.webView.load(URLRequest(
                url: self.startURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30))
        }
    }

    func cancelActiveFetch() {
        activeNavigation = nil
        webView.stopLoading()
        complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation("fetch cancelled")))
    }

    private func startTimeout(generation: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled else { return }
            self?.complete(generation: generation, .failure(OpenCodeGoError.navigation("timed out")))
        }
    }

    private func scheduleScrape(generation: Int, delay: Duration = .seconds(2)) {
        scrapeTask?.cancel()
        scrapeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scrape(generation: generation)
        }
    }

    func scrape(generation: Int) {
        if let consoleSnapshotLoader, !hasRetriedConsoleAfterDashboardLoad {
            hasRetriedConsoleAfterDashboardLoad = true
            Task { [weak self] in
                do {
                    let snapshot = try await consoleSnapshotLoader()
                    self?.complete(generation: generation, .success(snapshot))
                } catch is CancellationError {
                    self?.complete(generation: generation, .failure(CancellationError()))
                } catch let error as OpenCodeGoError where error == .notSubscribed {
                    self?.complete(generation: generation, .failure(error))
                } catch {
                    self?.scrapeDashboard(generation: generation)
                }
            }
            return
        }
        scrapeDashboard(generation: generation)
    }

    private func scrapeDashboard(generation: Int) {
        webView.evaluateJavaScript(Self.scrapeJS) { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.activeGeneration == generation, self.continuation != nil else { return }
                if let error {
                    self.scrapeRetries += 1
                    if self.scrapeRetries <= 3 {
                        self.scheduleScrape(generation: generation, delay: .seconds(2))
                        return
                    }
                    self.lastObservedURL = self.webView.url
                    self.complete(generation: generation, .failure(OpenCodeGoError.navigation(error.localizedDescription)))
                    return
                }
                guard let json = value as? String else {
                    self.lastObservedURL = self.webView.url
                    self.complete(generation: generation, .failure(OpenCodeGoError.invalidResponse))
                    return
                }
                if let redirect = Self.workspaceRedirect(from: json), redirect != self.webView.url {
                    self.activeNavigation = self.webView.load(URLRequest(url: redirect, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                    return
                }
                do {
                    let result = try OpenCodeGoParser.parse(jsonText: json)
                    if let workspaceID = result.workspaceID { self.workspaceStore.save(workspaceID) }
                    self.complete(generation: generation, .success(result.snapshot))
                } catch {
                    self.lastObservedURL = self.webView.url
                    self.complete(generation: generation, .failure(error))
                }
            }
        }
    }

    private func complete(generation: Int, _ result: Result<ProviderSnapshot, Error>) {
        guard activeGeneration == generation, let continuation else { return }
        if case let .failure(error) = result,
           let openCodeError = error as? OpenCodeGoError,
           openCodeError == .invalidResponse,
           scrapeRetries < 3
        {
            scrapeRetries += 1
            scheduleScrape(generation: generation, delay: .seconds(2))
            return
        }
        self.continuation = nil
        activeNavigation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        scrapeTask?.cancel()
        scrapeTask = nil
        continuation.resume(with: result)
    }

    private static func workspaceRedirect(from json: String) -> URL? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlText = object["url"] as? String,
              let url = URL(string: urlText),
              url.host == "opencode.ai",
              let items = object["items"] as? [[String: Any]], items.isEmpty
        else { return nil }
        let consolePattern = #"^/console/(wrk_[A-Za-z0-9_-]+)(?:/go)?/?$"#
        let legacyPattern = #"^/workspace/(wrk_[A-Za-z0-9_-]+)(?:/go)?/?$"#
        let path = url.path
        if path.range(of: consolePattern, options: .regularExpression) != nil {
            let base = path.hasSuffix("/") ? String(path.dropLast()) : path
            return URL(string: "https://opencode.ai" + (base.hasSuffix("/go") ? base : base + "/go"))
        }
        guard let match = path.range(of: legacyPattern, options: .regularExpression) else { return nil }
        let legacy = String(path[match])
        let components = legacy.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return URL(string: "https://opencode.ai/console/\(components[1])/go")
    }

    private static func isAllowedScraperURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        return url.host == "opencode.ai" || url.host == "auth.opencode.ai"
    }

    static func navigationDecision(for url: URL?, isMainFrame: Bool?) -> OpenCodeGoNavigationDecision {
        guard let url else { return .rejectMainFrame }
        if isAllowedScraperURL(url) { return .allow }
        return isMainFrame == false ? .cancelSubframe : .rejectMainFrame
    }

    static let scrapeJS = """
    (function(){
      var items = document.querySelectorAll('[data-slot="usage-item"]');
      var out = [];
      for (var i = 0; i < items.length; i++) {
        var el = items[i];
        var q = function(s){ var n = el.querySelector(s); return n && n.textContent ? n.textContent.trim() : ''; };
        out.push({ label: q('[data-slot="usage-label"]'), value: q('[data-slot="usage-value"]'), reset: q('[data-slot="reset-time"]') });
      }
      if (!out.length) {
        var section = document.querySelector('[aria-label="Go usage limits"]');
        var cards = section ? section.children : [];
        for (var c = 0; c < cards.length; c++) {
          var nodes = cards[c].querySelectorAll('*');
          var label = '';
          var value = '';
          var reset = '';
          for (var n = 0; n < nodes.length; n++) {
            var text = (nodes[n].textContent || '').trim();
            if (!label && /^(Rolling|Weekly|Monthly) usage$/i.test(text)) label = text;
            if (!value && /^\\d+(?:\\.\\d+)?\\s*%$/.test(text)) value = text;
            if (!reset && /^Resets in\\b/i.test(text)) reset = nodes[n].getAttribute('title') || text;
          }
          if (label || value) out.push({ label: label, value: value, reset: reset });
        }
      }
      var promo = !!document.querySelector('[data-slot="subscribe-button"]');
      var other = !!document.querySelector('[data-slot="other-message"]');
      var cb = document.querySelector('form[data-slot="setting-row"] input[type="checkbox"]');
      var links = document.querySelectorAll('a[href]');
      var target = '';
      for (var j = 0; j < links.length; j++) {
        try {
          var link = new URL(links[j].href || '', location.origin);
          if (link.host === 'opencode.ai' && /^\\/console\\/wrk_[A-Za-z0-9_-]+\\/go\\/?$/.test(link.pathname)) {
            target = link.href;
            break;
          }
        } catch (_) {}
      }
      if (!target) {
        var html = document.documentElement.innerHTML;
        var current = html.match(/(?:https:\\/\\/opencode\\.ai)?(\\/console\\/wrk_[A-Za-z0-9_-]+)(?:\\/go)?/);
        var legacy = html.match(/(?:https:\\/\\/opencode\\.ai)?(\\/workspace\\/wrk_[A-Za-z0-9_-]+)(?:\\/go)?/);
        if (current) { target = 'https://opencode.ai' + current[1] + '/go'; }
        else if (legacy) {
          var workspace = legacy[1].split('/').pop();
          target = 'https://opencode.ai/console/' + workspace + '/go';
        }
      }
      if (!target) {
        var scripts = document.querySelectorAll('script');
        for (var k = 0; k < scripts.length && !target; k++) {
          var text = scripts[k].textContent || '';
          var m = text.match(/wrk_[A-Za-z0-9_-]{8,}/);
          if (m) { target = 'https://opencode.ai/console/' + m[0] + '/go'; }
        }
      }
      return JSON.stringify({
        url: target || location.href,
        items: out,
        promo: promo,
        other: other,
        useBalance: cb ? cb.checked : null
      });
    })()
    """
}

extension OpenCodeGoProvider: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
    {
        switch Self.navigationDecision(
            for: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame)
        {
        case .allow:
            decisionHandler(.allow)
        case .cancelSubframe:
            // The current Go console embeds Stripe payment UI. That subframe is
            // unrelated to usage scraping; suppress it without failing the
            // main opencode.ai navigation.
            decisionHandler(.cancel)
        case .rejectMainFrame:
            decisionHandler(.cancel)
            complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation("blocked navigation to an unexpected host")))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === activeNavigation, continuation != nil else { return }
        scheduleScrape(generation: activeGeneration)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation, continuation != nil else { return }
        complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation, continuation != nil else { return }
        complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation(error.localizedDescription)))
    }
}

@MainActor
final class OpenCodeGoConsoleClient {
    typealias CookieLoader = () async -> [HTTPCookie]
    typealias RequestLoader = (URLRequest) async throws -> (Data, URLResponse)

    private static let organizationsURL = URL(string: "https://opencode.ai/console/api/orgs")!
    private static let statusURL = URL(string: "https://opencode.ai/console/api/go/status")!

    private let workspaceStore: OpenCodeWorkspaceStore
    private let cookieLoader: CookieLoader
    private let requestLoader: RequestLoader

    init(
        workspaceStore: OpenCodeWorkspaceStore,
        cookieLoader: @escaping CookieLoader,
        requestLoader: @escaping RequestLoader)
    {
        self.workspaceStore = workspaceStore
        self.cookieLoader = cookieLoader
        self.requestLoader = requestLoader
    }

    convenience init(
        workspaceStore: OpenCodeWorkspaceStore,
        dataStore: WKWebsiteDataStore,
        session: URLSession = OpenCodeGoConsoleClient.makeSession())
    {
        self.init(
            workspaceStore: workspaceStore,
            cookieLoader: {
                await withCheckedContinuation { continuation in
                    dataStore.httpCookieStore.getAllCookies {
                        continuation.resume(returning: $0)
                    }
                }
            },
            requestLoader: { request in
                try await session.data(for: request)
            })
    }

    func fetch() async throws -> ProviderSnapshot {
        let cookies = await cookieLoader()
        guard Self.hasConsoleSession(cookies) else { throw OpenCodeGoError.notLoggedIn }

        let workspaceID: String
        if let stored = workspaceStore.workspaceID {
            workspaceID = stored
        } else {
            let organizationsRequest = try Self.makeOrganizationsRequest(cookies: cookies)
            let organizationsData = try await load(organizationsRequest)
            do {
                workspaceID = try Self.parseWorkspaceID(data: organizationsData)
            } catch {
                throw OpenCodeGoConsoleError.unavailable
            }
            workspaceStore.save(workspaceID)
        }

        let statusRequest = try Self.makeStatusRequest(
            workspaceID: workspaceID,
            cookies: cookies)
        let statusData = try await load(statusRequest)
        do {
            return try OpenCodeGoConsoleStatusParser.parse(data: statusData)
        } catch let error as OpenCodeGoError where error == .notSubscribed {
            throw error
        } catch {
            throw OpenCodeGoConsoleError.unavailable
        }
    }

    nonisolated static func parseWorkspaceID(data: Data) throws -> String {
        guard let organizations = try? JSONDecoder().decode([Organization].self, from: data),
              let workspaceID = organizations.map(\.id).first(where: { candidate in
                  candidate.range(
                      of: #"^wrk_[A-Za-z0-9_\-]{3,128}$"#,
                      options: .regularExpression) != nil
              })
        else { throw OpenCodeGoError.invalidResponse }
        return workspaceID
    }

    static func makeOrganizationsRequest(cookies: [HTTPCookie]) throws -> URLRequest {
        try makeRequest(url: organizationsURL, workspaceID: nil, cookies: cookies)
    }

    static func makeStatusRequest(workspaceID: String, cookies: [HTTPCookie]) throws -> URLRequest {
        guard workspaceID.range(
            of: #"^wrk_[A-Za-z0-9_\-]{3,128}$"#,
            options: .regularExpression) != nil
        else { throw OpenCodeGoError.invalidResponse }
        return try makeRequest(url: statusURL, workspaceID: workspaceID, cookies: cookies)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: RejectRedirectDelegate(),
            delegateQueue: nil)
    }

    private static func makeRequest(
        url: URL,
        workspaceID: String?,
        cookies: [HTTPCookie]
    ) throws -> URLRequest {
        let matchingCookies = cookies.filter(Self.isUsableOpenCodeCookie)
        guard !matchingCookies.isEmpty else { throw OpenCodeGoError.notLoggedIn }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20)
        request.httpMethod = "GET"
        if let workspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: "x-org-id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: matchingCookies)
        request.setValue(cookieHeaders["Cookie"], forHTTPHeaderField: "Cookie")
        request.setValue("AIUsage/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func hasConsoleSession(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            isUsableOpenCodeCookie(cookie) &&
                (cookie.name == "__Host-console_session" || cookie.name == "console_session")
        }
    }

    private static func isUsableOpenCodeCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "opencode.ai" && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenCodeGoConsoleError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeGoConsoleError.unavailable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OpenCodeGoError.notLoggedIn
        }
        guard (200...299).contains(http.statusCode) else {
            throw OpenCodeGoConsoleError.unavailable
        }
        return data
    }

    private struct Organization: Decodable {
        let id: String
    }
}

enum OpenCodeGoConsoleError: Error {
    case unavailable
}

/// Parser for OpenCode's lightweight Go usage endpoint. This endpoint is used
/// only as a recovery timing hint; the WebKit dashboard remains the source of
/// truth for values shown by AIUsage and for recovery notifications.
enum OpenCodeGoAPIUsageParser {
    static func parse(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OpenCodeGoAPIError.invalidResponse
        }

        let inputs: [(UsageWindowKind, String, APIWindow)] = [
            (.fiveHour, "5-hour", response.usage.rolling),
            (.weekly, "Weekly", response.usage.weekly),
            (.monthly, "Monthly", response.usage.monthly),
        ]
        let windows = try inputs.map { kind, label, item in
            guard item.percent.isFinite,
                  (0...100).contains(item.percent),
                  let reset = parseISO8601(item.resetsAt)
            else { throw OpenCodeGoAPIError.invalidResponse }
            return try UsageWindow(
                kind: kind,
                label: label,
                usedPercent: item.percent,
                resetsAt: reset,
                resetDescription: nil)
        }
        return ProviderSnapshot(
            provider: .openCodeGo,
            planName: "OpenCode Go",
            windows: windows,
            fetchedAt: now)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private struct Response: Decodable {
        let usage: Usage
    }

    private struct Usage: Decodable {
        let rolling: APIWindow
        let weekly: APIWindow
        let monthly: APIWindow
    }

    private struct APIWindow: Decodable {
        let percent: Double
        let resetsAt: String
    }
}

enum OpenCodeGoAPIError: LocalizedError, Equatable {
    case missingKey
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "OpenCode Go API key is missing."
        case .invalidResponse: "OpenCode Go recovery probe returned invalid usage data."
        case let .http(status): "OpenCode Go recovery probe returned HTTP \(status)."
        }
    }
}

@MainActor
enum OpenCodeGoAPIClient {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func fetch(apiKey: String, session: URLSession) async throws -> ProviderSnapshot {
        let request = try makeRequest(apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeGoAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw OpenCodeGoAPIError.http(http.statusCode) }
        return try OpenCodeGoAPIUsageParser.parse(data: data)
    }

    static func makeRequest(apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenCodeGoAPIError.missingKey }
        var request = URLRequest(
            url: usageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: RejectRedirectDelegate(),
            delegateQueue: nil)
    }
}

enum OpenCodeGoRecoveryPlanner {
    static let normalRecheckInterval: TimeInterval = 300
    static let minimumDelay: TimeInterval = 5
    static let resetGrace: TimeInterval = 2

    static func didRecover(previous: ProviderSnapshot?, current: ProviderSnapshot) -> Bool {
        guard let previous,
              previous.provider == .openCodeGo,
              current.provider == .openCodeGo else { return false }
        let old = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0.remainingPercent) })
        return current.windows.contains { window in
            guard let prior = old[window.id] else { return false }
            return prior < 100 && window.remainingPercent >= 100
        }
    }

    static func nextDelay(snapshot: ProviderSnapshot, now: Date) -> TimeInterval {
        let nextReset = snapshot.windows
            .filter { $0.remainingPercent < 100 }
            .compactMap(\.resetsAt)
            .min()
        guard let nextReset else { return normalRecheckInterval }
        let untilReset = nextReset.timeIntervalSince(now) + resetGrace
        return min(normalRecheckInterval, max(minimumDelay, untilReset))
    }
}

/// Optional best-effort monitor for faster OpenCode Go recovery notifications.
/// It never publishes API values. A lightweight API recovery transition only
/// triggers the normal WebKit refresh, which must independently confirm 100%.
@MainActor
final class OpenCodeGoRecoveryMonitor {
    typealias KeyLoader = (ProviderInstance) throws -> String?
    typealias ConfirmRefresh = (UUID) async -> Void

    private let session: URLSession
    private let keyLoader: KeyLoader
    private let confirmRefresh: ConfirmRefresh
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        session: URLSession = OpenCodeGoAPIClient.makeSession(),
        keyLoader: @escaping KeyLoader = { try ProviderInstanceCredentialStore.secret(for: $0) },
        confirmRefresh: @escaping ConfirmRefresh
    ) {
        self.session = session
        self.keyLoader = keyLoader
        self.confirmRefresh = confirmRefresh
    }

    func sync(instances: [ProviderInstance]) {
        let eligible = Dictionary(uniqueKeysWithValues: instances
            .filter { $0.provider == .openCodeGo }
            .map { ($0.id, $0) })

        for id in Set(tasks.keys).subtracting(Set(eligible.keys)) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        for (id, instance) in eligible where tasks[id] == nil {
            start(instance)
        }
    }

    func restart(_ instance: ProviderInstance) {
        tasks.removeValue(forKey: instance.id)?.cancel()
        guard instance.provider == .openCodeGo else { return }
        start(instance)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func start(_ instance: ProviderInstance) {
        tasks[instance.id] = Task { [weak self] in
            await self?.run(instance)
        }
    }

    private func run(_ instance: ProviderInstance) async {
        var previous: ProviderSnapshot?

        while !Task.isCancelled {
            do {
                guard let apiKey = try keyLoader(instance),
                      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    previous = nil
                    try await sleep(seconds: OpenCodeGoRecoveryPlanner.normalRecheckInterval)
                    continue
                }

                let current = try await OpenCodeGoAPIClient.fetch(apiKey: apiKey, session: session)
                if OpenCodeGoRecoveryPlanner.didRecover(previous: previous, current: current) {
                    await confirmRefresh(instance.id)
                }
                previous = current

                let delay = OpenCodeGoRecoveryPlanner.nextDelay(snapshot: current, now: Date())
                try await sleep(seconds: delay)
            } catch is CancellationError {
                return
            } catch let error as OpenCodeGoAPIError {
                if case let .http(status) = error, status == 401 || status == 403 {
                    previous = nil
                }
                try? await sleep(seconds: OpenCodeGoRecoveryPlanner.normalRecheckInterval)
            } catch {
                try? await sleep(seconds: OpenCodeGoRecoveryPlanner.normalRecheckInterval)
            }
        }
    }

    private func sleep(seconds: TimeInterval) async throws {
        let milliseconds = Int64(max(1, seconds * 1_000))
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
