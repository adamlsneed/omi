import AppKit
import XCTest
@testable import Omi_Computer

final class DockIconVisibilitySettingsTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "DockIconVisibilitySettingsTests")
    defaults.removePersistentDomain(forName: "DockIconVisibilitySettingsTests")
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: "DockIconVisibilitySettingsTests")
    defaults = nil
    super.tearDown()
  }

  func testDefaultsToShowingDockIcon() {
    let settings = DockIconVisibilitySettings(defaults: defaults)

    XCTAssertFalse(settings.hidesDockIcon)
  }

  func testPersistsHiddenDockIconPreference() {
    var settings = DockIconVisibilitySettings(defaults: defaults)

    settings.hidesDockIcon = true

    XCTAssertTrue(defaults.bool(forKey: DockIconVisibilitySettings.hideDockIconKey))
    XCTAssertTrue(DockIconVisibilitySettings(defaults: defaults).hidesDockIcon)
  }

  func testActivationPolicyMatchesPreference() {
    XCTAssertEqual(DockIconVisibilitySettings.activationPolicy(hidesDockIcon: false), .regular)
    XCTAssertEqual(DockIconVisibilitySettings.activationPolicy(hidesDockIcon: true), .accessory)
  }

  func testSettingsSearchIncludesDockIconSetting() {
    let item = SettingsSearchItem.allSearchableItems.first { $0.settingId == "general.dockicon" }

    XCTAssertEqual(item?.name, "Dock Icon")
    XCTAssertEqual(item?.section, .general)
  }
}
