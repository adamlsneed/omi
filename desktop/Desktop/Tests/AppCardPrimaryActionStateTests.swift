import XCTest

@testable import Omi_Computer

final class AppCardPrimaryActionStateTests: XCTestCase {
    func testDisabledAppCardInstallsApp() {
        let state = AppCardPrimaryActionState(isEnabled: false)

        XCTAssertEqual(state.title, "Install")
        XCTAssertEqual(state.action, .install)
    }

    func testDisabledExternalAppCardOpensSetupAwareSettings() {
        let state = AppCardPrimaryActionState(isEnabled: false, worksExternally: true)

        XCTAssertEqual(state.title, "Setup")
        XCTAssertEqual(state.action, .openSettings)
    }

    func testEnabledAppCardOpensSettingsInsteadOfTogglingInstallState() {
        let state = AppCardPrimaryActionState(isEnabled: true)

        XCTAssertEqual(state.title, "Settings")
        XCTAssertEqual(state.action, .openSettings)
    }
}
