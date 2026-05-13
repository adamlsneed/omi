import XCTest

@testable import Omi_Computer

final class AppDetailPrimaryActionStateTests: XCTestCase {
    func testEnabledNonExternalAppPrimaryActionDoesNotDisableApp() {
        let state = AppDetailPrimaryActionState(isEnabled: true, worksExternally: false)

        XCTAssertEqual(state.title, "Installed")
        XCTAssertEqual(state.action, .none)
        XCTAssertTrue(state.isDisabled)
    }

    func testEnabledExternalAppPrimaryActionOpensExternalDestination() {
        let state = AppDetailPrimaryActionState(isEnabled: true, worksExternally: true)

        XCTAssertEqual(state.title, "Open")
        XCTAssertEqual(state.action, .openExternal)
        XCTAssertFalse(state.isDisabled)
    }

    func testEnabledExternalAppWithoutTargetDoesNotShowNoOpOpenAction() {
        let state = AppDetailPrimaryActionState(
            isEnabled: true,
            worksExternally: true,
            externalOpenTargetAvailable: false
        )

        XCTAssertEqual(state.title, "Installed")
        XCTAssertEqual(state.action, .none)
        XCTAssertTrue(state.isDisabled)
    }

    func testDisabledAppPrimaryActionInstallsApp() {
        let state = AppDetailPrimaryActionState(isEnabled: false, worksExternally: false)

        XCTAssertEqual(state.title, "Install")
        XCTAssertEqual(state.action, .install)
        XCTAssertFalse(state.isDisabled)
    }

    func testOnlyOwnerCanManageApp() {
        XCTAssertTrue(AppDetailOwnershipPolicy.canManage(appOwnerId: "user-1", currentUserId: "user-1"))
        XCTAssertFalse(AppDetailOwnershipPolicy.canManage(appOwnerId: "user-1", currentUserId: "user-2"))
        XCTAssertFalse(AppDetailOwnershipPolicy.canManage(appOwnerId: nil, currentUserId: "user-1"))
        XCTAssertFalse(AppDetailOwnershipPolicy.canManage(appOwnerId: "user-1", currentUserId: nil))
    }
}
