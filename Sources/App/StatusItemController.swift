import AppKit
import Combine
import SwiftUI

@MainActor
final class PopoverLayoutMetrics: ObservableObject {
    @Published var providerListHeight: CGFloat = 0
}

struct QuotaRecoveryEvent: Equatable, Sendable {
    let instanceID: UUID
    let provider: ProviderID
    let accountTitle: String
    let windowID: String
    let windowKind: UsageWindowKind

    var message: String {
        "\(Self.windowName(windowKind))利用量が回復しました！"
    }

    private static func windowName(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour: "5時間"
        case .weekly: "週間"
        case .monthly: "月間"
        }
    }
}

/// Detects only transitions from a partially consumed quota to a completely
/// restored quota. The first observation is a baseline and never emits an event.
struct QuotaRecoveryDetector {
    private struct Key: Hashable {
        let instanceID: UUID
        let windowID: String
    }

    private var previousRemaining: [Key: Double] = [:]

    mutating func observe(
        snapshots: [UUID: ProviderSnapshot],
        instanceLookup: (UUID) -> ProviderInstance?
    ) -> [QuotaRecoveryEvent] {
        var activeKeys: Set<Key> = []
        var events: [QuotaRecoveryEvent] = []

        for (instanceID, snapshot) in snapshots {
            guard let instance = instanceLookup(instanceID) else { continue }

            for window in snapshot.windows {
                let key = Key(instanceID: instanceID, windowID: window.id)
                activeKeys.insert(key)
                let remaining = window.remainingPercent

                if let previous = previousRemaining[key],
                   previous < 100,
                   remaining >= 100
                {
                    events.append(QuotaRecoveryEvent(
                        instanceID: instanceID,
                        provider: snapshot.provider,
                        accountTitle: instance.title,
                        windowID: window.id,
                        windowKind: window.kind))
                }

                previousRemaining[key] = remaining
            }
        }

        previousRemaining = previousRemaining.filter { activeKeys.contains($0.key) }
        return events.sorted {
            ($0.accountTitle, $0.windowKind.sortOrderForRecoveryToast, $0.windowID)
                < ($1.accountTitle, $1.windowKind.sortOrderForRecoveryToast, $1.windowID)
        }
    }
}

private extension UsageWindowKind {
    var sortOrderForRecoveryToast: Int {
        switch self {
        case .fiveHour: 0
        case .weekly: 1
        case .monthly: 2
        }
    }
}

struct QuotaRecoveryToastLayout {
    static let margin: CGFloat = 8
    static let verticalGap: CGFloat = 7
    static let revealOffset: CGFloat = 6

    static func targetOrigin(
        anchor: CGRect,
        visibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGPoint {
        let idealX = anchor.midX - panelSize.width / 2
        let minX = visibleFrame.minX + margin
        let unclampedMaxX = visibleFrame.maxX - panelSize.width - margin
        let maxX = max(minX, unclampedMaxX)
        let x = min(max(idealX, minX), maxX)
        let y = max(
            visibleFrame.minY + margin,
            anchor.minY - panelSize.height - verticalGap)
        return CGPoint(x: x, y: y)
    }

    static func initialOrigin(target: CGPoint) -> CGPoint {
        CGPoint(x: target.x, y: target.y + revealOffset)
    }
}

/// Reads only OpenCode's documented local auth storage for the stable default
/// card. Duplicate AIUsage cards never inherit ambient CLI credentials.
enum OpenCodeGoAmbientCredentialLoader {
    static func apiKey(
        for instance: ProviderInstance,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard instance.provider == .openCodeGo, instance.isDefaultSlot else { return nil }

        if let environmentKey = cleaned(environment["OPENCODE_API_KEY"]) {
            return environmentKey
        }

        let authURL = homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL, options: .mappedIfSafe) else { return nil }
        return apiKey(fromAuthData: data)
    }

    static func apiKey(fromAuthData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["opencode"] as? [String: Any],
              entry["type"] as? String == "api"
        else { return nil }
        return cleaned(entry["key"] as? String)
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
private final class QuotaRecoveryToastController {
    private struct Toast {
        let title: String
        let message: String
    }

    private weak var anchorView: NSView?
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var queue: [Toast] = []
    private var dismissWorkItem: DispatchWorkItem?
    private var isShowing = false

    init(anchorView: NSView) {
        self.anchorView = anchorView
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effectView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        messageLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])

        panel.contentView = effectView
    }

