import XCTest
@testable import Omi_Computer

final class AppDetailActionPolicyTests: XCTestCase {
    func testInstalledNonExternalAppPrimaryActionIsNotDestructive() {
        let action = AppDetailPrimaryAction.resolve(isInstalled: true, worksExternally: false)

        XCTAssertEqual(action.kind, .installed)
        XCTAssertEqual(action.label, "Installed")
        XCTAssertFalse(action.mutatesInstallation)
        XCTAssertFalse(action.isInteractive)
    }

    func testUninstalledAppPrimaryActionInstalls() {
        let action = AppDetailPrimaryAction.resolve(isInstalled: false, worksExternally: false)

        XCTAssertEqual(action.kind, .install)
        XCTAssertEqual(action.label, "Install")
        XCTAssertTrue(action.mutatesInstallation)
        XCTAssertTrue(action.isInteractive)
    }

    func testInstalledExternalAppPrimaryActionOpensExternalApp() {
        let action = AppDetailPrimaryAction.resolve(isInstalled: true, worksExternally: true)

        XCTAssertEqual(action.kind, .openExternal)
        XCTAssertEqual(action.label, "Open")
        XCTAssertFalse(action.mutatesInstallation)
        XCTAssertTrue(action.isInteractive)
    }

    func testOnlyOwnerCanManageApp() {
        XCTAssertTrue(AppDetailOwnershipPolicy.canManage(appOwnerId: "user-1", currentUserId: "user-1"))
        XCTAssertFalse(AppDetailOwnershipPolicy.canManage(appOwnerId: "user-1", currentUserId: "user-2"))
        XCTAssertFalse(AppDetailOwnershipPolicy.canManage(appOwnerId: nil, currentUserId: "user-1"))
        XCTAssertFalse(AppDetailOwnershipPolicy.canManage(appOwnerId: "user-1", currentUserId: nil))
    }
}
