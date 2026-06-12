import XCTest

@testable import Omi_Computer

final class IdeaCaptureSidebarActionTests: XCTestCase {
  func testShowsCaptureIdeaActionWhenIdle() {
    let action = IdeaCaptureSidebarAction.current(isActive: false)

    XCTAssertEqual(action, .start)
    XCTAssertEqual(action.title, "Capture Idea")
    XCTAssertEqual(action.systemImage, "lightbulb.fill")
    XCTAssertEqual(action.helpText, "Start recording a focused idea")
    XCTAssertEqual(action.accessibilityLabel, "Capture Idea")
  }

  func testShowsStopIdeaActionWhileCapturing() {
    let action = IdeaCaptureSidebarAction.current(isActive: true)

    XCTAssertEqual(action, .stop)
    XCTAssertEqual(action.title, "Stop Idea")
    XCTAssertEqual(action.systemImage, "stop.fill")
    XCTAssertEqual(action.helpText, "Stop recording and save this idea")
    XCTAssertEqual(action.accessibilityLabel, "Stop Idea")
  }

  func testRecordingControlCopyUsesConsistentNames() {
    XCTAssertEqual(DesktopRecordingControlCopy.screenRecordingTitle, "Screen Recording")
    XCTAssertEqual(DesktopRecordingControlCopy.microphoneTitle, "Microphone")
  }
}
