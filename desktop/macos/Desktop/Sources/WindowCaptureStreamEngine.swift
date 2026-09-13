import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
// ScreenCaptureKit's async stream methods are nonisolated and take non-Sendable
// arguments (SCContentFilter, SCStreamConfiguration), so every call from this actor
// reads as sending a `self`-isolated value to a nonisolated method. The pinned CI
// toolchain's SDK carries no concurrency annotations for the framework, which makes
// those errors rather than warnings; a newer SDK annotates them and stays quiet.
// `@preconcurrency` is the sanctioned way to say "this module predates strict
// concurrency" — the calls are serialized by the stream lock, which is what actually
// makes them safe.
@preconcurrency import ScreenCaptureKit

/// Pure reconfiguration policy for the persistent capture stream, extracted so the
/// session-reuse contract is unit-testable without ScreenCaptureKit: a request must
/// reuse the running stream whenever it can, because every `startCapture` is a fresh
/// TCC authorization — the exact sampling this engine exists to eliminate.
enum WindowCaptureStreamPolicy {
  enum StreamAction: Equatable {
    /// No usable stream — build one (this is the only action that costs an authorization).
    case startStream
    /// Same window, same output size — serve from the running stream.
    case reuseStream
    /// The capture scope changed (another display, or a different set of excluded
    /// applications): retarget the live stream via `updateContentFilter`.
    case updateFilter
    /// Same scope, different window, crop, or output size (the user switched between
    /// two windows of one app, or moved or resized one): `updateConfiguration` only.
    case updateConfiguration
  }

  /// Everything the live stream's content filter is built from. Same key, same filter.
  struct FilterKey: Equatable {
    var displayID: CGDirectDisplayID
    var excludedApplicationPIDs: Set<pid_t>
  }

  /// Everything the live stream's configuration is built from. Same key, same configuration.
  struct ConfigKey: Equatable {
    var sourceRect: CGRect
    var outputSize: CGSize
  }

  static func action(
    runningWindowID: CGWindowID?,
    runningFilter: FilterKey?,
    runningConfig: ConfigKey?,
    requestedWindowID: CGWindowID,
    requestedFilter: FilterKey,
    requestedConfig: ConfigKey
  ) -> StreamAction {
    guard let runningWindowID, let runningFilter, let runningConfig else { return .startStream }
    if runningFilter != requestedFilter { return .updateFilter }
    if runningWindowID != requestedWindowID || runningConfig != requestedConfig {
      return .updateConfiguration
    }
    return .reuseStream
  }

  /// The display-relative crop that isolates `windowFrame` on a display occupying
  /// `displayFrame` (both in the global space ScreenCaptureKit reports), or nil when
  /// the window has no area on that display.
  static func cropRect(windowFrame: CGRect, displayFrame: CGRect) -> CGRect? {
    let visible = windowFrame.intersection(displayFrame)
    guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
    return visible.offsetBy(dx: -displayFrame.origin.x, dy: -displayFrame.origin.y)
  }

  /// Index of the display whose stream should serve the window: the one under its
  /// center, else the one showing the largest part of it, nil when it is on none.
  static func displayIndex(for windowFrame: CGRect, displayFrames: [CGRect]) -> Int? {
    let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
    if let index = displayFrames.firstIndex(where: { $0.contains(center) }) { return index }
    let areas = displayFrames.map { frame -> CGFloat in
      let overlap = frame.intersection(windowFrame)
      return overlap.isNull ? 0 : overlap.width * overlap.height
    }
    guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else {
      return nil
    }
    return best
  }

  /// Whether the stream should be torn down for lack of use. A live SCStream keeps the
  /// OS screen-recording indicator on, so it must not outlive actual capture requests:
  /// the capture tick already gates itself off while the user is idle, and this is the
  /// matching teardown. Rebuild-on-next-request costs one authorization per idle period,
  /// not one per frame.
  static func shouldSuspendForIdle(
    lastRequestAt: Date, now: Date, idleTimeout: TimeInterval
  ) -> Bool {
    now.timeIntervalSince(lastRequestAt) >= idleTimeout
  }
}

