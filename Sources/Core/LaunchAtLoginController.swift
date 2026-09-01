import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginService: AnyObject {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginService

    init(service: any LaunchAtLoginService = MainAppLaunchAtLoginService()) {
        self.service = service
        isEnabled = service.isEnabled
    }

    func refresh() {
        isEnabled = service.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}

@MainActor
private final class MainAppLaunchAtLoginService: LaunchAtLoginService {
    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        service.status == .enabled || service.status == .requiresApproval
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
