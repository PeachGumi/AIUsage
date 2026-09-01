import XCTest
@testable import AIUsage

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testEnablingRegistersServiceAndRefreshesState() {
        let service = FakeLaunchAtLoginService()
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisablingUnregistersServiceAndRefreshesState() {
        let service = FakeLaunchAtLoginService(isEnabled: true)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testRegistrationFailureKeepsActualStateAndExposesError() {
        let service = FakeLaunchAtLoginService(registerError: TestError.failed)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    var isEnabled: Bool
    var registerCallCount = 0
    var unregisterCallCount = 0
    var registerError: Error?

    init(isEnabled: Bool = false, registerError: Error? = nil) {
        self.isEnabled = isEnabled
        self.registerError = registerError
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        isEnabled = true
    }

    func unregister() throws {
        unregisterCallCount += 1
        isEnabled = false
    }
}

private enum TestError: Error {
    case failed
}
