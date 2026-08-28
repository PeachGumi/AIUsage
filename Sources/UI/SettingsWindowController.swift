import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: SettingsStore) {
        let content = SettingsView(settings: settings)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "AIUsage Settings"
        window.contentView = hosting
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Menu Bar") {
                if settings.registeredProviders.isEmpty {
                    LabeledContent("Displayed account", value: "No provider accounts added")
                } else {
                    Picker("Displayed account", selection: $settings.selectedProviderInstanceID) {
                        ForEach(settings.registeredProviders) { instance in
                            Text(instance.title).tag(Optional(instance.id))
                        }
                    }
                }
                Picker("Displayed value", selection: $settings.metric) {
                    Text("Remaining").tag(UsageMetric.remaining)
                    Text("Used").tag(UsageMetric.used)
                }
            }
            Section("Updates") {
                LabeledContent("Refresh interval", value: "5 minutes")
                Text("Every account card is refreshed independently, including multiple accounts of the same provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 430, height: 280)
    }
}
