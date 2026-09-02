import Foundation

/// Seam between an idea-capture session and the audio-recording preference. Hermetic
/// tests swap it so a session transition does not start real capture.
struct IdeaCaptureMicControl {
  var mode: @MainActor () -> AssistantSettings.AudioRecordingMode
  var setMode: @MainActor (AssistantSettings.AudioRecordingMode) -> Void

  static let live = IdeaCaptureMicControl(
    mode: { AssistantSettings.shared.audioRecordingMode },
    setMode: { AssistantSettings.shared.audioRecordingMode = $0 })
}

/// Outcome of finishing and filing the desktop's own recording as an idea.
enum IdeaCaptureOutcome: Equatable {
  case nothing
  case savedToIdeas
  case savedLoose
}

// idea-capture (fork): desktop has no pendant, so "Capture Idea" is an app action. It
// closes this device's in-progress conversation and files the result under a dedicated
// "Ideas" folder, mirroring the mobile CaptureProvider.forceProcessingCurrentConversation
// (asIdea: true) path.
@MainActor
extension AppState {
  /// Resolve (or lazily create) the "Ideas" destination folder, caching its id.
  private func ensureIdeaFolder() async -> String? {
    do {
      let folders = try await APIClient.shared.getFolders()
      let cachedId = UserDefaults.standard.string(forKey: Self.ideaFolderIdKey) ?? ""
      if let existing = folders.first(where: {
        (!cachedId.isEmpty && $0.id == cachedId) || $0.name.lowercased() == "ideas"
      }) {
        UserDefaults.standard.set(existing.id, forKey: Self.ideaFolderIdKey)
        return existing.id
      }
      let created = try await APIClient.shared.createFolder(
        name: "Ideas",
        description: "Captured ideas: intentional, fleeting thoughts saved from the pendant or app.",
        color: "#22C55E")
      UserDefaults.standard.set(created.id, forKey: Self.ideaFolderIdKey)
      return created.id
    } catch {
      logError("idea-capture: ensure folder failed", error: error)
      return nil
    }
  }

  /// Finish the desktop's own recording and file the resulting conversation under
  /// "Ideas". Shared by the toggle's stop step and the one-shot automation path.
  ///
  /// Server-side force-process is the wrong tool here: it processes whichever
  /// in-progress conversation the backend's pointer names, which can be another
  /// device's empty stub while this device's segments are still in flight.
  /// `finishConversation()` closes this app's own stream, so the backend processes
  /// exactly the conversation we recorded; its server id reaches the local session row
  /// via the memory_created binding (or API reconciliation), and that id is what gets filed.
  private func fileInProgressConversationAsIdea() async throws -> IdeaCaptureOutcome {
    guard isTranscribing, let sessionId = currentSessionId else {
      log("idea-capture: not recording on this device; not filing")
      return .nothing
    }
    // On-device STT emits segments in ~10s windows (and cloud STT has a couple of
    // seconds of latency), so a short idea can have zero in-memory segments at the
    // moment the user stops. Give the in-flight window a chance to land first.
    var waitedNanoseconds: UInt64 = 0
    while totalSegmentCount == 0, speakerSegments.isEmpty, waitedNanoseconds < 12_000_000_000 {
      try? await Task.sleep(nanoseconds: 500_000_000)
      waitedNanoseconds += 500_000_000
    }
    guard totalSegmentCount > 0 || !speakerSegments.isEmpty else {
      log("idea-capture: nothing recorded on this device; not filing")
      return .nothing
    }
    if case .error(let message) = await finishConversation() {
      // The recording was still closed and queued; only the restart failed.
      log("idea-capture: finishConversation reported: \(message)")
    }
    guard let folderId = await ensureIdeaFolder() else {
      log("idea-capture: no Ideas folder, leaving conversation in place")
      return .savedLoose
    }
    if let conversationId = await ideaConversationId(
      sessionId: sessionId, attempts: 30, delayNanoseconds: 1_000_000_000)
    {
      try await fileIdeaConversation(conversationId, folderId: folderId)
      return .savedToIdeas
    }
    // Backend is still processing; finish the filing once the conversation id binds.
    log("idea-capture: conversation id for session \(sessionId) not bound yet, filing in background")
    Task { [weak self] in
      guard let self = self else { return }
      guard
        let conversationId = await self.ideaConversationId(
          sessionId: sessionId, attempts: 36, delayNanoseconds: 5_000_000_000)
      else {
        log("idea-capture: gave up waiting for the conversation id of session \(sessionId)")
        return
      }
      do {
        try await self.fileIdeaConversation(conversationId, folderId: folderId)
        await self.loadConversations()
      } catch {
        logError("idea-capture: background filing failed", error: error)
      }
    }
    return .savedToIdeas
  }

