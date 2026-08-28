import AppKit
import WebKit

enum LoginSuccessRules {
    static func isSuccess(provider: ProviderID, url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        switch provider {
        case .openCodeGo:
            guard url.host == "opencode.ai" else { return false }
            let path = url.path
            return path == "/console" || path.hasPrefix("/console/") ||
                path.range(of: #"^/workspace/wrk_[A-Za-z0-9_-]+(?:/go)?/?$"#, options: .regularExpression) != nil
        case .qwen:
            return url.host == "home.qwencloud.com" && url.path.hasPrefix("/billing/")
        case .codex, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            return false
        }
    }
}

@MainActor
final class WebLoginWindowController: NSObject, NSWindowDelegate {
    private let provider: ProviderID
    private let accountLabel: String?
    private let startURL: URL
    private let dataStore: WKWebsiteDataStore
    private let onSuccess: (URL) -> Void
    private var window: NSWindow?
    private var webView: WKWebView?
    private var successTask: Task<Void, Never>?
    private var isCompleting = false

    init(
        provider: ProviderID,
        accountLabel: String? = nil,
        startURL: URL,
        dataStore: WKWebsiteDataStore = .default(),
        onSuccess: @escaping (URL) -> Void)
    {
        self.provider = provider
        self.accountLabel = accountLabel
        self.startURL = startURL
        self.dataStore = dataStore
        self.onSuccess = onSuccess
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        cancelPendingSuccess()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        let suffix = accountLabel.map { " — \($0)" } ?? ""
        window.title = "Sign in to \(provider.displayName)\(suffix)"
        window.contentView = webView
        window.delegate = self
        window.center()
        self.webView = webView
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: startURL))
    }

    func close() {
        cancelPendingSuccess()
        webView?.stopLoading()
        window?.orderOut(nil)
        window = nil
        webView = nil
    }

    private func navigationPolicy(for url: URL) -> WKNavigationActionPolicy {
        guard url.scheme == "https" else { return .cancel }
        switch provider {
        case .openCodeGo:
            return ["opencode.ai", "auth.opencode.ai"].contains(url.host) ? .allow : .cancel
        case .qwen:
            return ["home.qwencloud.com", "cs-data.qwencloud.com", "passport.qwencloud.com",
                    "qwencloud.com", "qianwenai.com"].contains(url.host) ? .allow : .cancel
        case .codex, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            return .cancel
        }
    }

    private func handlePossibleSuccess(url: URL) {
        guard LoginSuccessRules.isSuccess(provider: provider, url: url) else {
            cancelPendingSuccess()
            return
        }
        guard !isCompleting else { return }

        isCompleting = true
        successTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            close()
            onSuccess(url)
        }
    }

    private func cancelPendingSuccess() {
        successTask?.cancel()
        successTask = nil
        isCompleting = false
    }
}

extension WebLoginWindowController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
    {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(navigationPolicy(for: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        handlePossibleSuccess(url: url)
    }

    func windowWillClose(_ notification: Notification) {
        cancelPendingSuccess()
        webView?.stopLoading()
        window = nil
        webView = nil
    }
}
