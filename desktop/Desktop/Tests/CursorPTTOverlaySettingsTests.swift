import XCTest
@testable import Omi_Computer

@MainActor
final class CursorPTTOverlaySettingsTests: XCTestCase {

    func testCursorIdleDotDefaultIsOff() {
        XCTAssertFalse(ShortcutSettings.cursorIdleDotDefault)
    }

    func testCursorIdleDotSettingPersistsToUserDefaults() {
        let settings = ShortcutSettings.shared
        let key = ShortcutSettings.cursorIdleDotDefaultsKey
        let originalSetting = settings.cursorIdleDotEnabled
        let originalStoredValue = UserDefaults.standard.object(forKey: key)

        defer {
            settings.cursorIdleDotEnabled = originalSetting
            if let originalStoredValue {
                UserDefaults.standard.set(originalStoredValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)

        settings.cursorIdleDotEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        settings.cursorIdleDotEnabled = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    func testIdleDotDecisionRequiresCursorSettingFloatingBarAndNoSnooze() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            CursorPTTOverlayManager.shouldShowIdleDot(
                cursorIdleDotEnabled: false,
                floatingBarEnabled: true,
                snoozedUntil: nil,
                now: now
            )
        )
        XCTAssertFalse(
            CursorPTTOverlayManager.shouldShowIdleDot(
                cursorIdleDotEnabled: true,
                floatingBarEnabled: false,
                snoozedUntil: nil,
                now: now
            )
        )
        XCTAssertFalse(
            CursorPTTOverlayManager.shouldShowIdleDot(
                cursorIdleDotEnabled: true,
                floatingBarEnabled: true,
                snoozedUntil: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowIdleDot(
                cursorIdleDotEnabled: true,
                floatingBarEnabled: true,
                snoozedUntil: now.addingTimeInterval(-60),
                now: now
            )
        )
        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowIdleDot(
                cursorIdleDotEnabled: true,
                floatingBarEnabled: true,
                snoozedUntil: nil,
                now: now
            )
        )
    }

    func testActiveOverlayPhasesRemainVisibleWhenIdleDotIsDisabled() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .listening,
                cursorIdleDotEnabled: false,
                floatingBarEnabled: false,
                snoozedUntil: nil,
                now: now
            )
        )
        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .processing,
                cursorIdleDotEnabled: false,
                floatingBarEnabled: false,
                snoozedUntil: nil,
                now: now
            )
        )
        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .responding,
                cursorIdleDotEnabled: false,
                floatingBarEnabled: false,
                snoozedUntil: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .notifying,
                cursorIdleDotEnabled: false,
                floatingBarEnabled: false,
                snoozedUntil: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertTrue(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .executing,
                cursorIdleDotEnabled: false,
                floatingBarEnabled: false,
                snoozedUntil: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertFalse(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .idle,
                cursorIdleDotEnabled: false,
                floatingBarEnabled: true,
                snoozedUntil: nil,
                now: now
            )
        )
        XCTAssertFalse(
            CursorPTTOverlayManager.shouldShowOverlayPhase(
                .hidden,
                cursorIdleDotEnabled: true,
                floatingBarEnabled: true,
                snoozedUntil: nil,
                now: now
            )
        )
    }
}
