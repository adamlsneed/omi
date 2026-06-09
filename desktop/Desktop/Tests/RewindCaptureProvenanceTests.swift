import XCTest

@testable import Omi_Computer

final class RewindCaptureProvenanceTests: XCTestCase {
  func testScreenshotDefaultsCaptureProvenanceForLegacyCallers() {
    let screenshot = Screenshot(appName: "Notes")

    XCTAssertEqual(screenshot.captureTrigger, CaptureTrigger.timer.rawValue)
    XCTAssertEqual(screenshot.textSource, CapturedTextSource.none.rawValue)
    XCTAssertNil(screenshot.accessibilityText)
  }

  func testScreenshotPreservesExplicitCaptureProvenance() {
    let screenshot = Screenshot(
      appName: "Google Chrome",
      captureTrigger: CaptureTrigger.contextSwitch.rawValue,
      textSource: CapturedTextSource.accessibility.rawValue,
      accessibilityText: "A11y text"
    )

    XCTAssertEqual(screenshot.captureTrigger, "context_switch")
    XCTAssertEqual(screenshot.textSource, "accessibility")
    XCTAssertEqual(screenshot.accessibilityText, "A11y text")
  }

}
