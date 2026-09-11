import CoreGraphics
import XCTest

@testable import Omi_Computer

/// The persistent-stream contract: `startCapture` is the only action that pays a TCC
/// authorization, so the policy must reuse or retarget the live stream in every case
/// where one exists. If any of these degrade to `.startStream`, the per-frame
/// authorization sampling — the root of the consent-re-prompt defect — comes back.
final class WindowCaptureStreamPolicyTests: XCTestCase {
  private typealias FilterKey = WindowCaptureStreamPolicy.FilterKey
  private typealias ConfigKey = WindowCaptureStreamPolicy.ConfigKey

  private let scope = FilterKey(displayID: 1, excludedApplicationPIDs: [100, 200])
  private let config = ConfigKey(
    sourceRect: CGRect(x: 0, y: 30, width: 1710, height: 1072),
    outputSize: CGSize(width: 1710, height: 1072))
  private let movedConfig = ConfigKey(
    sourceRect: CGRect(x: 300, y: 130, width: 1710, height: 1072),
    outputSize: CGSize(width: 1710, height: 1072))

  func testNoRunningStreamStarts() {
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: nil, runningFilter: nil, runningConfig: nil,
        requestedWindowID: 42, requestedFilter: scope, requestedConfig: config),
      .startStream
    )
  }

  func testSameWindowSameScopeReuses() {
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: 42, runningFilter: scope, runningConfig: config,
        requestedWindowID: 42, requestedFilter: scope, requestedConfig: config),
      .reuseStream
    )
  }

  /// The frontmost window changes constantly (every app switch); each change must ride
  /// the live stream, never a new session. Another app owns the window, so the excluded
  /// set differs and the filter is what changes.
  func testSwitchToAnotherAppUpdatesFilterInsteadOfRestarting() {
    let otherScope = FilterKey(displayID: 1, excludedApplicationPIDs: [100, 300])
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: 42, runningFilter: scope, runningConfig: config,
        requestedWindowID: 43, requestedFilter: otherScope, requestedConfig: movedConfig),
      .updateFilter
    )
  }

  /// Two windows of one app share the scope; only the crop moves.
  func testSwitchWithinOneAppOnlyReconfigures() {
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: 42, runningFilter: scope, runningConfig: config,
        requestedWindowID: 43, requestedFilter: scope, requestedConfig: movedConfig),
      .updateConfiguration
    )
  }

  func testMoveOrResizeOfSameWindowOnlyReconfigures() {
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: 42, runningFilter: scope, runningConfig: config,
        requestedWindowID: 42, requestedFilter: scope, requestedConfig: movedConfig),
      .updateConfiguration
    )
  }

  func testWindowMovingToAnotherDisplayUpdatesFilter() {
    let otherDisplay = FilterKey(displayID: 2, excludedApplicationPIDs: [100, 200])
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: 42, runningFilter: scope, runningConfig: config,
        requestedWindowID: 42, requestedFilter: otherDisplay, requestedConfig: config),
      .updateFilter
    )
  }

  /// An application that appeared since the stream was built must join the exclusion
  /// list on the next request, or its windows could overlap into the capture.
  func testNewApplicationRebuildsFilter() {
    let grown = FilterKey(displayID: 1, excludedApplicationPIDs: [100, 200, 300])
    XCTAssertEqual(
      WindowCaptureStreamPolicy.action(
        runningWindowID: 42, runningFilter: scope, runningConfig: config,
        requestedWindowID: 42, requestedFilter: grown, requestedConfig: config),
      .updateFilter
    )
  }

  // MARK: - Geometry

  func testCropRectIsDisplayRelative() {
    let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let window = CGRect(x: -1500, y: 100, width: 800, height: 600)
    XCTAssertEqual(
      WindowCaptureStreamPolicy.cropRect(windowFrame: window, displayFrame: display),
      CGRect(x: 420, y: 100, width: 800, height: 600))
  }

  func testCropRectClipsToTheDisplay() {
    let display = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let window = CGRect(x: 2800, y: 1500, width: 600, height: 400)
    XCTAssertEqual(
      WindowCaptureStreamPolicy.cropRect(windowFrame: window, displayFrame: display),
      CGRect(x: 2800, y: 1500, width: 208, height: 192))
  }

  func testCropRectIsNilOffTheDisplay() {
    let display = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let window = CGRect(x: 4000, y: 0, width: 800, height: 600)
    XCTAssertNil(WindowCaptureStreamPolicy.cropRect(windowFrame: window, displayFrame: display))
  }

  func testDisplayIndexPrefersTheDisplayUnderTheWindowCenter() {
    let displays = [
      CGRect(x: 0, y: 0, width: 3008, height: 1692),
      CGRect(x: 3008, y: 0, width: 1920, height: 1080),
    ]
    XCTAssertEqual(
      WindowCaptureStreamPolicy.displayIndex(
        for: CGRect(x: 2900, y: 100, width: 400, height: 300), displayFrames: displays),
      1)
  }

  func testDisplayIndexFallsBackToTheLargestOverlap() {
    let displays = [
      CGRect(x: 0, y: 0, width: 1000, height: 1000),
      CGRect(x: 1000, y: 0, width: 1000, height: 1000),
    ]
    XCTAssertEqual(
      WindowCaptureStreamPolicy.displayIndex(
        for: CGRect(x: 600, y: 800, width: 600, height: 600), displayFrames: displays),
      0)
  }

  func testDisplayIndexIsNilWhenTheWindowIsOnNoDisplay() {
    let displays = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
    XCTAssertNil(
      WindowCaptureStreamPolicy.displayIndex(
        for: CGRect(x: 5000, y: 5000, width: 10, height: 10), displayFrames: displays))
  }

  // MARK: - Filter shape

  /// A live stream whose filter names a window makes macOS replace that window's
  /// traffic-light buttons with the window-sharing badge for the stream's whole life,
  /// and a display filter that lists the window via `including:` gets the badge too.
  /// The engine must scope by display, exclude applications, and crop instead.
  func testStreamEngineNeverBuildsAWindowScopedFilter() throws {
    let engine = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/WindowCaptureStreamEngine.swift")
    // omi-test-quality: source-inspection -- static contract: ScreenCaptureKit filters cannot be constructed or inspected in a unit test, so the filter shape can only be pinned at the source.
    let code = try String(contentsOf: engine, encoding: .utf8)
      .split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    XCTAssertFalse(code.contains("desktopIndependentWindow"), "window-scoped filter would badge the window")
    XCTAssertFalse(code.contains("including:"), "listing the window in a display filter badges it too")
    XCTAssertTrue(code.contains("excludingApplications:"))
    XCTAssertTrue(code.contains("config.sourceRect = key.sourceRect"))
  }

  // MARK: - Idle teardown

  /// A live stream keeps the OS screen-recording indicator on; it must not outlive
  /// actual capture requests, and it must not be torn down while requests still flow
  /// (each rebuild costs an authorization sample).
  func testIdleTeardownFiresOnlyAfterTimeout() {
    let now = Date()
    XCTAssertFalse(
      WindowCaptureStreamPolicy.shouldSuspendForIdle(
        lastRequestAt: now.addingTimeInterval(-59), now: now, idleTimeout: 60))
    XCTAssertTrue(
      WindowCaptureStreamPolicy.shouldSuspendForIdle(
        lastRequestAt: now.addingTimeInterval(-60), now: now, idleTimeout: 60))
    XCTAssertTrue(
      WindowCaptureStreamPolicy.shouldSuspendForIdle(
        lastRequestAt: .distantPast, now: now, idleTimeout: 60))
  }
}
