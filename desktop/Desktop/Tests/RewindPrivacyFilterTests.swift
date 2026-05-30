import XCTest

@testable import Omi_Computer

final class RewindPrivacyFilterTests: XCTestCase {
  func testScopedWindowPatternMatchesOnlySpecifiedAppAndTitle() {
    XCTAssertTrue(RewindPrivacyFilter.shouldExclude(
      appName: "Google Chrome",
      windowTitle: "Bank - Checking",
      excludedApps: [],
      excludedWindowPatterns: ["Google Chrome::*Bank*"],
      suppressPrivateBrowsing: false
    ))

    XCTAssertFalse(RewindPrivacyFilter.shouldExclude(
      appName: "Safari",
      windowTitle: "Bank - Checking",
      excludedApps: [],
      excludedWindowPatterns: ["Google Chrome::*Bank*"],
      suppressPrivateBrowsing: false
    ))
  }

  func testPlainWindowPatternMatchesWindowTitleWithoutExcludingWholeApp() {
    XCTAssertTrue(RewindPrivacyFilter.shouldExclude(
      appName: "Notes",
      windowTitle: "Q2 payroll planning",
      excludedApps: [],
      excludedWindowPatterns: ["*payroll*"],
      suppressPrivateBrowsing: false
    ))

    XCTAssertFalse(RewindPrivacyFilter.shouldExclude(
      appName: "Notes",
      windowTitle: "Project notes",
      excludedApps: [],
      excludedWindowPatterns: ["*payroll*"],
      suppressPrivateBrowsing: false
    ))
  }

  func testPrivateBrowsingWindowsCanBeSuppressedConservatively() {
    XCTAssertTrue(RewindPrivacyFilter.shouldExclude(
      appName: "Google Chrome",
      windowTitle: "New Incognito Tab",
      excludedApps: [],
      excludedWindowPatterns: [],
      suppressPrivateBrowsing: true
    ))

    XCTAssertTrue(RewindPrivacyFilter.shouldExclude(
      appName: "Safari",
      windowTitle: "Private Browsing",
      excludedApps: [],
      excludedWindowPatterns: [],
      suppressPrivateBrowsing: true
    ))

    XCTAssertFalse(RewindPrivacyFilter.shouldExclude(
      appName: "Safari",
      windowTitle: "Private equity research",
      excludedApps: [],
      excludedWindowPatterns: [],
      suppressPrivateBrowsing: true
    ))
  }
}