    func enqueue(title: String, message: String) {
        queue.append(Toast(title: title, message: message))
        showNextIfNeeded()
    }

    private func showNextIfNeeded() {
        guard !isShowing, !queue.isEmpty else { return }
        guard let anchorView, let anchorWindow = anchorView.window else {
            queue.removeAll()
            return
        }

        isShowing = true
        let toast = queue.removeFirst()
        titleLabel.stringValue = toast.title
        messageLabel.stringValue = toast.message

        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorOnScreen = anchorWindow.convertToScreen(anchorInWindow)
        let visibleFrame = anchorWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let targetOrigin = QuotaRecoveryToastLayout.targetOrigin(
            anchor: anchorOnScreen,
            visibleFrame: visibleFrame,
            panelSize: panel.frame.size)
        panel.setFrameOrigin(QuotaRecoveryToastLayout.initialOrigin(target: targetOrigin))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(targetOrigin)
        }

        let item = DispatchWorkItem { [weak self] in self?.dismissCurrent() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: item)
    }

    private func dismissCurrent() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.isShowing = false
                self.showNextIfNeeded()
            }
        })
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let coordinator: UsageCoordinator
    private let settings: SettingsStore
    private let layoutMetrics = PopoverLayoutMetrics()
    private var recoveryDetector = QuotaRecoveryDetector()
    private var recoveryToastController: QuotaRecoveryToastController?
    private var openCodeRecoveryMonitor: OpenCodeGoRecoveryMonitor?
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: UsageCoordinator, settings: SettingsStore, actions: AppActions) {
        self.coordinator = coordinator
        self.settings = settings
        super.init()

        openCodeRecoveryMonitor = OpenCodeGoRecoveryMonitor(
            keyLoader: { instance in OpenCodeGoAmbientCredentialLoader.apiKey(for: instance) },
            confirmRefresh: { [weak coordinator] id in
                await coordinator?.refresh(id)
            })

        let dashboard = DashboardView(
            coordinator: coordinator,
            settings: settings,
            layoutMetrics: layoutMetrics,
            actions: actions)
        popover.contentViewController = NSHostingController(rootView: dashboard)
        popover.behavior = .transient
        popover.animates = true

        configureButton()
        observeChanges()
        openCodeRecoveryMonitor?.sync(instances: settings.registeredProviders)
        updatePopoverSize()
        render()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.setAccessibilityRole(.button)
        button.addObserver(self, forKeyPath: "effectiveAppearance", context: nil)
        recoveryToastController = QuotaRecoveryToastController(anchorView: button)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?)
    {
        if keyPath == "effectiveAppearance" {
            Task { @MainActor [weak self] in self?.render() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func observeChanges() {
        Publishers.CombineLatest4(
            settings.$selectedProviderInstanceID,
            settings.$metric,
            settings.$registeredProviders,
            coordinator.$snapshots)
            .combineLatest(coordinator.$errors)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePopoverSize()
                self?.render()
            }
            .store(in: &cancellables)

        settings.$registeredProviders
            .receive(on: RunLoop.main)
            .sink { [weak self] instances in
                self?.openCodeRecoveryMonitor?.sync(instances: instances)
            }
            .store(in: &cancellables)

        coordinator.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots in
                guard let self else { return }
                let events = self.recoveryDetector.observe(
                    snapshots: snapshots,
                    instanceLookup: { [weak self] id in self?.coordinator.instance(id) })
                for event in events {
                    self.recoveryToastController?.enqueue(
                        title: event.accountTitle,
                        message: event.message)
                }
            }
            .store(in: &cancellables)

        layoutMetrics.$providerListHeight
            .removeDuplicates { abs($0 - $1) < 0.5 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePopoverSize() }
            .store(in: &cancellables)
    }

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        updatePopoverSize()
        popover.show(
            relativeTo: Self.popoverAnchorRect(buttonBounds: button.bounds),
            of: button,
            preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { @MainActor [weak self] in
            await self?.coordinator.refreshIfStale(olderThan: 60)
        }
    }

    private func updatePopoverSize() {
        let screenHeight = statusItem.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 900
        popover.contentSize = NSSize(
            width: 430,
            height: Self.preferredPopoverHeight(
                providerCount: settings.registeredProviders.count,
                measuredProviderListHeight: layoutMetrics.providerListHeight,
                screenHeight: screenHeight))
    }

    nonisolated static func preferredPopoverHeight(
        providerCount: Int,
        measuredProviderListHeight: CGFloat,
        screenHeight: CGFloat
    ) -> CGFloat {
        let safeScreenHeight = max(320, screenHeight - 24)
        if providerCount <= 0 { return min(280, safeScreenHeight) }
        let chromeHeight: CGFloat = 118
        let fallbackCardHeight: CGFloat = 330
        let providerListHeight = measuredProviderListHeight > 0
            ? measuredProviderListHeight
            : CGFloat(providerCount) * fallbackCardHeight
        let naturalHeight = chromeHeight + providerListHeight
        return min(max(320, naturalHeight), safeScreenHeight)
    }

    nonisolated static func popoverAnchorRect(buttonBounds: CGRect) -> CGRect {
        CGRect(
            x: buttonBounds.maxX - 1,
            y: buttonBounds.minY,
            width: 1,
            height: buttonBounds.height)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        defer {
            if popover.isShown {
                popover.positioningRect = Self.popoverAnchorRect(buttonBounds: button.bounds)
            }
        }
        guard let instance = settings.selectedProvider else {
            let image = renderEmptyImage()
            statusItem.length = image.size.width + 8
            button.image = image
            button.toolTip = "AIUsage: no provider accounts added\nClick: add an account"
            button.setAccessibilityLabel("AIUsage, no provider accounts added. Click to add an account")
            return
        }

        let snapshot = coordinator.snapshots[instance.id]
        let hasError = coordinator.errors[instance.id] != nil
        let title = displayTitle(instance: instance, snapshot: snapshot, hasError: hasError)
        let image = renderImage(title: title, snapshot: snapshot, provider: instance.provider, hasError: hasError)
        statusItem.length = image.size.width + 8
        button.image = image
        let tooltip = accessibilityText(instance: instance, snapshot: snapshot, hasError: hasError)
        button.toolTip = tooltip + "\nClick: show details"
        button.setAccessibilityLabel("AIUsage, \(tooltip)")
    }

    private func displayTitle(instance: ProviderInstance, snapshot: ProviderSnapshot?, hasError: Bool) -> String {
        let base = snapshot.map { MenuBarPresentation.title(snapshot: $0, metric: settings.metric) }
            ?? "\(instance.provider.shortName) --"
        return hasError ? base + " !" : base
    }

    private func accessibilityText(instance: ProviderInstance, snapshot: ProviderSnapshot?, hasError: Bool) -> String {
        guard let snapshot else {
            return "\(instance.title): \(hasError ? "needs attention" : "loading")"
        }
        let values = snapshot.windows.map { window in
            let value = MenuBarPresentation.value(window, metric: settings.metric)
            let metric = settings.metric == .remaining ? "remaining" : "used"
            return "\(window.label) \(PercentFormatter.string(value)) percent \(metric)"
        }.joined(separator: ", ")
        return "\(instance.title): \(values)\(hasError ? ", showing stale data" : "")"
    }

    private func renderEmptyImage() -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let attributed = NSAttributedString(string: "AI +", attributes: attributes)
        let size = attributed.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            attributed.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
    }

    private func renderImage(
        title: String,
        snapshot: ProviderSnapshot?,
        provider: ProviderID,
        hasError: Bool) -> NSImage
    {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let prefix = provider.shortName
        let suffix = String(title.dropFirst(prefix.count))
        let prefixAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: brandColor(provider),
        ]
        let valueColor: NSColor = hasError
            ? .systemOrange
            : snapshot == nil ? .secondaryLabelColor : severityColor(snapshot?.mostConstrainedRemaining)
        let suffixAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: valueColor]
        let attributed = NSMutableAttributedString(string: prefix, attributes: prefixAttributes)
        attributed.append(NSAttributedString(string: suffix, attributes: suffixAttributes))
        let size = attributed.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            attributed.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
    }

    private func severityColor(_ remaining: Double?) -> NSColor {
        guard let remaining else { return .secondaryLabelColor }
        return ProviderVisuals.severityRGB(UsageSeverity(remainingPercent: remaining)).nsColor
    }

    private func brandColor(_ provider: ProviderID) -> NSColor {
        ProviderVisuals.accentRGB(provider).nsColor
    }
}
