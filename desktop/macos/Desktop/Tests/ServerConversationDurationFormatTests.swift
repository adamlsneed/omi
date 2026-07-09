import XCTest

@testable import Omi_Computer

final class ServerConversationDurationFormatTests: XCTestCase {
  func testBelowOneMinuteShowsSecondsOnly() {
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 0), "0s")
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 45), "45s")
  }

  func testMinutesAndSeconds() {
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 60), "1m 0s")
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 330), "5m 30s")
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 3599), "59m 59s")
  }

  func testRollsUpToHours() {
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 3600), "1h 0m")
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 4605), "1h 16m")  // was "76m 45s"
    XCTAssertEqual(ServerConversation.formatDuration(seconds: 14400), "4h 0m")  // was "240m 0s"
  }

  func testNegativeDurationClampsToZero() {
    XCTAssertEqual(ServerConversation.formatDuration(seconds: -5), "0s")
  }
}
