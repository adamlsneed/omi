import XCTest

@testable import Omi_Computer

final class AppDetailSummaryPreferenceActionTests: XCTestCase {
    func testInstalledSummaryAppCanBeSetAsDefault() throws {
        let action = try XCTUnwrap(AppDetailSummaryPreferenceAction.resolve(
            appId: "summary-app",
            preferredAppId: "",
            isInstalled: true,
            worksWithMemories: true
        ))

        XCTAssertEqual(action.kind, .setDefault)
        XCTAssertEqual(action.label, "Set as default summary app")
        XCTAssertTrue(action.isInteractive)
    }

    func testCurrentDefaultSummaryAppIsNotInteractive() throws {
        let action = try XCTUnwrap(AppDetailSummaryPreferenceAction.resolve(
            appId: "summary-app",
            preferredAppId: "summary-app",
            isInstalled: true,
            worksWithMemories: true
        ))

        XCTAssertEqual(action.kind, .currentDefault)
        XCTAssertEqual(action.label, "Default summary app")
        XCTAssertFalse(action.isInteractive)
    }

    func testUninstalledSummaryAppCannotBeSetAsDefault() throws {
        let action = try XCTUnwrap(AppDetailSummaryPreferenceAction.resolve(
            appId: "summary-app",
            preferredAppId: "",
            isInstalled: false,
            worksWithMemories: true
        ))

        XCTAssertEqual(action.kind, .installRequired)
        XCTAssertEqual(action.label, "Install to set default")
        XCTAssertFalse(action.isInteractive)
    }

    func testNonSummaryAppDoesNotShowSummaryDefaultAction() {
        XCTAssertNil(AppDetailSummaryPreferenceAction.resolve(
            appId: "chat-app",
            preferredAppId: "",
            isInstalled: true,
            worksWithMemories: false
        ))
    }
}
