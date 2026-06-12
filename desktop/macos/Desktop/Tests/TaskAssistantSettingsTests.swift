import XCTest

@testable import Omi_Computer

@MainActor
final class TaskAssistantSettingsTests: XCTestCase {
  private let autoPromoteKey = "taskAutoPromoteEnabled"

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: autoPromoteKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: autoPromoteKey)
    super.tearDown()
  }

  func testAutoPromoteDefaultsToEnabledForExistingBehavior() {
    XCTAssertTrue(TaskAssistantSettings.shared.autoPromoteEnabled)
  }

  func testAutoPromoteCanBeDisabledAndReenabled() {
    TaskAssistantSettings.shared.autoPromoteEnabled = false
    XCTAssertFalse(TaskAssistantSettings.shared.autoPromoteEnabled)

    TaskAssistantSettings.shared.autoPromoteEnabled = true
    XCTAssertTrue(TaskAssistantSettings.shared.autoPromoteEnabled)
  }
}
