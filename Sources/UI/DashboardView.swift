import SwiftUI

enum ProviderDragLayout {
    static func nextIndex(
        pointerY: CGFloat,
        currentIndex: Int,
        slots: [CGRect],
        hysteresis: CGFloat
    ) -> Int {
        guard slots.indices.contains(currentIndex) else { return currentIndex }
        if currentIndex + 1 < slots.count,
           pointerY > slots[currentIndex + 1].midY + hysteresis {
            return currentIndex + 1
        }
        if currentIndex > 0,
           pointerY < slots[currentIndex - 1].midY - hysteresis {
            return currentIndex - 1
        }
        return currentIndex
    }

    static func verticalTranslation(_ translation: CGSize) -> CGSize {
        CGSize(width: 0, height: translation.height)
    }
}

@MainActor
struct AppActions {
    let addProvider: (ProviderID) -> Void
    let removeProvider: (ProviderID) -> Void
    let refreshAll: () -> Void
    let refresh: (ProviderID) -> Void
    let login: (ProviderID) -> Void
    let logout: (ProviderID) -> Void
    let openDashboard: (ProviderID) -> Void
    let showSettings: () -> Void
    let quit: () -> Void
}

/// Main popover content. Supported providers are a catalog; only providers the
/// user explicitly adds are shown, refreshed, and eligible for menu-bar pinning.
struct DashboardView: View {
    @ObservedObject var coordinator: UsageCoordinator
    @ObservedObject var settings: SettingsStore
    let actions: AppActions
    @State private var draggedProvider: ProviderID?
    @State private var hoveredProvider: ProviderID?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartFrame: CGRect?
    @State private var dragSlotFrames: [CGRect] = []
    @State private var dragCurrentIndex: Int?
    @State private var cardFrames: [ProviderID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if settings.registeredProviders.isEmpty {
                emptyState
            } else {
                providerList
            }
            footer
        }
        .frame(width: 430)
        .background(.ultraThinMaterial)
    }

    private var providerList: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 12) {
                ForEach(settings.registeredProviders, id: \.self) { provider in
                    providerCard(provider, floating: false)
                        .opacity(draggedProvider == provider ? 0.12 : 1)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProviderCardFrameKey.self,
                                    value: [provider: proxy.frame(in: .named("provider-list"))])
                            }
                        )
                }
            }

            if let provider = draggedProvider, let start = dragStartFrame {
                providerCard(provider, floating: true)
                    .frame(width: start.width, height: start.height)
                    .position(
                        x: start.midX,
                        y: start.midY + dragTranslation.height)
                    .scaleEffect(1.025)
                    .shadow(color: .black.opacity(0.30), radius: 14, y: 8)
                    .zIndex(100)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "provider-list")
        .onPreferenceChange(ProviderCardFrameKey.self) { frames in
            Task { @MainActor in cardFrames = frames }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func providerCard(_ provider: ProviderID, floating: Bool) -> some View {
        ProviderCard(
            provider: provider,
            snapshot: coordinator.snapshots[provider],
            error: coordinator.errors[provider],
            refreshing: coordinator.refreshing.contains(provider),
            metric: settings.metric,
            isSelected: settings.selectedProvider == provider,
            showsReorderHandle: settings.registeredProviders.count > 1,
            isDropTarget: hoveredProvider == provider,
            isFloating: floating,
            actions: actions,
            select: { settings.selectedProvider = provider },
            dragChanged: { value in handleDragChanged(provider: provider, value: value) },
            dragEnded: { handleDragEnded() })
    }

    private func handleDragChanged(provider: ProviderID, value: DragGesture.Value) {
        if draggedProvider == nil {
            let order = settings.registeredProviders
            let slots = order.compactMap { cardFrames[$0] }
            guard slots.count == order.count,
                  let index = order.firstIndex(of: provider),
                  let startFrame = cardFrames[provider] else { return }
            draggedProvider = provider
            dragStartFrame = startFrame
            dragSlotFrames = slots
            dragCurrentIndex = index
        }
        dragTranslation = ProviderDragLayout.verticalTranslation(value.translation)

        guard let currentIndex = dragCurrentIndex else { return }
        let nextIndex = ProviderDragLayout.nextIndex(
            pointerY: value.location.y,
            currentIndex: currentIndex,
            slots: dragSlotFrames,
            hysteresis: 12)
        guard nextIndex != currentIndex,
              settings.registeredProviders.indices.contains(nextIndex) else {
            hoveredProvider = nil
            return
        }

        let target = settings.registeredProviders[nextIndex]
        hoveredProvider = target
        dragCurrentIndex = nextIndex
        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88)) {
            settings.moveProvider(provider, onto: target)
        }
    }

    private func handleDragEnded() {
        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88)) {
            draggedProvider = nil
            hoveredProvider = nil
            dragTranslation = .zero
            dragStartFrame = nil
            dragSlotFrames = []
            dragCurrentIndex = nil
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage").font(.headline)
                Text(settings.registeredProviders.isEmpty
                     ? "Add a provider to get started"
                     : "Click a card to pin it to the menu bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            addProviderMenu
            Button(action: actions.refreshAll) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(settings.registeredProviders.isEmpty)
            .help("Refresh registered providers")
            .accessibilityLabel("Refresh registered providers")
        }
        .padding(14)
    }

    private var addProviderMenu: some View {
        Menu {
            if settings.addableProviders.isEmpty {
                Button("All supported providers are added") {}
                    .disabled(true)
            } else {
                ForEach(settings.addableProviders) { provider in
                    Button(provider.displayName) {
                        actions.addProvider(provider)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add provider")
        .accessibilityLabel("Add provider")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No providers added")
                .font(.headline)
            Text("Use the + button above to choose a provider.\nAIUsage will only contact providers you add.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var footer: some View {
        HStack {
            Button("Settings", systemImage: "gearshape", action: actions.showSettings)
                .buttonStyle(.borderless)
            Spacer()
            if !settings.registeredProviders.isEmpty {
                Text("Drag cards to reorder").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            Button("Quit", action: actions.quit)
                .buttonStyle(.borderless)
        }
        .padding(12)
    }
}

private struct ProviderCardFrameKey: PreferenceKey {
    static let defaultValue: [ProviderID: CGRect] = [:]

    static func reduce(value: inout [ProviderID: CGRect], nextValue: () -> [ProviderID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ProviderCard: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let error: String?
    let refreshing: Bool
    let metric: UsageMetric
    let isSelected: Bool
    let showsReorderHandle: Bool
    let isDropTarget: Bool
    let isFloating: Bool
    let actions: AppActions
    let select: () -> Void
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: () -> Void

    var body: some View {
        card
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                isDropTarget ? Color.accentColor : isSelected ? ProviderVisuals.accent(provider).opacity(0.7) : Color.primary.opacity(0.08),
                lineWidth: isDropTarget || isSelected ? 1.5 : 1))
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardHeader
            if let snapshot {
                ForEach(snapshot.windows) { window in
                    UsageWindowRow(window: window, metric: metric)
                }
            } else if error == nil {
                placeholder
            }
            if let error { errorView(error) }
            if let fetchedAt = snapshot?.fetchedAt {
                HStack(spacing: 5) {
                    Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                    if error != nil { Text("· stale").foregroundStyle(.orange) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            cardActions
        }
        .padding(13)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Sets this provider as the menu bar display")
        .accessibilityAction(named: "Pin to menu bar", select)
        .onTapGesture(perform: select)
    }

    private var accessibilitySummary: String {
        let status = error != nil ? "needs attention" : snapshot == nil ? "loading" : "available"
        return "\(provider.displayName), \(status)\(isSelected ? ", shown in menu bar" : "")"
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            if showsReorderHandle {
                let handle = Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())

                if isFloating {
                    handle
                } else {
                    handle
                        .gesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .named("provider-list"))
                                .onChanged(dragChanged)
                                .onEnded { _ in dragEnded() })
                        .help("Drag to reorder")
                        .accessibilityLabel("Drag \(provider.displayName) to reorder")
                }
            }
            Text(provider.shortName)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 24)
                .background(ProviderVisuals.accent(provider), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName).font(.subheadline.weight(.semibold))
                if let plan = snapshot?.planName { Text(plan).font(.caption2).foregroundStyle(.secondary) }
            }
            if isSelected {
                Label("Menu bar", systemImage: "menubar.rectangle")
                    .font(.caption2)
                    .foregroundStyle(ProviderVisuals.accent(provider))
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            if refreshing { ProgressView().controlSize(.small) }
            statusDot
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(error == nil && snapshot != nil ? Color.green : error == nil ? Color.gray : Color.orange)
            .frame(width: 8, height: 8)
            .accessibilityLabel(error == nil && snapshot != nil ? "Available" : error == nil ? "Waiting" : "Needs attention")
    }

    private var placeholder: some View {
        Text(refreshing ? "Fetching usage…" : "No usage data yet")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardActions: some View {
        HStack(spacing: 14) {
            Button("Refresh") { actions.refresh(provider) }.buttonStyle(.link)
            if provider != .codex {
                if error == nil && snapshot != nil {
                    Button("Sign out") { actions.logout(provider) }.buttonStyle(.link)
                } else {
                    Button("Sign in") { actions.login(provider) }.buttonStyle(.link)
                }
            }
            Spacer()
            Button("Open dashboard") { actions.openDashboard(provider) }.buttonStyle(.link)
            Button("Remove") { actions.removeProvider(provider) }
                .buttonStyle(.link)
                .foregroundStyle(.red)
                .help("Remove from AIUsage without signing out")
        }
        .font(.caption)
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).font(.caption.weight(.medium))
                Spacer()
                Text(valueText).font(.system(.caption, design: .monospaced, weight: .semibold))
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(ProviderVisuals.severity(UsageSeverity(remainingPercent: window.remainingPercent)))
                .accessibilityLabel(window.label)
                .accessibilityValue("Remaining \(PercentFormatter.string(window.remainingPercent)) percent")
            if let resetText {
                Text(resetText).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var valueText: String {
        let value = MenuBarPresentation.value(window, metric: metric)
        let suffix = metric == .remaining ? "left" : "used"
        return "\(PercentFormatter.string(value))% \(suffix)"
    }

    private var resetText: String? {
        if let description = window.resetDescription { return description }
        guard let date = window.resetsAt else { return nil }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
