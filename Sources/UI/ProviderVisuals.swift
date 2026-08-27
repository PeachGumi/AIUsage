import SwiftUI

enum ProviderVisuals {
    static func accent(_ provider: ProviderID) -> Color {
        switch provider {
        case .openCodeGo: Color(red: 0.05, green: 0.62, blue: 0.66)
        case .qwen: Color(red: 0.48, green: 0.32, blue: 0.88)
        case .codex: Color(red: 0.31, green: 0.36, blue: 0.82)
        }
    }

    static func severity(_ severity: UsageSeverity) -> Color {
        switch severity {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
