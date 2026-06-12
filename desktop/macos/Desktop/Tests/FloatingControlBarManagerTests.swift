import XCTest

@testable import Omi_Computer

/// Guards the persistence contract of the floating bar enable preference:
/// only explicit user actions (show/hide) may write it; transient reveals
/// and hides for PTT, notifications, and onboarding must leave it alone.
@MainActor
final class FloatingControlBarManagerTests: XCTestCase {
    private let enabledKey = "askOmiBarEnabled"
    private var savedValue: Any?

    override func setUp() async throws {
        savedValue = UserDefaults.standard.object(forKey: enabledKey)
    }

    override func tearDown() async throws {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: enabledKey)
        }
    }

    func testShowForVoiceSessionDoesNotPersistEnablePreference() {
        let manager = FloatingControlBarManager.shared
        manager.isEnabled = false
        manager.showForVoiceSession()
        XCTAssertFalse(manager.isEnabled, "PTT reveal must not turn the bar preference back on")
    }

    func testHideTemporarilyDoesNotPersistEnablePreference() {
        let manager = FloatingControlBarManager.shared
        manager.isEnabled = true
        manager.hideTemporarily()
        XCTAssertTrue(manager.isEnabled, "Transient hide must not turn the bar preference off")
    }

    func testShowAndHidePersistEnablePreference() {
        let manager = FloatingControlBarManager.shared
        manager.isEnabled = false
        manager.show()
        XCTAssertTrue(manager.isEnabled)
        manager.hide()
        XCTAssertFalse(manager.isEnabled)
    }

    func testIsEnabledDefaultsToTrueWhenNeverSet() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        XCTAssertTrue(FloatingControlBarManager.shared.isEnabled)
    }
}
