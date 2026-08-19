import CoreGraphics
import XCTest

@testable import Omi_Computer

final class ScreenCaptureConfigurationTests: XCTestCase {
  func testCaptureDimensionsRejectsZeroHeightWindowFrame() {
    let size = ScreenCaptureService.captureDimensions(width: 1440, height: 0, maxSize: 3000)

    XCTAssertNil(size)
  }

  func testCaptureDimensionsRejectsNonFiniteWindowFrame() {
    let size = ScreenCaptureService.captureDimensions(
      width: CGFloat.nan, height: 900, maxSize: 3000)

    XCTAssertNil(size)
  }

  func testCaptureDimensionsPreservesAspectRatioWithinMaxSize() throws {
    let size = try XCTUnwrap(
      ScreenCaptureService.captureDimensions(width: 6000, height: 3000, maxSize: 3000))

    XCTAssertEqual(size.width, 3000)
    XCTAssertEqual(size.height, 1500)
  }
}
