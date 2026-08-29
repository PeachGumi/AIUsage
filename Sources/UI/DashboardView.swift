import SwiftUI

enum ProviderDragLayout {
    static func nextIndex(
        draggedCenterY: CGFloat,
        currentIndex: Int,
        slots: [CGRect],
        hysteresis: CGFloat
    ) -> Int {
        guard slots.indices.contains(currentIndex) else { return currentIndex }
        if currentIndex + 1 < slots.count {
            let lowerBoundary = (slots[currentIndex].midY + slots[currentIndex + 1].midY) / 2
            if draggedCenterY > lowerBoundary + hysteresis { return currentIndex + 1 }
        }
        if currentIndex > 0 {
            let upperBoundary = (slots[currentIndex - 1].midY + slots[currentIndex].midY) / 2
            if draggedCenterY < upperBoundary - hysteresis { return currentIndex - 1 }
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
    let removeProvider: (UUID) -> Void
    let renameProvider: (UUID) -> Void
    let refreshAll: () -> Void
    let refresh: (UUID) -> Void
    let login: (UUID) -> Void
    let logout: (UUID) -> Void
    let openDashboard: (UUID) -> Void
    let showSettings: () -> Void
    let quit: () -> Void
}

private struct ProviderDragState {
    let instanceID: UUID
    let startFrame: CGRect
    let slots: [CGRect]
    var currentIndex: Int
    var translation: CGSize = .zero
    var dropTarget: UUID?
}

struct DashboardView: View {
    @ObservedObject var coordinator: UsageCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var layoutMetrics: PopoverLayoutMetrics
    let actions: AppActions

    @State private var dragState: ProviderDragState?
    @State private var cardFrames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if settings.registeredProviders.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    providerList
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProviderListHeightKey.self,
                                    value: proxy.size.height)
                            }
                        )
                }
                .scrollIndicators(.automatic)
                .onPreferenceChange(ProviderListHeightKey.self) { height in
                    Task { @MainActor in layoutMetrics.providerListHeight = height }
                }
            }
            footer
        }
        .frame(width: 430)
        .background(.ultraThinMaterial)
    }

    private var providerList: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 12) {
                ForEach(settings.registeredProviders) { instance in
                    providerCard(instance, floating: false)
                        .opacity(dragState?.instanceID == instance.id ? 0.12 : 1)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProviderCardFrameKey.self,
                                    value: [instance.id: proxy.frame(in: .named("provider-list"))])
                            }
                        )
                }
            }

            if let dragState,
               let instance = settings.instance(dragState.instanceID) {
                providerCard(instance, floating: true)
                    .frame(width: dragState.startFrame.width, height: dragState.startFrame.height)
                    .position(
                        x: dragState.startFrame.midX,
                        y: dragState.startFrame.midY + dragState.translation.height)
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

    private func providerCard(_ instance: ProviderInstance, floating: Bool) -> some View {
        ProviderCard(
            instance: instance,
            snapshot: coordinator.snapshots[instance.id],
            error: coordinator.errors[instance.id],
            refreshing: coordinator.refreshing.contains(instance.id),
            authenticationState: coordinator.authenticationStates[instance.id] ?? .unknown,
            metric: settings.metric,
            isSelected: settings.selectedProviderInstanceID == instance.id,
            showsReorderHandle: settings.registeredProviders.count > 1,
            isDropTarget: dragState?.dropTarget == instance.id,
            isFloating: floating,
            actions: actions,
            select: { settings.selectedProviderInstanceID = instance.id },
            dragChanged: { value in handleDragChanged(instanceID: instance.id, value: value) },
            dragEnded: handleDragEnded)
    }

    private func handleDragChanged(instanceID: UUID, value: DragGesture.Value) {
        if dragState == nil {
            let order = settings.registeredProviders
            let slots = order.compactMap { cardFrames[$0.id] }
            guard slots.count == order.count,
                  let index = order.firstIndex(where: { $0.id == instanceID }),
                  let startFrame = cardFrames[instanceID] else { return }
            dragState = ProviderDragState(
                instanceID: instanceID,
                startFrame: startFrame,
                slots: slots,
                currentIndex: index)
        }

        guard var state = dragState else { return }
        state.translation = ProviderDragLayout.verticalTranslation(value.translation)
        let nextIndex = ProviderDragLayout.nextIndex(
            draggedCenterY: state.startFrame.midY + state.translation.height,
            currentIndex: state.currentIndex,
            slots: state.slots,
            hysteresis: 6)

        guard nextIndex != state.currentIndex,
              settings.registeredProviders.indices.contains(nextIndex) else {
            state.dropTarget = nil
            dragState = state
            return
        }

        let target = settings.registeredProviders[nextIndex].id
        state.currentIndex = nextIndex
        state.dropTarget = target
        dragState = state
        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88)) {
            settings.moveProvider(instanceID, onto: target)
        }
    }

    private func handleDragEnded() {
        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88)) {
            dragState = nil
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage").font(.headline)
                Text(settings.registeredProviders.isEmpty
                     ? "Add a provider to get started"
                     : "Each card is an independent account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            addProviderMenu
            Button(action: actions.refreshAll) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(settings.registeredProviders.isEmpty)
                .help("Refresh registered accounts")
                .accessibilityLabel("Refresh registered accounts")
        }
        .padding(14)
    }

    private var addProviderMenu: some View {
        Menu {
            ForEach(settings.addableProviders) { provider in
                Button(provider.isExperimental
                       ? "\(provider.displayName) — Experimental"
                       : provider.displayName) {
                    actions.addProvider(provider)
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add another provider account")
        .accessibilityLabel("Add provider account")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No provider accounts added")
                .font(.headline)
            Text("Use the + button above to add an account.\nProviders with isolated credentials can be added more than once.")
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
            Button("Quit", action: actions.quit).buttonStyle(.borderless)
        }
        .padding(12)
    }
}

private struct ProviderListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProviderCardFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ProviderCard: View {
    let instance: ProviderInstance
    let snapshot: ProviderSnapshot?
    let error: String?
    let refreshing: Bool
    let authenticationState: ProviderAuthenticationState
    let metric: UsageMetric
    let isSelected: Bool
    let showsReorderHandle: Bool
    let isDropTarget: Bool
    let isFloating: Bool
    let actions: AppActions
    let select: () -> Void
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: () -> Void

    private var provider: ProviderID { instance.provider }

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
        .accessibilityHint("Sets this account as the menu bar display")
        .accessibilityAction(named: "Pin to menu bar", select)
        .onTapGesture(perform: select)
    }

    private var accessibilitySummary: String {
        let status: String
        if authenticationState == .required { status = "sign in required" }
        else if error != nil { status = "needs attention" }
        else if snapshot == nil { status = "loading" }
        else { status = "available" }
        let experimental = provider.isExperimental ? ", experimental integration" : ""
        return "\(instance.title), \(status)\(experimental)\(isSelected ? ", shown in menu bar" : "")"
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
                        .accessibilityLabel("Drag \(instance.title) to reorder")
                }
            }
            Text(provider.shortName)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 24)
                .background(ProviderVisuals.accent(provider), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    if let label = instance.accountLabel {
                        Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    if provider.isExperimental {
                        Label("Experimental", systemImage: "flask")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if let plan = snapshot?.planName {
                        Text(plan).font(.caption2).foregroundStyle(.secondary)
                    }
                }
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

    @ViewBuilder
    private var authenticationAction: some View {
        switch provider.accountAction {
        case .apiKey:
            Button("API key…") { actions.login(instance.id) }.buttonStyle(.link)
        case .account:
            Button("Account…") { actions.login(instance.id) }.buttonStyle(.link)
        case .signInOut:
            switch authenticationState {
            case .authenticated:
                Button("Sign out") { actions.logout(instance.id) }.buttonStyle(.link)
            case .required:
                Button("Sign in") { actions.login(instance.id) }.buttonStyle(.link)
            case .unknown:
                Button(snapshot != nil ? "Sign out" : "Sign in") {
                    snapshot != nil ? actions.logout(instance.id) : actions.login(instance.id)
                }.buttonStyle(.link)
            }
        }
    }

    private var cardActions: some View {
        HStack(spacing: 12) {
            Button("Refresh") { actions.refresh(instance.id) }.buttonStyle(.link)
            authenticationAction
            Button("Rename…") { actions.renameProvider(instance.id) }.buttonStyle(.link)
            Spacer()
            Button("Open dashboard") { actions.openDashboard(instance.id) }.buttonStyle(.link)
            Button("Remove") { actions.removeProvider(instance.id) }
                .buttonStyle(.link)
                .foregroundStyle(.red)
                .help("Remove this account and its AIUsage-owned account data")
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
