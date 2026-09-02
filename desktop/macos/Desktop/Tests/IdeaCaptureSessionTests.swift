import XCTest

@testable import Omi_Computer

/// Drives the desktop idea-capture session through AppState's production transitions
/// with the mic seam stubbed, so no real capture starts and no network is touched
/// (nothing is transcribing, so stop files nothing).
@MainActor
final class IdeaCaptureSessionTests: XCTestCase {
  @MainActor private final class FakeMic {
    var mode: AssistantSettings.AudioRecordingMode
    var setModeCalls: [AssistantSettings.AudioRecordingMode] = []
    init(mode: AssistantSettings.AudioRecordingMode) { self.mode = mode }
    var control: IdeaCaptureMicControl {
      IdeaCaptureMicControl(
        mode: { [unowned self] in self.mode },
        setMode: { [unowned self] in
          self.setModeCalls.append($0)
          self.mode = $0
        })
    }
  }

  private var savedPaywalled: Any?
  private var stateChanges = 0
  private var stateObserver: NSObjectProtocol?

  override func setUp() async throws {
    savedPaywalled = UserDefaults.standard.object(forKey: .desktopIsPaywalled)
    UserDefaults.standard.removeObject(forKey: .desktopIsPaywalled)
    stateObserver = NotificationCenter.default.addObserver(
      forName: .ideaCaptureStateChanged, object: nil, queue: nil
    ) { [weak self] _ in self?.stateChanges += 1 }
  }

  override func tearDown() async throws {
    if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    if let savedPaywalled {
      UserDefaults.standard.set(savedPaywalled, forKey: .desktopIsPaywalled)
    } else {
      UserDefaults.standard.removeObject(forKey: .desktopIsPaywalled)
    }
  }

  private func makeAppState(mic: FakeMic) -> AppState {
    let appState = AppState()
    appState.ideaCaptureMicControl = mic.control
    return appState
  }

  func testStartForcesAlwaysModeAndStopRestoresThePriorMode() async {
    let mic = FakeMic(mode: .onlyMeetings)
    let appState = makeAppState(mic: mic)

    await appState.startIdeaCapture()

    XCTAssertTrue(appState.isIdeaCaptureActive)
    XCTAssertEqual(mic.setModeCalls, [.always])
    XCTAssertEqual(stateChanges, 1)

    await appState.stopIdeaCaptureAndFile()

    XCTAssertFalse(appState.isIdeaCaptureActive)
    XCTAssertEqual(mic.setModeCalls, [.always, .onlyMeetings], "the session must hand the mic back")
    XCTAssertEqual(stateChanges, 2)
  }

  func testSessionLeavesAnAlreadyAlwaysOnMicAlone() async {
    let mic = FakeMic(mode: .always)
    let appState = makeAppState(mic: mic)

    await appState.startIdeaCapture()
    await appState.stopIdeaCaptureAndFile()

    XCTAssertTrue(mic.setModeCalls.isEmpty)
    XCTAssertFalse(appState.isIdeaCaptureActive)
  }

  func testStopDoesNotClobberAModeTheUserChangedMidSession() async {
    let mic = FakeMic(mode: .off)
    let appState = makeAppState(mic: mic)

    await appState.startIdeaCapture()
    mic.mode = .onlyMeetings
    await appState.stopIdeaCaptureAndFile()

    XCTAssertEqual(mic.setModeCalls, [.always], "restore only undoes the session's own change")
  }

  func testStopWithoutASessionIsANoOp() async {
    let mic = FakeMic(mode: .off)
    let appState = makeAppState(mic: mic)

    await appState.stopIdeaCaptureAndFile()

    XCTAssertFalse(appState.isIdeaCaptureActive)
    XCTAssertTrue(mic.setModeCalls.isEmpty)
    XCTAssertEqual(stateChanges, 0)
  }

  func testToggleRecordsIntentWhileATransitionIsRunning() async {
    let mic = FakeMic(mode: .off)
    let appState = makeAppState(mic: mic)

    appState.ideaCaptureTransitionRunning = true
    await appState.toggleIdeaCapture()

    XCTAssertFalse(appState.isIdeaCaptureActive, "a click mid-transition only records intent")
    XCTAssertEqual(appState.ideaCaptureDesiredActive, true)

    appState.ideaCaptureTransitionRunning = false
    await appState.toggleIdeaCapture()

    XCTAssertTrue(appState.isIdeaCaptureActive)
    XCTAssertNil(appState.ideaCaptureDesiredActive, "the runner loop drains the recorded intent")

    await appState.toggleIdeaCapture()
    XCTAssertFalse(appState.isIdeaCaptureActive)
  }

  func testPaywalledUserCannotStartASession() async {
    let mic = FakeMic(mode: .off)
    let appState = makeAppState(mic: mic)
    // Set after init, which clears a stale flag; the setter mirrors it to UserDefaults.
    appState.isPaywalled = true

    await appState.startIdeaCapture()

    if APIKeyService.isByokActive {
      // BYOK users are never paywalled, so the flag must not block them.
      XCTAssertTrue(appState.isIdeaCaptureActive)
    } else {
      XCTAssertFalse(appState.isIdeaCaptureActive)
      XCTAssertTrue(mic.setModeCalls.isEmpty, "a blocked start must not touch the mic")
      XCTAssertEqual(stateChanges, 0)
    }
  }
}
