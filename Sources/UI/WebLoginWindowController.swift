import AppKit
import WebKit

enum LoginSuccessRules {
    static func isSuccess(provider: ProviderID, url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        switch provider {
        case .openCodeGo:
            return url.host == "opencode.ai" && !url.path.contains("/auth")
        case .qwen:
            return url.host == "home.qwencloud.com" &&
                !url.path.lowercased().contains("login") &&
                !url.path.lowercased().contains("signin")
        case .codex:
            return false
        }
    }
}

@MainActor
final class WebLoginWindowController: NSObject, NSWindowDelegate {
    private let provider: ProviderID
    private let startURL: URL
    private let onSuccess: (URL) -> Void
    private var window: NSWindow?
    private var webView: WKWebView?
    private var successTask: Task<Void, Never>?
    private var isCompleting = false

    init(provider: ProviderID, startURL: URL, onSuccess: @escaping (URL) -> Void) {
        self.provider = provider
        self.startURL = startURL
        self.onSuccess = onSuccess
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // A controller is retained per provider and may be reused after a
        // successful sign-in or manual close. Reset one-shot state before each
        // new browser session so subsequent sign-ins can complete normally.
        successTask?.cancel()
        successTask = nil
        isCompleting = false

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Sign in to \(provider.displayName)"
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
        successTask?.cancel()
        successTask = nil
        webView?.stopLoading()
        window?.orderOut(nil)
        window = nil
        webView = nil
        isCompleting = false
    }

    /// Only provider account hosts and their OAuth endpoints may load inside
    /// the sign-in window. Unexpected destinations are blocked rather than
    /// inheriting authenticated browser state.
    private func navigationPolicy(for url: URL) -> WKNavigationActionPolicy {
        guard url.scheme == "https" else { return .cancel }
        switch provider {
        case .openCodeGo:
            return ["opencode.ai", "auth.opencode.ai"].contains(url.host) ? .allow : .cancel
        case .qwen:
            return ["home.qwencloud.com", "cs-data.qwencloud.com", "passport.qwencloud.com",
                    "qwencloud.com", "qianwenai.com"].contains(url.host) ? .allow : .cancel
        case .codex:
            return .cancel
        }
    }

    private func handlePossibleSuccess(url: URL) {
        guard !isCompleting, LoginSuccessRules.isSuccess(provider: provider, url: url) else { return }
        isCompleting = true
        successTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            close()
            onSuccess(url)
        }
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
        successTask?.cancel()
        successTask = nil
        webView?.stopLoading()
        window = nil
        webView = nil
        isCompleting = false
    }
}
