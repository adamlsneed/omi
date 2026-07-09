import XCTest

@testable import Omi_Computer

final class IdeaCaptureToastHitRectTests: XCTestCase {
  // The toast panel is a fixed size; its visible card is inset by shadowPadding on every
  // side for the drop shadow. Tap detection must exclude that transparent margin.

  func testHitRectExcludesTheShadowMargin() {
    let pad = IdeaCaptureToast.shadowPadding
    let panel = NSRect(x: 100, y: 200, width: 384, height: 104)
    let hit = IdeaCaptureToast.tapHitRect(panelFrame: panel)

    XCTAssertEqual(hit, panel.insetBy(dx: pad, dy: pad))
    XCTAssertEqual(hit.width, panel.width - 2 * pad)
    XCTAssertEqual(hit.height, panel.height - 2 * pad)
  }

  func testCenterOfCardIsTappable() {
    let panel = NSRect(x: 100, y: 200, width: 384, height: 104)
    let hit = IdeaCaptureToast.tapHitRect(panelFrame: panel)
    XCTAssertTrue(hit.contains(NSPoint(x: panel.midX, y: panel.midY)))
  }

  func testPointsInTheInvisibleMarginAreNotTaps() {
    let pad = IdeaCaptureToast.shadowPadding
    let panel = NSRect(x: 100, y: 200, width: 384, height: 104)
    let hit = IdeaCaptureToast.tapHitRect(panelFrame: panel)

    // Just inside each panel edge but within the shadow margin: was wrongly a tap before.
    let insideMargin: [NSPoint] = [
      NSPoint(x: panel.minX + pad / 2, y: panel.midY),  // left margin
      NSPoint(x: panel.maxX - pad / 2, y: panel.midY),  // right margin
      NSPoint(x: panel.midX, y: panel.minY + pad / 2),  // bottom margin
      NSPoint(x: panel.midX, y: panel.maxY - pad / 2),  // top margin
    ]
    for p in insideMargin {
      XCTAssertTrue(panel.contains(p), "sanity: point should be within the full panel")
      XCTAssertFalse(hit.contains(p), "point in the shadow margin must not count as a tap")
    }
  }

  func testCardEdgesBoundTheHitRect() {
    let panel = NSRect(x: 0, y: 0, width: 384, height: 104)
    let hit = IdeaCaptureToast.tapHitRect(panelFrame: panel)
    XCTAssertTrue(hit.contains(NSPoint(x: hit.minX + 1, y: hit.minY + 1)))
    XCTAssertFalse(hit.contains(NSPoint(x: hit.minX - 1, y: hit.minY - 1)))
  }
}