/// One long-lived `SCStream` scoped to the frontmost window, serving every frame request
/// (full captures and the ≤80 px previews alike) from the stream's latest delivered frame.
///
/// Why a stream and not one-shot screenshots: each `SCScreenshotManager.captureImage`
/// with an app-built `SCContentFilter(desktopIndependentWindow:)` is its own capture
/// session, and macOS runs a full TCC authorization per session — measured at ~1.5/s
/// (~5,000/hour) under the capture tick. macOS ties its periodic re-confirmation of
/// app-built filters to session creation, so that rate makes the consent dialog fire the
/// instant it comes due. One stream = one authorization at `startCapture`; window
/// switches ride `updateContentFilter` / `updateConfiguration` on the live stream.
///
/// Scope: the stream is display-scoped, excludes every application other than the
/// target window's owner, and crops to the window's frame (`sourceRect`). It is NOT a
/// `desktopIndependentWindow` filter and must not become one: a live stream whose
/// filter names a window makes macOS replace that window's traffic-light buttons with
/// the "window is being shared" badge for as long as the stream runs, on every app the
/// user brings forward. A display filter that names the window via `including:` gets
/// the badge too; excluding applications does not (verified on macOS 27.0 by
/// screenshotting the captured window's title bar under each filter shape).
/// The privacy boundary stays OS-enforced: excluded applications are never composited,
/// so another app's window overlapping the target cannot leak into the frame (also
/// verified, against a window occluded by the frontmost app). The residual is an
/// application that appears after the shareable-content snapshot the filter was built
/// from; that snapshot is at most `ScreenCaptureService.sharedContentTTL` old, and the
/// filter is rebuilt as soon as the excluded set changes. Frames are dropped outright
/// for the whole duration of a retarget (see `CaptureFrameSink`), so a request for a
/// new window cannot be served the previous window's pixels.
///
/// Concurrency contract — read this before editing:
/// - Every mutation of `stream` / `sink` / `streamWindowID` / `streamConfigSize` runs
///   while holding the stream lock. Actor isolation alone is NOT enough: all of these
///   operations `await` non-Sendable ScreenCaptureKit calls, and an actor is reentrant
///   across `await`, so a second request would otherwise interleave with a half-built
///   stream (two live streams = a leak and a second TCC authorization).
/// - The lock is held across the configuration ops only, never across the frame wait —
///   a 3 s wait must not serialize other requesters behind it.
/// - The frame wait is done on the `CaptureFrameSink` instance that belongs to the
///   stream that was configured, captured as a local. Nothing re-reads `self.sink`
///   after a suspension, so a teardown-and-rebuild during the wait resolves the old
///   waiter (with `nil`) instead of crossing streams.
@available(macOS 14.0, *)
actor WindowCaptureStreamEngine {
  static let shared = WindowCaptureStreamEngine()

  enum FrameResult {
    case success(CGImage)
    /// ScreenCaptureKit rejected the session with "user declined TCCs" — the consent
    /// dialog is (or was) on screen. The caller must treat this as terminal; retrying
    /// opens a new session, which re-arms the dialog.
    case permissionDeclined
    case failed
  }

  /// Teardown after this long without a capture request (user idle / capture gated off).
  static let idleTeardownSeconds: TimeInterval = 60
  /// How long to wait for SCK to push a frame after start / filter change. SCK delivers
  /// promptly when content is dirty, which a fresh target always is.
  private static let frameWaitTimeoutNs: UInt64 = 3_000_000_000
  /// 2 fps ceiling: the capture tick polls at 1 Hz and SCK only pushes on content
  /// change anyway, so this bounds cost without starving a dwell double-capture.
  private static let minimumFrameInterval = CMTime(value: 1, timescale: 2)
  /// Poll interval for `acquireStreamLock`. Configuration ops finish in tens of ms and
  /// requesters arrive at ~1 Hz, so this is a handful of wakeups at worst.
  private static let lockPollNs: UInt64 = 20_000_000
  /// Hard bound on waiting for the stream lock. Without it, a `startCapture()` that
  /// never returns (WindowServer wedged, TCC prompt sitting unanswered) parks EVERY
  /// later request in the poll loop forever — a silent hang with no failure to report.
  /// Bounded, the requests fail, the capture failure tracker sees them, and the app's
  /// existing recovery path runs instead of the engine going quiet.
  private static let lockAcquireTimeoutNs: UInt64 = 5_000_000_000

  private var stream: SCStream?
  /// One sink per stream, never shared. A departing stream stays alive until its
  /// `stopCapture()` completes and can deliver a late frame or a late
  /// `didStopWithError` after we have already built its replacement; with a shared
  /// sink those would land on the new stream's state — poisoning it with a bogus stop
  /// error, or worse, tagging the old window's pixels with the new window's ID.
  private var sink: CaptureFrameSink?
  private var streamWindowID: CGWindowID?
  private var streamFilter: WindowCaptureStreamPolicy.FilterKey?
  private var streamConfig: WindowCaptureStreamPolicy.ConfigKey?
  private let sampleQueue = DispatchQueue(label: "com.omi.window-capture-stream")
  private var idleWatchdog: Task<Void, Never>?
  private var lastRequestAt = Date.distantPast
  private var isMutatingStream = false

  /// Capture the given window at `requestedMaxSize` (long edge, points-derived pixels).
  /// `content` is the shareable-content snapshot the window came from; the stream's
  /// scope (display, excluded applications) is derived from it.
  /// The stream always runs at the full `ScreenCaptureService.maxSize` configuration;
  /// smaller requests (the ≤80 px previews) are served by downscaling the latest full
  /// frame, so preview and full ticks never thrash the stream configuration.
  func captureFrame(window: SCWindow, content: SCShareableContent, requestedMaxSize: CGFloat) async
    -> FrameResult
  {
    lastRequestAt = Date()
    guard let target = Self.makeTarget(window: window, content: content) else {
      // Zero-area or off every display: same refusal as the one-shot path.
      return .failed
    }
    let windowID = window.windowID

    let activeSink: CaptureFrameSink
    switch await configureStream(target) {
    case .ready(let configured):
      activeSink = configured
    case .declined:
      return .permissionDeclined
    case .failed:
      return .failed
    }

    guard
      let frame = await activeSink.nextFrame(windowID: windowID, timeoutNs: Self.frameWaitTimeoutNs)
    else {
      // No frame inside the window: either the stream died (classify its stop error) or
      // SCK stalled. Either way this tick fails and the failure tracker takes over.
      if let stopError = activeSink.takeStopError() {
        await teardownIfCurrent(sink: activeSink, reason: "stream stopped while waiting for frame")
        return ScreenCaptureService.classifyCaptureError(stopError) == .permissionDeclined
          ? .permissionDeclined : .failed
      }
      log("WindowCaptureStreamEngine: timed out waiting for a frame from window \(windowID)")
      return .failed
    }

    if requestedMaxSize < ScreenCaptureService.maxSize {
      guard let scaled = Self.downscale(frame, maxSize: requestedMaxSize) else {
        // Answer off-contract or not at all: the ≤80 px preview's dHash is compared
        // against other preview-scale hashes, and a full-resolution image aliases
        // differently (see RewindOCRService.previewScaleDHash), so silently returning
        // the full frame would poison the similarity history rather than degrade.
        log("WindowCaptureStreamEngine: downscale to \(Int(requestedMaxSize))px failed")
        return .failed
      }
      return .success(scaled)
    }
    return .success(frame)
  }

  /// Tear the stream down (sleep, lock, monitoring stop, idle). Safe to call with no
  /// stream running. The next capture request rebuilds lazily.
  ///
  /// Takes the stream lock rather than checking `stream != nil` up front: a suspend
  /// that arrives while `startCapture()` is still in flight would otherwise see a nil
  /// stream, do nothing, and let the stream be born *after* the machine locked —
  /// leaving the OS screen-recording indicator lit over a locked screen.
  func suspend(reason: String) async {
    await withStreamLock {
      guard self.stream != nil else { return }
      log("WindowCaptureStreamEngine: suspending capture stream (\(reason))")
      await self.teardownStreamLocked(reason: reason)
    }
  }

  // MARK: - Serialization

  /// Serialize every stream mutation. Correctness rests on one property: between the
  /// `while` loop observing `false` and the assignment of `true` there is NO suspension
  /// point, so on the actor's serial executor the test-and-set is atomic. Do not
  /// introduce an `await` between them.
  /// Returns `false` if the lock could not be acquired within `lockAcquireTimeoutNs`.
  private func acquireStreamLock() async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ Self.lockAcquireTimeoutNs
    while isMutatingStream {
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        log(
          "WindowCaptureStreamEngine: stream lock held past \(Self.lockAcquireTimeoutNs / 1_000_000_000)s — abandoning this request"
        )
        return false
      }
      try? await Task.sleep(nanoseconds: Self.lockPollNs)
    }
    isMutatingStream = true
    return true
  }

  private func releaseStreamLock() {
    isMutatingStream = false
  }

  /// Run `body` under the stream lock. Returns `false` if the lock timed out and `body`
  /// never ran. Holders that need to return a non-Sendable value take the lock directly
  /// with `acquireStreamLock` instead — see `configureStream`.
  @discardableResult
  private func withStreamLock(_ body: () async -> Void) async -> Bool {
    guard await acquireStreamLock() else { return false }
    defer { releaseStreamLock() }
    await body()
    return true
  }

  // MARK: - Stream lifecycle

  private enum ConfigureOutcome {
    case ready(CaptureFrameSink)
    case declined
    case failed
  }

  private func configureStream(_ target: StreamTarget) async -> ConfigureOutcome {
    // Takes the lock directly rather than through `withStreamLock`: this is the only
    // holder that returns a non-Sendable value (`CaptureFrameSink`), and handing one
    // out of a closure makes it cross an isolation boundary the pinned CI toolchain
    // rejects. `defer` keeps the release leak-proof across every exit below.
    guard await acquireStreamLock() else { return .failed }
    defer { releaseStreamLock() }

    // A stream the OS already stopped must not be reused; classify its stop error so a
    // consent decline surfaces without paying another startCapture authorization.
    if let stopError = self.sink?.takeStopError() {
      await self.teardownStreamLocked(
        reason: "stream stopped by OS: \(stopError.localizedDescription)")
      if ScreenCaptureService.classifyCaptureError(stopError) == .permissionDeclined {
        return .declined
      }
    }

    do {
      switch WindowCaptureStreamPolicy.action(
        runningWindowID: self.streamWindowID,
        runningFilter: self.streamFilter,
        runningConfig: self.streamConfig,
        requestedWindowID: target.window.windowID,
        requestedFilter: target.filterKey,
        requestedConfig: target.configKey)
      {
      case .startStream:
        try await self.startStreamLocked(target)
      case .updateFilter:
        guard let stream = self.stream, let sink = self.sink else { return .failed }
        // Privacy: beginRetarget stops the sink accepting ANY frame, and the stream
        // keeps producing old-scope frames until the filter change lands. Tagging
        // them with the new window ID (what an expect(windowID:) up front would do)
        // is exactly how a caller ends up holding a screenshot of the window the user
        // just switched away from — possibly a Rewind-excluded one.
        sink.beginRetarget()
        try await stream.updateContentFilter(Self.makeFilter(target))
        if self.streamConfig != target.configKey {
          try await stream.updateConfiguration(self.makeConfiguration(target.configKey))
        }
        sink.endRetarget(windowID: target.window.windowID)
        self.streamWindowID = target.window.windowID
        self.streamFilter = target.filterKey
        self.streamConfig = target.configKey
      case .updateConfiguration:
        guard let stream = self.stream, let sink = self.sink else { return .failed }
        // Same scope, new window or crop: the cached frame shows the wrong region and
        // in-flight frames still carry the old one, so drop both.
        sink.beginRetarget()
        try await stream.updateConfiguration(self.makeConfiguration(target.configKey))
        sink.endRetarget(windowID: target.window.windowID)
        self.streamWindowID = target.window.windowID
        self.streamConfig = target.configKey
      case .reuseStream:
        break
      }
    } catch {
      log(
        "WindowCaptureStreamEngine: stream (re)configuration failed: \(error.localizedDescription)"
      )
      await self.teardownStreamLocked(reason: "configuration error")
      return ScreenCaptureService.classifyCaptureError(error) == .permissionDeclined
        ? .declined : .failed
    }

    guard let sink = self.sink else { return .failed }
    return .ready(sink)
  }

  private func startStreamLocked(_ target: StreamTarget) async throws {
    let newSink = CaptureFrameSink()
    let filter = Self.makeFilter(target)
    let config = makeConfiguration(target.configKey)
    let newStream = SCStream(filter: filter, configuration: config, delegate: newSink)
    try newStream.addStreamOutput(newSink, type: .screen, sampleHandlerQueue: sampleQueue)
    newSink.endRetarget(windowID: target.window.windowID)
    // The one TCC authorization this engine pays per stream lifetime.
    try await newStream.startCapture()
    stream = newStream
    sink = newSink
    streamWindowID = target.window.windowID
    streamFilter = target.filterKey
    streamConfig = target.configKey
    startIdleWatchdog()
    log(
      "WindowCaptureStreamEngine: started persistent stream for window \(target.window.windowID) on display \(target.display.displayID)"
    )
  }

  /// Tear down the current stream. Caller MUST hold the stream lock.
  ///
  /// `stopCapture()` is awaited inline. An earlier revision hopped it onto a detached
  /// `Task` "so as not to hold the actor"; that was wrong twice over — an `await` never
  /// holds an actor's executor (it suspends the task and lets other messages run), and
  /// handing a non-Sendable `SCStream` that is still reachable from `self`-isolated code
  /// to a concurrently-executing closure is a data race that Swift 6 rejects outright.
  /// Awaiting here is both the safe and the simpler answer: the lock is held for the
  /// duration, which is what keeps a rebuild from racing the stop.
  private func teardownStreamLocked(reason: String) async {
    idleWatchdog?.cancel()
    idleWatchdog = nil
    let departingStream = stream
    let departingSink = sink
    stream = nil
    sink = nil
    streamWindowID = nil
    streamFilter = nil
    streamConfig = nil
    // Detach before stopping: the departing stream may still emit a frame or a
    // didStopWithError, and a detached sink drops both instead of letting them reach
    // a caller or be mistaken for the next stream's state.
    departingSink?.detach()
    guard let departingStream else { return }
    do {
      try await departingStream.stopCapture()
    } catch {
      // Already stopped by the OS is the common case here — nothing to repair.
      log("WindowCaptureStreamEngine: stopCapture (\(reason)): \(error.localizedDescription)")
    }
  }

  /// Tear down only if the stream identified by `candidate` is still the current one.
  /// Without the identity check, a slow failure path could tear down a healthy stream
  /// that was rebuilt while it was suspended.
  private func teardownIfCurrent(sink candidate: CaptureFrameSink, reason: String) async {
    await withStreamLock {
      guard self.sink === candidate else { return }
      await self.teardownStreamLocked(reason: reason)
    }
  }

  /// What one capture request resolves to once the window is placed on a display.
  private struct StreamTarget {
    let window: SCWindow
    let display: SCDisplay
    let excludedApplications: [SCRunningApplication]
    let filterKey: WindowCaptureStreamPolicy.FilterKey
    let configKey: WindowCaptureStreamPolicy.ConfigKey
  }

  /// Nil when the window has no area on any display (`captureDimensions` refuses a
  /// zero-area crop for the same reason it refuses a zero-area window).
  private static func makeTarget(window: SCWindow, content: SCShareableContent) -> StreamTarget? {
    let displays = content.displays
    guard
      let index = WindowCaptureStreamPolicy.displayIndex(
        for: window.frame, displayFrames: displays.map(\.frame))
    else { return nil }
    let display = displays[index]
    guard
      let crop = WindowCaptureStreamPolicy.cropRect(
        windowFrame: window.frame, displayFrame: display.frame),
      let fullSize = ScreenCaptureService.captureDimensions(
        width: crop.width, height: crop.height, maxSize: ScreenCaptureService.maxSize)
    else { return nil }
    let ownerPID = window.owningApplication?.processID
    let excluded = content.applications.filter { $0.processID != ownerPID }
    return StreamTarget(
      window: window,
      display: display,
      excludedApplications: excluded,
      filterKey: .init(
        displayID: display.displayID, excludedApplicationPIDs: Set(excluded.map(\.processID))),
      configKey: .init(
        sourceRect: crop, outputSize: CGSize(width: fullSize.width, height: fullSize.height)))
  }

  /// Display-scoped and application-excluding on purpose; see the type comment for why
  /// a window-scoped filter is off the table.
  private static func makeFilter(_ target: StreamTarget) -> SCContentFilter {
    SCContentFilter(
      display: target.display, excludingApplications: target.excludedApplications,
      exceptingWindows: [])
  }

  private func makeConfiguration(_ key: WindowCaptureStreamPolicy.ConfigKey) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.scalesToFit = true
    config.showsCursor = false
    config.sourceRect = key.sourceRect
    config.width = Int(key.outputSize.width)
    config.height = Int(key.outputSize.height)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    ScreenCaptureService.applySingleWindowPixelIntegrityPolicy(to: config)
    config.minimumFrameInterval = Self.minimumFrameInterval
    config.queueDepth = 3
    return config
  }

  private func startIdleWatchdog() {
    idleWatchdog?.cancel()
    idleWatchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard let self else { return }
        await self.suspendIfIdle()
      }
    }
  }

  private func suspendIfIdle() async {
    await withStreamLock {
      guard self.stream != nil else { return }
      guard
        WindowCaptureStreamPolicy.shouldSuspendForIdle(
          lastRequestAt: self.lastRequestAt, now: Date(),
          idleTimeout: Self.idleTeardownSeconds)
      else { return }
      log(
        "WindowCaptureStreamEngine: no capture requests for \(Int(Self.idleTeardownSeconds))s — releasing stream"
      )
      await self.teardownStreamLocked(reason: "idle")
    }
  }

  // MARK: - Image helpers

  private static func downscale(_ image: CGImage, maxSize: CGFloat) -> CGImage? {
    guard
      let size = ScreenCaptureService.captureDimensions(
        width: CGFloat(image.width), height: CGFloat(image.height), maxSize: maxSize)
    else { return nil }
    guard
      let context = CGContext(
        data: nil,
        width: size.width,
        height: size.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    return context.makeImage()
  }
}

