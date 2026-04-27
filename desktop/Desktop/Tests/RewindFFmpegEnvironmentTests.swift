import XCTest

@testable import Omi_Computer

final class RewindFFmpegEnvironmentTests: XCTestCase {
  func testRewindFFmpegProcessesUseScrubbedEnvironment() throws {
    let testsPath = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // Desktop/

    let paths = [
      testsPath.appendingPathComponent("Sources/Rewind/Core/VideoChunkEncoder.swift"),
      testsPath.appendingPathComponent("Sources/Rewind/Core/RewindStorage.swift"),
    ]

    for path in paths {
      let src = try String(contentsOf: path, encoding: .utf8)
      XCTAssert(src.contains("ffmpegEnvironment()"),
        "\(path.lastPathComponent) should build a minimal ffmpeg environment")
      XCTAssert(src.contains("process.environment = ffmpegEnvironment()"),
        "\(path.lastPathComponent) should not let ffmpeg inherit app auth environment")
      XCTAssertFalse(src.contains("ProcessInfo.processInfo.environment"),
        "\(path.lastPathComponent) must not copy the full app environment into ffmpeg")
    }
  }
}