  /// Move the conversation into the Ideas folder, reprocessing it first if the backend's
  /// discard heuristic dropped a short capture (discarded conversations are hidden from
  /// folder listings).
  private func fileIdeaConversation(_ conversationId: String, folderId: String) async throws {
    if let conversation = try? await APIClient.shared.getConversation(id: conversationId),
      conversation.discarded
    {
      log("idea-capture: conversation \(conversationId) was discarded, reprocessing")
      _ = try? await APIClient.shared.reprocessConversation(conversationId: conversationId)
    }
    _ = try await APIClient.shared.moveConversationToFolder(
      conversationId: conversationId, folderId: folderId)
    log("idea-capture: filed conversation \(conversationId) under Ideas")
  }

  /// Poll the local session row until its backend conversation id binds.
  private func ideaConversationId(
    sessionId: Int64, attempts: Int, delayNanoseconds: UInt64
  ) async -> String? {
    for attempt in 0..<attempts {
      if attempt > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
      if let record = try? await TranscriptionStorage.shared.getSession(id: sessionId),
        let backendId = record.backendId, !backendId.isEmpty
      {
        return backendId
      }
    }
    return nil
  }

  private func showIdeaCaptureResultToast(_ outcome: IdeaCaptureOutcome) {
    switch outcome {
    case .nothing:
      IdeaCaptureToast.shared.show(
        symbol: "mic.slash", title: "Nothing captured",
        message: "No speech was recorded for this idea.")
    case .savedToIdeas:
      IdeaCaptureToast.shared.show(
        symbol: "lightbulb.fill", title: "Idea captured",
        message: "Saved to your Ideas folder. Tap to open.",
        onTap: { AppDelegate.shared?.revealIdeaFolder() })
    case .savedLoose:
      IdeaCaptureToast.shared.show(
        symbol: "lightbulb.fill", title: "Idea captured",
        message: "Saved to your conversations.")
    }
  }

  /// Toggle entry point: start a session, or stop and file one.
  ///
  /// Transitions hold multi-second network calls. Every click records the state the
  /// user wants (the opposite of what the UI showed when they clicked) and a single
  /// runner loop converges to the latest desired state once the in-flight transition
  /// finishes, so a click that lands mid-transition is applied instead of dropped.
  func toggleIdeaCapture() async {
    ideaCaptureDesiredActive = !isIdeaCaptureActive
    guard !ideaCaptureTransitionRunning else { return }
    ideaCaptureTransitionRunning = true
    defer { ideaCaptureTransitionRunning = false }
    while let desired = ideaCaptureDesiredActive {
      ideaCaptureDesiredActive = nil
      guard desired != isIdeaCaptureActive else { continue }
      if desired {
        await startIdeaCapture()
      } else {
        await stopIdeaCaptureAndFile()
      }
    }
  }