/// Receives frames and stream-stop errors from ScreenCaptureKit's callback queue and
/// hands them to the engine actor. NSObject because SCStreamOutput/SCStreamDelegate
/// require it; all mutable state is behind `lock`, hence `@unchecked Sendable`.
///
/// One instance per `SCStream`, never reused across streams — see the `sink` property.
///
/// The retarget protocol is the privacy-critical part. `beginRetarget()` puts the sink
/// in a state where EVERY delivered frame is dropped, because between the call to
/// `updateContentFilter` and its completion the stream is still producing the previous
/// window's pixels. `endRetarget(windowID:)` reopens it once the new filter is live.
/// Known residual: ScreenCaptureKit may have queued a frame produced under the old
/// filter just before the change landed, and this sink cannot tell such a frame from a
/// new one. Verify during dogfood by fast-switching between two visually distinct
/// windows and watching for a one-frame lag of the wrong window.
@available(macOS 14.0, *)
final class CaptureFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let lock = NSLock()
  /// The window whose frames are currently acceptable. `nil` means drop everything —
  /// either a retarget is in flight or this sink has been detached from a dead stream.
  private var acceptingWindowID: CGWindowID?
  private var isDetached = false
  private var latestFrame: (windowID: CGWindowID, image: CGImage)?
  private var waiter: CheckedContinuation<CGImage?, Never>?
  private var waiterGeneration = 0

  /// Whether a caller is currently parked in `nextFrame`. Tests use this to observe
  /// that a waiter has registered instead of sleeping for a plausible interval; a
  /// wall-clock wait would make the retarget assertions racy on a loaded machine.
  var hasParkedWaiter: Bool { lock.withLock { waiter != nil } }
  private var stopError: Error?

  /// CIContext for CVPixelBuffer → CGImage. Cheap at ≤2 fps.
  ///
  /// Deliberately an instance property, not a `static`. As a `static` it is global
  /// mutable state whose legality depends on whether the SDK in hand declares
  /// `CIContext` as `Sendable` — and the SDKs disagree: without `nonisolated(unsafe)`
  /// the pinned CI toolchain rejects it, with it a newer toolchain rejects it as
  /// unnecessary. No spelling satisfies both. Per-instance, the question never arises
  /// (this class is already `@unchecked Sendable`), and the cost is one context per
  /// stream — a lifetime this engine exists to make long.
  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  /// Stop accepting frames and drop what is cached. Call BEFORE an
  /// `updateContentFilter` / `updateConfiguration` await.
  func beginRetarget() {
    let staleWaiter: CheckedContinuation<CGImage?, Never>? = lock.withLock {
      acceptingWindowID = nil
      latestFrame = nil
      let stale = waiter
      waiter = nil
      return stale
    }
    // A waiter from the previous target must not receive the new target's frame.
    staleWaiter?.resume(returning: nil)
  }

  /// Start accepting frames for `windowID`. Call AFTER the reconfiguration await has
  /// returned, i.e. once the stream is actually producing the new target's pixels.
  func endRetarget(windowID: CGWindowID) {
    lock.withLock {
      guard !isDetached else { return }
      latestFrame = nil
      acceptingWindowID = windowID
    }
  }

  /// Permanently retire this sink; its stream is going away. Idempotent.
  func detach() {
    let staleWaiter: CheckedContinuation<CGImage?, Never>? = lock.withLock {
      isDetached = true
      acceptingWindowID = nil
      latestFrame = nil
      stopError = nil
      let stale = waiter
      waiter = nil
      return stale
    }
    staleWaiter?.resume(returning: nil)
  }

  /// Read-and-clear the terminal stream error, if the OS stopped the stream.
  func takeStopError() -> Error? {
    lock.withLock {
      let error = stopError
      stopError = nil
      return error
    }
  }

  /// Latest frame for `windowID` if one is cached (a static window legitimately
  /// produces no new frames — the cached one IS the current content); otherwise wait
  /// for the next delivery, bounded by `timeoutNs`.
  func nextFrame(windowID: CGWindowID, timeoutNs: UInt64) async -> CGImage? {
    return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
      let generation: Int? = lock.withLock {
        if isDetached {
          continuation.resume(returning: nil)
          return nil
        }
        if let latestFrame, latestFrame.windowID == windowID {
          continuation.resume(returning: latestFrame.image)
          return nil
        }
        if stopError != nil {
          continuation.resume(returning: nil)
          return nil
        }
        waiterGeneration += 1
        waiter = continuation
        return waiterGeneration
      }
      guard let generation else { return }
      Task.detached { [weak self] in
        try? await Task.sleep(nanoseconds: timeoutNs)
        self?.expireWaiter(generation: generation)
      }
    }
  }

  /// Generation-matched so this can never resume a waiter other than the one it armed:
  /// every registration bumps `waiterGeneration`, and a resumed waiter is cleared under
  /// the same lock, so a stale timer finds either a mismatched generation or no waiter.
  private func expireWaiter(generation: Int) {
    let expired: CheckedContinuation<CGImage?, Never>? = lock.withLock {
      guard waiterGeneration == generation, let pending = waiter else { return nil }
      waiter = nil
      return pending
    }
    expired?.resume(returning: nil)
  }

  // MARK: - SCStreamOutput

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }
    // Only complete frames carry displayable content; .idle/.blank/.suspended do not.
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let statusRaw = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: statusRaw) == .complete
    else { return }
    // Cheap gate before the CIContext render: during a retarget, and after detach,
    // there is no target to tag this frame with and it must be dropped, not converted.
    guard lock.withLock({ acceptingWindowID != nil }) else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
    deliver(cgImage)
  }

  /// Tag-and-publish a rendered frame. Split out of the SCK callback so the
  /// privacy-critical tagging rule — a frame is only ever tagged with the window the
  /// sink is CURRENTLY accepting, and is dropped outright when it is accepting none —
  /// is exercisable without a live capture session.
  func deliver(_ cgImage: CGImage) {
    let pendingWaiter: CheckedContinuation<CGImage?, Never>? = lock.withLock {
      // Re-checked under the lock: a retarget can have begun while the frame was being
      // rendered, and a frame that arrives mid-retarget belongs to the OLD window.
      guard let acceptingWindowID else { return nil }
      latestFrame = (acceptingWindowID, cgImage)
      let pending = waiter
      waiter = nil
      return pending
    }
    pendingWaiter?.resume(returning: cgImage)
  }

  // MARK: - SCStreamDelegate

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    log("WindowCaptureStreamEngine: stream stopped by OS: \(error.localizedDescription)")
    let pendingWaiter: CheckedContinuation<CGImage?, Never>? = lock.withLock {
      // A detached sink's stream is one we are already tearing down; its stop error is
      // expected and must not be reported as the next stream's failure.
      guard !isDetached else { return nil }
      stopError = error
      latestFrame = nil
      let pending = waiter
      waiter = nil
      return pending
    }
    pendingWaiter?.resume(returning: nil)
  }
}
