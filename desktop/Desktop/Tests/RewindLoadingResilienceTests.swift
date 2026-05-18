import XCTest

@testable import Omi_Computer

final class RewindLoadingResilienceTests: XCTestCase {
  func testInitialRewindLoadDoesNotAwaitCaptureIndexer() throws {
    let source = try desktopSource("Sources/Rewind/UI/RewindViewModel.swift")
    let body = try functionBody(named: "loadInitialData", in: source)

    XCTAssertFalse(body.contains("RewindIndexer.shared.initialize()"),
      "Rewind page loading must not wait on the capture/indexing actor")
    XCTAssert(body.contains("RewindDatabase.shared.initialize()"),
      "Rewind page loading should initialize the read-side database directly")
    XCTAssert(body.contains("RewindStorage.shared.initialize()"),
      "Rewind page loading should initialize read-side storage directly")
  }

  func testVideoChunkFinalizeDoesNotBlockActorWithWaitUntilExit() throws {
    let source = try desktopSource("Sources/Rewind/Core/VideoChunkEncoder.swift")
    let body = try functionBody(named: "finalizeCurrentChunk", in: source)

    XCTAssertFalse(body.contains("waitUntilExit()"),
      "Video chunk finalization must not synchronously block the encoder actor")
    XCTAssert(body.contains("waitForProcessExit"),
      "Video chunk finalization should use the async bounded process waiter")
  }

  private func desktopSource(_ relativePath: String) throws -> String {
    let testsPath = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // Desktop/
    return try String(contentsOf: testsPath.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private func functionBody(named functionName: String, in source: String) throws -> String {
    guard let signatureRange = source.range(of: "func \(functionName)") else {
      XCTFail("Could not find \(functionName)")
      return ""
    }

    guard let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else {
      XCTFail("Could not find opening brace for \(functionName)")
      return ""
    }

    var depth = 0
    var index = openingBrace

    while index < source.endIndex {
      if source[index] == "{" {
        depth += 1
      } else if source[index] == "}" {
        depth -= 1
        if depth == 0 {
          return String(source[openingBrace...index])
        }
      }
      index = source.index(after: index)
    }

    throw NSError(domain: "RewindLoadingResilienceTests", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "Could not parse body for \(functionName)"
    ])
  }
}
