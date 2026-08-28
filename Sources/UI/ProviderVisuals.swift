import SwiftUI

enum ProviderVisuals {
    static func accent(_ provider: ProviderID) -> Color {
        switch provider {
        case .openCodeGo: Color(red: 0.05, green: 0.62, blue: 0.66)
        case .qwen: Color(red: 0.48, green: 0.32, blue: 0.88)
        case .codex: Color(red: 0.31, green: 0.36, blue: 0.82)
        case .claude: Color(red: 0.70, green: 0.39, blue: 0.25)
        case .antigravity: Color(red: 0.18, green: 0.48, blue: 0.86)
        case .copilot: Color(red: 0.39, green: 0.30, blue: 0.70)
        case .cursor: Color(red: 0.26, green: 0.26, blue: 0.29)
        case .zai: Color(red: 0.08, green: 0.55, blue: 0.42)
        case .kimi: Color(red: 0.78, green: 0.32, blue: 0.58)
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
