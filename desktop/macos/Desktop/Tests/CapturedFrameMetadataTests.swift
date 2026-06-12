import Foundation
import XCTest

@testable import Omi_Computer

final class CapturedFrameMetadataTests: XCTestCase {
  func testCapturedFrameDefaultsToTimerTrigger() {
    let frame = CapturedFrame(
      jpegData: Data(),
      appName: "Notes",
      frameNumber: 42
    )

    XCTAssertEqual(frame.captureTrigger, .timer)
  }

  func testCapturedFramePreservesExplicitTrigger() {
    let frame = CapturedFrame(
      jpegData: Data(),
      appName: "Safari",
      windowTitle: "Docs",
      frameNumber: 7,
      captureTrigger: .startupImmediate
    )

    XCTAssertEqual(frame.captureTrigger, .startupImmediate)
  }
}
