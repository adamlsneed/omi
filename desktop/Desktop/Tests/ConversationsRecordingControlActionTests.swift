import XCTest

@testable import Omi_Computer

final class ConversationsRecordingControlActionTests: XCTestCase {
  func testShowsStartRecordingActionWhenIdle() {
    let action = ConversationsRecordingControlAction.current(isTranscribing: false)

    XCTAssertEqual(action, .start)
    XCTAssertEqual(action.title, "Start Recording")
    XCTAssertEqual(action.systemImage, "mic.fill")
  }

  func testShowsStopRecordingActionWhileRecording() {
    let action = ConversationsRecordingControlAction.current(isTranscribing: true)

    XCTAssertEqual(action, .stop)
    XCTAssertEqual(action.title, "Stop Recording")
    XCTAssertEqual(action.systemImage, "stop.fill")
  }
}