  /// Begin a session. Turns the mic on (remembering its prior mode) and cuts a clean
  /// boundary so the idea is isolated from anything recorded before.
  func startIdeaCapture() async {
    guard !ideaCaptureBusy, !isIdeaCaptureActive else { return }
    ideaCaptureBusy = true
    defer { ideaCaptureBusy = false }

    if AppState.isPaywalledEffective {
      NotificationCenter.default.post(
        name: .showUsageLimitPopup, object: nil, userInfo: ["reason": "trial_expired"])
      return
    }

    // Flip state and confirm before the mic spin-up and the boundary-cutting network
    // call so the click registers instantly.
    isIdeaCaptureActive = true
    NotificationCenter.default.post(name: .ideaCaptureStateChanged, object: nil)
    IdeaCaptureToast.shared.show(
      symbol: "record.circle.fill", title: "Recording idea",
      message: "Click the Stop Idea control in the sidebar or menu when you're done.")

    // Only Meetings keeps the mic paused between calls, so the session needs Always.
    let priorMode = ideaCaptureMicControl.mode()
    audioRecordingModeBeforeIdeaCapture = priorMode
    if priorMode != .always {
      ideaCaptureMicControl.setMode(.always)
    }
    // Close this device's in-progress conversation so the idea starts fresh.
    // finishConversation() skips the rotation itself when nothing has been recorded.
    if isTranscribing {
      _ = await finishConversation()
    }
  }

  /// Stop the session, file what was recorded under "Ideas", and restore the mic to
  /// its pre-session mode.
  func stopIdeaCaptureAndFile() async {
    guard !ideaCaptureBusy, isIdeaCaptureActive else { return }
    ideaCaptureBusy = true
    defer { ideaCaptureBusy = false }

    isIdeaCaptureActive = false
    NotificationCenter.default.post(name: .ideaCaptureStateChanged, object: nil)
    IdeaCaptureToast.shared.show(
      symbol: "hourglass", title: "Saving idea", message: "One moment.", autoDismiss: false)

    do {
      let outcome = try await fileInProgressConversationAsIdea()
      restoreMicAfterIdeaCapture()
      showIdeaCaptureResultToast(outcome)
      if outcome != .nothing {
        await loadConversations()
      }
    } catch {
      logError("idea-capture: stop/file failed", error: error)
      restoreMicAfterIdeaCapture()
      IdeaCaptureToast.shared.show(
        symbol: "exclamationmark.triangle.fill", title: "Couldn't save idea",
        message: "Something went wrong. Please try again.")
    }
  }

  /// If the session changed the recording mode, put it back (unless the user changed
  /// it again mid-session).
  private func restoreMicAfterIdeaCapture() {
    defer { audioRecordingModeBeforeIdeaCapture = nil }
    guard let priorMode = audioRecordingModeBeforeIdeaCapture, priorMode != .always,
      ideaCaptureMicControl.mode() == .always
    else { return }
    ideaCaptureMicControl.setMode(priorMode)
  }

  /// One-shot capture of the current in-progress conversation (automation bridge).
  /// `notify` shows confirmation toasts; the test path passes `false`.
  func captureCurrentConversationAsIdea(notify: Bool = true) async {
    guard !ideaCaptureBusy else { return }
    ideaCaptureBusy = true
    defer { ideaCaptureBusy = false }
    if notify {
      IdeaCaptureToast.shared.show(
        symbol: "hourglass", title: "Capturing idea",
        message: "Saving what's being recorded.", autoDismiss: false)
    }
    do {
      let outcome = try await fileInProgressConversationAsIdea()
      if notify {
        if case .nothing = outcome {
          IdeaCaptureToast.shared.show(
            symbol: "mic.slash", title: "Nothing to capture yet",
            message:
              "Turn on \(DesktopRecordingControlCopy.microphoneTitle) first. There's no active conversation."
          )
        } else {
          showIdeaCaptureResultToast(outcome)
        }
      }
      if outcome != .nothing {
        await loadConversations()
      }
    } catch {
      logError("idea-capture: capture failed", error: error)
      if notify {
        IdeaCaptureToast.shared.show(
          symbol: "exclamationmark.triangle.fill", title: "Couldn't capture idea",
          message: "Something went wrong. Please try again.")
      }
    }
  }
}
