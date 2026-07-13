import AVFoundation
import Combine
import OmiSupport
@preconcurrency import ObjectiveC
import SwiftUI
import UserNotifications

enum SystemAudioPermissionStatus: String {
  case unknown
  case granted
  case denied
  case unsupported

  /// Map a capture-start failure to an honest permission status. A TCC denial
  /// manifests as the tap failing to create or the device failing to start;
  /// format/converter/aggregate failures are provably NOT permission problems
  /// and must not claim a denial.
  @available(macOS 14.4, *)
  static func classify(captureError error: Error) -> SystemAudioPermissionStatus {
    guard let captureError = error as? SystemAudioCaptureService.SystemAudioCaptureError else {
      return .unknown
    }
    switch captureError {
    case .tapCreationFailed, .deviceStartFailed:
      return .denied
    case .aggregateDeviceFailed, .ioProcCreationFailed, .formatError, .converterCreationFailed:
      return .unknown
    case .unsupportedOS:
      return .unsupported
    }
  }
}

/// Translation from backend (e.g., Japanese speech translated to English)
struct SegmentTranslation: Identifiable {
  var id: String { lang }
  let lang: String
  let text: String
}

/// Speaker segment for diarized transcription
struct SpeakerSegment: Identifiable {
  /// Stable identity — uses backend segment ID when available, otherwise speaker + start time
  var id: String { segmentId ?? "\(speaker)-\(start)" }
  var segmentId: String?   // Backend-assigned UUID
  var speaker: Int
  var text: String
  var start: Double
  var end: Double
  var isUser: Bool = false
  var personId: String?    // Backend-assigned person ID from speaker identification
  var translations: [SegmentTranslation] = []
}

/// Result of finalizing a conversation
enum FinishConversationResult {
  case saved
  case discarded
  case error(String)
}

enum DesktopConversationMatchPolicy {
  /// Backend and local clocks can differ slightly around WebSocket close/reconnect.
  static let startedAtTolerance: TimeInterval = 10
  static let cloudReconciliationStatuses: [ConversationStatus] = [.inProgress, .processing, .completed]

  static func matchesDesktopConversation(
    startedAt conversationStartedAt: Date?,
    source: ConversationSource?,
    sessionStartedAt: Date
  ) -> Bool {
    guard let conversationStartedAt else { return false }
    guard source == .desktop else { return false }
    return abs(conversationStartedAt.timeIntervalSince(sessionStartedAt)) < startedAtTolerance
  }

  static func memoryEventMatchesFinishedSession(
    _ memory: [String: Any]?,
    sessionStartedAt: Date
  ) -> Bool {
    guard let memory else { return false }

    // Older backend lifecycle events may omit source; accept missing source for
    // compatibility, but reject an explicit non-desktop source.
    if let source = memory["source"] as? String, source != "desktop" {
      return false
    }

    guard let memoryStartedAt = parseMemoryEventDate(memory["started_at"] ?? memory["startedAt"]) else {
      return false
    }

    return abs(memoryStartedAt.timeIntervalSince(sessionStartedAt)) < startedAtTolerance
  }

  static func shouldBindConversationSession(
    incomingBackendId: String,
    expectedBackendId: String? = nil,
    activeBackendId: String?,
    ignoredRotatedBackendIds: Set<String>
  ) -> Bool {
    guard !incomingBackendId.isEmpty else { return false }
    if let expectedBackendId, !expectedBackendId.isEmpty, incomingBackendId != expectedBackendId {
      return false
    }
    if let activeBackendId, !activeBackendId.isEmpty {
      return incomingBackendId == activeBackendId
    }
    if ignoredRotatedBackendIds.contains(incomingBackendId) {
      return false
    }
    return true
  }

  /// Identified listen sessions may only consume lifecycle events produced by
  /// their own recording. Older backend versions omit `recording_session_id`,
  /// so the matching conversation id remains the compatibility proof.
  static func lifecycleEventBelongsToRecording(
    memoryId: String,
    recordingSessionId: String?,
    expectedBackendId: String?
  ) -> Bool {
    guard let expectedBackendId, !expectedBackendId.isEmpty else { return true }
    guard memoryId == expectedBackendId else { return false }
    return recordingSessionId == nil || recordingSessionId == expectedBackendId
  }

  static func canCompleteBoundBackendConversation(
    id conversationId: String,
    boundBackendId: String,
    status: ConversationStatus,
    source: ConversationSource?
  ) -> Bool {
    conversationId == boundBackendId && source == .desktop && status != .inProgress
  }

  static func shouldFinalizeTimestampMatchedConversation(status: ConversationStatus) -> Bool {
    status == .inProgress
  }

  static func canCompleteTimestampMatchedConversation(
    status: ConversationStatus,
    source: ConversationSource?
  ) -> Bool {
    source == .desktop && status != .inProgress
  }

  static func canForceProcessBoundCloudSession(
    capturedBackendId: String?,
    persistedBackendId: String?
  ) -> Bool {
    guard let capturedBackendId, !capturedBackendId.isEmpty else { return false }
    return persistedBackendId == capturedBackendId
  }

  static func parseMemoryEventDate(_ value: Any?) -> Date? {
    if let date = value as? Date {
      return date
    }
    guard let string = value as? String else {
      return nil
    }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: string) {
      return date
    }

    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)
  }
}

@MainActor
class AppState: ObservableObject {
  /// Weak reference to the current AppState instance, set on init.
  /// Used by background services (e.g. TranscriptionRetryService) to check recording state.
  static weak var current: AppState?

  @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false

  // Transcription state
  @Published var isTranscribing = false
  /// A terminal live-STT failure reported by `/v4/listen`. Audio capture can
  /// continue into the WAL while the transport reconnects, so this stays
  /// visible until the backend is ready or the active session is reset.
  @Published var transcriptionServiceError: String?
  /// Monotonically increasing counter — incremented each time a new recording starts.
  /// Used to detect if a new recording began during the post-stop force-process delay.
  var recordingGeneration: UInt64 = 0
  @Published var isSavingConversation = false
  // currentTranscript is internal-only (not observed by views), so no @Published needed
  var currentTranscript: String = ""
  @Published var hasMicrophonePermission = false
  @Published var hasSystemAudioPermission = false
  @Published var systemAudioPermissionStatus: SystemAudioPermissionStatus = .unknown
  @Published var isSystemAudioSupported = false

  // Audio source (microphone or BLE device)
  @Published var audioSource: AudioSource = .microphone
  /// Tracks the source for the current recording (for API tagging)
  var currentConversationSource: ConversationSource = .desktop

  /// Guards against re-entering the silent-mic fallback path multiple times in a single session.
  /// The user-visible banner lives in `SilentMicNoticeMonitor.shared`.
  var silentMicFallbackInProgress: Bool = false

  // Audio levels moved to AudioLevelMonitor to avoid triggering global re-renders
  // Access via AudioLevelMonitor.shared.microphoneLevel / .systemLevel
  var microphoneAudioLevel: Float { AudioLevelMonitor.shared.microphoneLevel }
  var systemAudioLevel: Float { AudioLevelMonitor.shared.systemLevel }

  // Recording timer moved to RecordingTimer to avoid triggering global re-renders
  // Access via RecordingTimer.shared.duration
  var recordingDuration: TimeInterval { RecordingTimer.shared.duration }

  var hasActiveConversationFilters: Bool {
    showStarredOnly || selectedDateFilter != nil || selectedFolderId != nil
  }

  // Live speaker segments moved to LiveTranscriptMonitor to avoid triggering global re-renders
  // Access via LiveTranscriptMonitor.shared.segments
  var liveSpeakerSegments: [SpeakerSegment] { LiveTranscriptMonitor.shared.segments }

  // Conversation state
  @Published var conversations: [ServerConversation] = []
  @Published var isLoadingConversations: Bool = false
  @Published var conversationsError: String? = nil
  @Published var totalConversationsCount: Int? = nil  // Unfiltered total count for dashboard metrics.
  @Published var filteredConversationsCount: Int? = nil  // Count matching the active conversations filters.
  let conversationRepository = ConversationRepository()

  // Conversation filters
  @Published var showStarredOnly: Bool = false
  @Published var selectedDateFilter: Date? = nil
  @Published var selectedFolderId: String? = nil

  // Folders
  @Published var folders: [Folder] = []
  @Published var isLoadingFolders: Bool = false

  // People (speaker voice profiles)
  @Published var people: [Person] = []
  var peopleById: [String: Person] {
    // Last-write-wins: the API can return duplicate person ids.
    Dictionary(lastWriteWins: people.map { ($0.id, $0) })
  }

  /// Maps live speaker IDs to person IDs during recording (cleared on finalize)
  @Published var liveSpeakerPersonMap: [Int: String] = [:]

  // Permission states for onboarding
  @Published var hasNotificationPermission = false
  @Published var notificationAlertStyle: UNAlertStyle = .none  // .none, .banner, or .alert
  @Published var hasScreenRecordingPermission = false
  @Published var hasBluetoothPermission = false

  // Track last notification settings for change detection (avoid duplicate analytics)
  var lastNotificationAuthStatus: String?
  var lastNotificationAlertStyle: String?
  var lastNotificationSoundEnabled: Bool?
  var lastNotificationBadgeEnabled: Bool?
  @Published var isScreenCaptureKitBroken = false  // Capture engine issue; not the source of permission truth
  @Published var isScreenRecordingStale = false  // Deprecated: no longer inferred from capture failures
  var screenRecordingGrantAttempts = 0  // Track how many times user clicked Grant without success
  @Published var hasAutomationPermission = false
  @Published var automationPermissionError: OSStatus = 0  // Non-zero when check fails unexpectedly (e.g. -600 procNotFound)
  var isCheckingAutomationPermission = false  // Prevent concurrent checks (retry path has a 1s sleep)
  @Published var hasAccessibilityPermission = false
  @Published var isAccessibilityBroken = false  // TCC says yes but AX calls actually fail (common after macOS updates/app re-signs)
  @Published var hasFullDiskAccess = false

  /// Usage-limit popup state. Set by `triggerUsageLimitPopup(reason:)` when the
  /// user hits a free-tier cap (transcription minutes, monthly chat messages, etc).
  /// The popup is mounted as an overlay in `DesktopHomeView` and is closable.
  @Published var showUsageLimitPopup: Bool = false
  @Published var usageLimitReason: String = ""

  /// True once the backend has told us this desktop user is past their trial
  /// (e.g. via the `freemium_threshold_reached` listen-WS event). When true,
  /// every $-incurring toggle on the desktop client should refuse to enable
  /// and show the paywall popup instead. Stays sticky until the app restarts
  /// or the user successfully reactivates (chat-quota allows / paid plan).
  ///
  /// Mirrored to UserDefaults `desktop_isPaywalled` so non-AppState singletons
  /// (e.g. `ProactiveAssistantsPlugin`) can synchronously gate without holding
  /// an AppState reference.
  @Published var isPaywalled: Bool = false {
    didSet { UserDefaults.standard.set(isPaywalled, forKey: "desktop_isPaywalled") }
  }

  /// Trial metadata from `/v1/users/me/trial`. Updated every 60s.
  @Published var trialMetadata: TrialMetadataResponse?

  var trialRefreshTimer: Timer?

  /// Trigger the monthly-limit popup. Safe to call repeatedly — SwiftUI's
  /// `@Published` dedupes identical-value writes automatically.
  let servicesCoordinator = AppServicesCoordinator()

  var audioCaptureService: AudioCaptureService? {
    get { servicesCoordinator.audioCaptureService }
    set { servicesCoordinator.audioCaptureService = newValue }
  }
  var transcriptionService: TranscriptionService? {
    get { servicesCoordinator.transcriptionService }
    set { servicesCoordinator.transcriptionService = newValue }
  }
  var systemAudioCaptureService: Any? {
    get { servicesCoordinator.systemAudioCaptureService }
    set { servicesCoordinator.systemAudioCaptureService = newValue }
  }
  var audioMixer: AudioMixer? {
    get { servicesCoordinator.audioMixer }
    set { servicesCoordinator.audioMixer = newValue }
  }
  var meetingDetector: MeetingDetector? {
    get { servicesCoordinator.meetingDetector }
    set { servicesCoordinator.meetingDetector = newValue }
  }
  var captureGateInFlight = false
  var captureReconcilePending = false
  var pendingCoreAudioCaptureRecoveryReason: String?
  var meetingEndFinalizationInProgress = false
  @Published var isAwaitingMeeting = false

  var effectiveSystemAudioMode: AssistantSettings.SystemAudioCaptureMode {
    if UserDefaults.standard.bool(forKey: "disableSystemAudioCapture") { return .never }
    return AssistantSettings.shared.systemAudioCaptureMode
  }
  var vadGateService: VADGateService? {
    get { servicesCoordinator.vadGateService }
    set { servicesCoordinator.vadGateService = newValue }
  }
  var localMicService: LocalTranscriptionService? {
    get { servicesCoordinator.localMicService }
    set { servicesCoordinator.localMicService = newValue }
  }
  var localSystemService: LocalTranscriptionService? {
    get { servicesCoordinator.localSystemService }
    set { servicesCoordinator.localSystemService = newValue }
  }
  var sttSession = STTSessionState()

  static let isAppleSilicon: Bool = {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
      return value == 1
    }
    return false
  }()

  var speakerSegments: [SpeakerSegment] = []
  let maxInMemorySegments = 200
  var totalSegmentCount = 0
  var totalWordCount = 0

  var recordingStartTime: Date?
  var recordingInputDeviceName: String?
  var maxRecordingTimer: Timer? {
    get { servicesCoordinator.maxRecordingTimer }
    set { servicesCoordinator.maxRecordingTimer = newValue }
  }
  let maxRecordingDuration: TimeInterval = 4 * 60 * 60
  var notificationHealthTimer: Timer? {
    get { servicesCoordinator.notificationHealthTimer }
    set { servicesCoordinator.notificationHealthTimer = newValue }
  }

  var currentSessionId: Int64?
  /// True while a bridge-owned hermetic capture session is active (T2 E2E only).
  var automationCaptureTestSessionActive = false
  var currentBackendConversationId: String?
  /// The UUID created by desktop before opening an identified `/v4/listen` stream.
  /// In the current compatible protocol it is also the backend conversation id.
  var currentClientConversationId: String?
  var pendingBackendConversationId: String?
  var ignoredRotatedBackendConversationIds: Set<String> = []
  var finishedSessionId: Int64?
  var finishedClientConversationId: String?
  var finishedRecordingStartTime: Date?

  var willTerminateObserver: NSObjectProtocol? {
    get { servicesCoordinator.willTerminateObserver }
    set { servicesCoordinator.willTerminateObserver = newValue }
  }
  var willSleepObserver: NSObjectProtocol? {
    get { servicesCoordinator.willSleepObserver }
    set { servicesCoordinator.willSleepObserver = newValue }
  }
  var didWakeObserver: NSObjectProtocol? {
    get { servicesCoordinator.didWakeObserver }
    set { servicesCoordinator.didWakeObserver = newValue }
  }
  var screenLockedObserver: NSObjectProtocol? {
    get { servicesCoordinator.screenLockedObserver }
    set { servicesCoordinator.screenLockedObserver = newValue }
  }
  var screenUnlockedObserver: NSObjectProtocol? {
    get { servicesCoordinator.screenUnlockedObserver }
    set { servicesCoordinator.screenUnlockedObserver = newValue }
  }
  var screenCapturePermissionLostObserver: NSObjectProtocol? {
    get { servicesCoordinator.screenCapturePermissionLostObserver }
    set { servicesCoordinator.screenCapturePermissionLostObserver = newValue }
  }
  var screenCaptureKitBrokenObserver: NSObjectProtocol? {
    get { servicesCoordinator.screenCaptureKitBrokenObserver }
    set { servicesCoordinator.screenCaptureKitBrokenObserver = newValue }
  }
  var systemAudioCaptureModeObserver: NSObjectProtocol? {
    get { servicesCoordinator.systemAudioCaptureModeObserver }
    set { servicesCoordinator.systemAudioCaptureModeObserver = newValue }
  }
  var coreAudioCaptureRecoveryObserver: NSObjectProtocol? {
    get { servicesCoordinator.coreAudioCaptureRecoveryObserver }
    set { servicesCoordinator.coreAudioCaptureRecoveryObserver = newValue }
  }

  var wasTranscribingBeforeSleep = false
  var lastScreenLockTime: Date?
  var lastScreenUnlockTime: Date?
  var buttonStreamTask: Task<Void, Never>? {
    get { servicesCoordinator.buttonStreamTask }
    set { servicesCoordinator.buttonStreamTask = newValue }
  }
  var bluetoothStateCancellable: AnyCancellable? {
    get { servicesCoordinator.bluetoothStateCancellable }
    set { servicesCoordinator.bluetoothStateCancellable = newValue }
  }

  init() {
    // Register as the current instance so background services can check recording state
    AppState.current = self
    conversationRepository.onSnapshot = { [weak self] snapshot in
      guard let self else { return }
      self.conversations = snapshot.conversations
      self.isLoadingConversations = snapshot.isLoading
      self.conversationsError = snapshot.error
      if self.hasActiveConversationFilters {
        self.filteredConversationsCount = snapshot.count
      } else {
        self.totalConversationsCount = snapshot.count
        self.filteredConversationsCount = nil
      }
    }

    // Restore paywall flag from prior session so toggles + auto-restart respect
    // it before any backend call has a chance to refresh state — but never for
    // a BYOK user (all four keys configured) or a user whose cached plan is
    // paid. The paid-plan carve-out fixes a popup-on-launch bug for Neo
    // subscribers grandfathered onto desktop by #7513: their last session
    // pre-grandfather wrote isPaywalled=true; without this clear, the next
    // launch shows the monthly-limit popup until fetchTrialMetadata returns
    // (~1-2s) AND callers that read UserDefaults synchronously
    // (ProactiveAssistantsPlugin, isPaywalledEffective) keep blocking until
    // didSet writes the new value. Only basic-tier users have a legitimate
    // pre-fetch paywalled state to preserve.
    // Freemium: the desktop trial paywall is disabled by default
    // (backend TRIAL_PAYWALL_ENABLED off), so a stale cached
    // `desktop_isPaywalled=true` from a pre-freemium session must not gate
    // anything on launch. Previously basic-tier users trusted that cache and
    // flashed the "monthly limit" popup until fetchTrialMetadata refreshed
    // (~1-2s) — and synchronous readers (ProactiveAssistantsPlugin,
    // isPaywalledEffective) blocked for that whole window. Always start
    // non-paywalled and let the backend's trial metadata be authoritative:
    // fetchTrialMetadata re-sets isPaywalled only if the backend genuinely
    // reports trial_expired (it won't under freemium).
    self.isPaywalled = false
    // didSet doesn't fire from init, so flush UserDefaults explicitly for
    // singletons that read the key directly.
    UserDefaults.standard.set(false, forKey: "desktop_isPaywalled")

    // Resolve beta/stable before loading backend URLs so beta releases use dev services.
    AppBuild.prepareUpdateChannelForBackendRouting()

    // Load API key from environment or .env file
    loadEnvironment()

    // Setup lifecycle observers for saving conversations
    setupLifecycleObservers()

    // Wire up memory pressure callback so ResourceMonitor can trim transcript state
    ResourceMonitor.shared.onMemoryPressureTrimTranscript = { [weak self] in
      self?.trimTranscriptStateForMemoryPressure()
    }

    // Listen for screen capture permission loss notifications
    screenCapturePermissionLostObserver = NotificationCenter.default.addObserver(
      forName: .screenCapturePermissionLost,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        let granted = ScreenCaptureService.checkPermission()
        self?.hasScreenRecordingPermission = ScreenRecordingPermissionPolicy.uiPermissionGranted(
          tccGranted: granted)
        self?.isScreenCaptureKitBroken = false  // Not broken, just lost
        self?.isScreenRecordingStale = false
        log("AppState: Screen recording permission lost notification; TCC granted=\(granted)")
      }
    }

    // Listen for ScreenCaptureKit broken notifications (TCC granted but SCK declined)
    screenCaptureKitBrokenObserver = NotificationCenter.default.addObserver(
      forName: .screenCaptureKitBroken,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        let granted = ScreenCaptureService.checkPermission()
        self?.hasScreenRecordingPermission = ScreenRecordingPermissionPolicy.uiPermissionGranted(
          tccGranted: granted)
        self?.isScreenCaptureKitBroken = ScreenRecordingPermissionPolicy.shouldMarkCaptureKitBroken(
          tccGranted: granted)
        self?.isScreenRecordingStale = false
        log("AppState: ScreenCaptureKit broken notification; TCC granted=\(granted)")
      }
    }

    // Check if system audio capture is supported (macOS 14.4+)
    // Note: hasSystemAudioPermission stays false until actually tested during onboarding
    if #available(macOS 14.4, *) {
      isSystemAudioSupported = true
    }

    // Note: Bluetooth subscription is initialized lazily via initializeBluetoothIfNeeded()
    // to avoid triggering the permission dialog before the user reaches the Bluetooth step

    // Start periodic notification health check (every 30 min)
    // Detects when macOS silently revokes notification authorization and auto-repairs
    notificationHealthTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) {
      [weak self] _ in
      DispatchQueue.main.async {
        self?.checkNotificationPermission()
      }
    }
  }

  /// Initialize Bluetooth manager and subscribe to state changes
  /// Call this only when the user reaches the Bluetooth onboarding step
  func initializeBluetoothIfNeeded() {
    guard bluetoothStateCancellable == nil else {
      log("Bluetooth already initialized, skipping")
      return
    }

    log("Initializing Bluetooth manager...")

    // Also initialize DeviceProvider's Bluetooth bindings
    DeviceProvider.shared.initializeBluetoothBindingsIfNeeded()

    // Subscribe to Bluetooth state changes for reactive permission updates
    bluetoothStateCancellable = BluetoothManager.shared.$bluetoothState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else { return }
        let oldValue = self.hasBluetoothPermission
        // poweredOn = ready to use, poweredOff = allowed but BT is off
        let newValue = state == .poweredOn || state == .poweredOff
        log(
          "BLUETOOTH_SUBSCRIPTION: state=\(BluetoothManager.shared.bluetoothStateDescription), stateRaw=\(state.rawValue), auth=\(BluetoothManager.shared.authorizationDescription), granted=\(newValue)"
        )
        if newValue != oldValue {
          log(
            "Bluetooth permission changed via subscription: \(oldValue) -> \(newValue), state=\(BluetoothManager.shared.bluetoothStateDescription)"
          )
          self.hasBluetoothPermission = newValue
        }
      }
  }

  /// Setup observers for app quit and system sleep to finalize conversations
  private func setupLifecycleObservers() {
    // App is about to quit
    willTerminateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      // Must run synchronously: AppKit exits before an enqueued Task would
      // ever execute. The observer is on the main queue, so this is safe.
      MainActor.assumeIsolated {
        if self.isTranscribing {
          log("App terminating - stopping transcription (backend handles conversation)")
          self.stopAudioCapture()
          // clearTranscriptionState finishes the DB session (finishSession: true) via its
          // own Task; the observer must stay synchronous, so we cannot await it here.
          self.clearTranscriptionState(
            finalizationReason: .userStop,
            runFinalizer: false,
            allowCloudForceProcess: false,
            finishSession: true
          )
        }
      }
    }

    // Computer is about to sleep
    willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        self.wasTranscribingBeforeSleep = self.isTranscribing
        if self.isTranscribing {
          log("Computer sleeping - stopping transcription (backend handles conversation)")
          let sessionId = self.currentSessionId
          self.stopAudioCapture()
          if let sessionId {
            try? await TranscriptionStorage.shared.finishSession(id: sessionId, reason: .userStop)
          }
          self.clearTranscriptionState(
            finalizationReason: .userStop,
            runFinalizer: false,
            allowCloudForceProcess: false,
            finishSession: false
          )
        }
        // Flush final sync changes before sleep
        await AgentSyncService.shared.stop()
      }
    }

    // Computer woke from sleep
    didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      log("System woke from sleep")
      NotificationCenter.default.post(name: .systemDidWake, object: nil)

      // Restart transcription if it was active before sleep
      Task { @MainActor in
        guard let self = self else { return }
        if self.wasTranscribingBeforeSleep && AssistantSettings.shared.transcriptionEnabled {
          log("System wake: Restarting transcription (was active before sleep)")
          // Brief delay to let audio subsystem settle after wake
          try? await Task.sleep(for: .seconds(2))
          if !self.isTranscribing {
            self.startTranscription()
          }
        }
        self.wasTranscribingBeforeSleep = false
      }
    }

    // Screen locked (debounced - macOS sometimes fires multiple times)
    screenLockedObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsLocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        let now = Date()
        if let lastTime = self?.lastScreenLockTime, now.timeIntervalSince(lastTime) < 1.0 {
          return  // Ignore duplicate within 1 second
        }
        self?.lastScreenLockTime = now
        log("Screen locked")
        NotificationCenter.default.post(name: .screenDidLock, object: nil)
      }
    }

    // Screen unlocked (debounced - macOS sometimes fires multiple times)
    screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        let now = Date()
        if let lastTime = self?.lastScreenUnlockTime, now.timeIntervalSince(lastTime) < 1.0 {
          return  // Ignore duplicate within 1 second
        }
        self?.lastScreenUnlockTime = now
        log("Screen unlocked")
        NotificationCenter.default.post(name: .screenDidUnlock, object: nil)
      }
    }

    // System Audio capture mode changed — re-apply the capture gate live if a recording is armed.
    systemAudioCaptureModeObserver = NotificationCenter.default.addObserver(
      forName: .systemAudioCaptureModeDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.reconcileCapture()
      }
    }

    coreAudioCaptureRecoveryObserver = NotificationCenter.default.addObserver(
      forName: .coreAudioCaptureRecoveryRequested,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let reason = note.userInfo?["reason"] as? String ?? "unspecified"
      Task { @MainActor in
        await self?.rebuildCoreAudioCaptureStack(reason: reason)
      }
    }
  }

  deinit {
    servicesCoordinator.removeLifecycleObservers()
  }

  // MARK: - Idea Capture (desktop quick-capture)

  // idea-capture: desktop has no pendant, so "Capture Idea" is a one-shot app
  // action. It force-processes the in-progress conversation (force_process
  // bypasses the backend short-conversation discard gate, so any length saves)
  // and files the result under a dedicated "Ideas" folder. Mirrors the mobile
  // CaptureProvider.forceProcessingCurrentConversation(asIdea: true) path; see
  // docs/developer/upstream-sync-and-backend-policy.mdx for the shared behavior.

  /// idea-capture: true while a start/stop idea-capture session is recording. Drives the
  /// menu-bar "Stop Idea Capture" state and the red status-bar indicator.
  @Published var isIdeaCaptureActive = false

  /// idea-capture: guards start/stop transitions (network calls) against double-clicks.
  private var ideaCaptureBusy = false

  /// idea-capture: the state the user last asked for via a toggle click. Set on every
  /// click, consumed by the runner loop in `toggleIdeaCapture`. Clicks that land while
  /// a transition's network tail is still running are recorded here and applied when
  /// the transition finishes, instead of being silently dropped by the busy guard.
  private var ideaCaptureDesiredActive: Bool?

  /// idea-capture: true while `toggleIdeaCapture`'s runner loop is draining
  /// `ideaCaptureDesiredActive`, so concurrent toggle calls just record intent.
  private var ideaCaptureTransitionRunning = false

  /// idea-capture: the mic (transcription) setting before a session began, so we can
  /// restore it on stop when the session turned the mic on itself.
  private var micEnabledBeforeIdeaCapture = false

  static let ideaFolderIdKey = "desktop_ideaFolderId"

  /// idea-capture: resolve (or lazily create) the "Ideas" destination folder, caching its id.
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
        description:
          "Captured ideas — intentional, fleeting thoughts saved from the pendant or app.",
        color: "#22C55E")
      UserDefaults.standard.set(created.id, forKey: Self.ideaFolderIdKey)
      return created.id
    } catch {
      logError("idea-capture: ensure folder failed", error: error)
      return nil
    }
  }

  /// idea-capture: outcome of finishing + filing the desktop's own recording.
  private enum IdeaCaptureOutcome { case nothing, savedToIdeas, savedLoose }

  /// idea-capture: finish the desktop's own recording and file the resulting
  /// conversation under "Ideas". Shared by the menu toggle's stop step and the
  /// one-shot automation path.
  ///
  /// POST /v1/conversations (force-process) is the wrong tool here: it processes
  /// whichever in-progress conversation the backend's Redis pointer names, which can
  /// be another device's empty stub while this device's segments are still in flight.
  /// The stub then gets filed and discarded (invisible in the folder), and the real
  /// idea lands in a later conversation that was never moved. finishConversation()
  /// closes this app's own stream, so the backend processes exactly the conversation
  /// we recorded; its server id reaches the local session row via the memory_created
  /// binding (or API reconciliation), and that id is what gets filed.
  private func fileInProgressConversationAsIdea() async throws -> IdeaCaptureOutcome {
    guard isTranscribing, let sessionId = currentSessionId else {
      log("idea-capture: not recording on this device; not filing")
      return .nothing
    }
    // On-device Parakeet emits segments in ~10s windows (and cloud STT has a couple
    // seconds of latency), so a short idea can have zero in-memory segments at the
    // moment the user stops. Give the in-flight window a chance to land before
    // concluding nothing was said.
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

  /// idea-capture: move the conversation into the Ideas folder, force-structuring it
  /// first if the backend's discard heuristic dropped a short capture (discarded
  /// conversations are hidden from folder listings).
  private func fileIdeaConversation(_ conversationId: String, folderId: String) async throws {
    if let conversation = try? await APIClient.shared.getConversation(id: conversationId),
      conversation.discarded
    {
      log("idea-capture: conversation \(conversationId) was discarded, reprocessing")
      try? await APIClient.shared.reprocessConversation(conversationId: conversationId)
    }
    try await APIClient.shared.moveConversationToFolder(
      conversationId: conversationId, folderId: folderId)
    log("idea-capture: filed conversation \(conversationId) under Ideas")
  }

  /// idea-capture: poll the local session row until its backend conversation id binds
  /// (memory_created event or API reconciliation, whichever lands first).
  private func ideaConversationId(
    sessionId: Int64, attempts: Int, delayNanoseconds: UInt64
  ) async -> String? {
    for attempt in 0..<attempts {
      if attempt > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
      if let record = try? await TranscriptionStorage.shared.getSession(id: sessionId),
        let backendId = record.backendId
      {
        return backendId
      }
    }
    return nil
  }

  /// idea-capture: confirmation toast for a finished capture.
  private func showIdeaCaptureResultToast(_ outcome: IdeaCaptureOutcome) {
    switch outcome {
    case .nothing:
      IdeaCaptureToast.shared.show(
        symbol: "mic.slash", title: "Nothing captured",
        message: "No speech was recorded for this idea.")
    case .savedToIdeas:
      IdeaCaptureToast.shared.show(
        symbol: "lightbulb.fill", title: "Idea captured",
        message: "Saved to your Ideas folder — tap to open.",
        onTap: { AppDelegate.revealIdeaFolderHandler?() })
    case .savedLoose:
      IdeaCaptureToast.shared.show(
        symbol: "lightbulb.fill", title: "Idea captured",
        message: "Saved to your conversations.")
    }
  }

  /// idea-capture: toggle entry point — start a session, or stop & file one.
  ///
  /// Start/stop transitions hold multi-second network calls, during which the old code
  /// dropped further clicks on the floor (the busy guard returned silently). A user who
  /// clicked "Stop Idea Capture" right after starting saw nothing happen until they
  /// waited and clicked again. Instead, every click records the state the user wants
  /// (the opposite of what the UI showed when they clicked), and a single runner loop
  /// converges to the latest desired state once the in-flight transition finishes.
  /// Rapid repeat clicks on the same row coalesce into one transition.
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

  /// idea-capture: begin a session. Turns the mic on (remembering its prior state) and
  /// cuts a clean boundary so the idea is isolated from anything recorded before.
  func startIdeaCapture() async {
    guard !ideaCaptureBusy, !isIdeaCaptureActive else { return }
    ideaCaptureBusy = true
    defer { ideaCaptureBusy = false }

    if AppState.isPaywalledEffective {
      NotificationCenter.default.post(
        name: .showUsageLimitPopup, object: nil, userInfo: ["reason": "trial_expired"])
      return
    }

    // Flip state and confirm immediately so the click registers instantly — the menu
    // row flips to "Stop Idea Capture" in place and the toast appears now, before the
    // mic spin-up and the boundary-cutting network call below.
    isIdeaCaptureActive = true
    NotificationCenter.default.post(name: .ideaCaptureStateChanged, object: nil)
    IdeaCaptureToast.shared.show(
      symbol: "record.circle.fill", title: "Recording idea…",
      message: "Click the Stop Idea control in the sidebar or menu when you're done.")

    micEnabledBeforeIdeaCapture = AssistantSettings.shared.transcriptionEnabled
    if !AssistantSettings.shared.transcriptionEnabled {
      AssistantSettings.shared.transcriptionEnabled = true
      NotificationCenter.default.post(
        name: .toggleTranscriptionRequested, object: nil, userInfo: ["enabled": true])
    }
    // Close this device's in-progress conversation so the idea starts fresh.
    // (Server-side force-process could cut another device's conversation instead.)
    // finishConversation() skips the rotation itself when nothing has been recorded.
    if isTranscribing {
      _ = await finishConversation()
    }
  }

  /// idea-capture: stop the session, file what was recorded under "Ideas", and restore
  /// the mic to its pre-session state.
  func stopIdeaCaptureAndFile() async {
    guard !ideaCaptureBusy, isIdeaCaptureActive else { return }
    ideaCaptureBusy = true
    defer { ideaCaptureBusy = false }

    isIdeaCaptureActive = false
    NotificationCenter.default.post(name: .ideaCaptureStateChanged, object: nil)
    IdeaCaptureToast.shared.show(
      symbol: "hourglass", title: "Saving idea…", message: "One moment.", autoDismiss: false)

    do {
      let outcome = try await fileInProgressConversationAsIdea()
      restoreMicAfterIdeaCapture()
      showIdeaCaptureResultToast(outcome)
      await loadConversations()
    } catch {
      logError("idea-capture: stop/file failed", error: error)
      restoreMicAfterIdeaCapture()
      IdeaCaptureToast.shared.show(
        symbol: "exclamationmark.triangle.fill", title: "Couldn't save idea",
        message: "Something went wrong. Please try again.")
    }
  }

  /// idea-capture: if the session turned the mic on, turn it back off.
  private func restoreMicAfterIdeaCapture() {
    guard !micEnabledBeforeIdeaCapture, AssistantSettings.shared.transcriptionEnabled else { return }
    AssistantSettings.shared.transcriptionEnabled = false
    NotificationCenter.default.post(
      name: .toggleTranscriptionRequested, object: nil, userInfo: ["enabled": false])
  }

  /// idea-capture: one-shot capture of the current in-progress conversation (used by the
  /// automation bridge). `notify` shows confirmation toasts; the test path passes `false`.
  func captureCurrentConversationAsIdea(notify: Bool = true) async {
    guard !ideaCaptureBusy else { return }
    ideaCaptureBusy = true
    defer { ideaCaptureBusy = false }
    if notify {
      IdeaCaptureToast.shared.show(
        symbol: "hourglass", title: "Capturing idea…",
        message: "Saving what's being recorded.", autoDismiss: false)
    }
    do {
      let outcome = try await fileInProgressConversationAsIdea()
      if notify {
        if case .nothing = outcome {
          IdeaCaptureToast.shared.show(
            symbol: "mic.slash", title: "Nothing to capture yet",
            message:
              "Turn on \(DesktopRecordingControlCopy.microphoneTitle) first - there's no active conversation."
          )
        } else {
          showIdeaCaptureResultToast(outcome)
        }
      }
      await loadConversations()
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

extension Notification.Name {
  static let resetOnboardingRequested = Notification.Name("resetOnboardingRequested")
  /// Posted when the system wakes from sleep
  static let systemDidWake = Notification.Name("systemDidWake")
  /// Posted when the screen is locked
  static let screenDidLock = Notification.Name("screenDidLock")
  /// Posted when the screen is unlocked
  static let screenDidUnlock = Notification.Name("screenDidUnlock")
  /// Posted when screen capture permission is detected as lost
  static let screenCapturePermissionLost = Notification.Name("screenCapturePermissionLost")
  /// Posted when ScreenCaptureKit is broken (TCC granted but SCK declined)
  static let screenCaptureKitBroken = Notification.Name("screenCaptureKitBroken")
  /// Posted to show the "Try asking" popup centered over the full window
  static let showTryAskingPopup = Notification.Name("showTryAskingPopup")
  /// Posted (automation bridge) to open the inline chat on the redesigned Home
  static let homeStageOpenChat = Notification.Name("homeStageOpenChat")
  /// Posted (automation bridge) to toggle the Connect tray on the redesigned Home
  static let homeStageToggleConnect = Notification.Name("homeStageToggleConnect")
  /// Posted (automation bridge) to collapse the redesigned Home back to the hub
  static let homeStageClose = Notification.Name("homeStageClose")
  /// Posted (automation bridge) to send a query through the Home ask bar. userInfo["query"] = text.
  static let homeStageAsk = Notification.Name("homeStageAsk")
  /// Posted (automation bridge) to stage a file in the Home ask bar. userInfo["path"] = file path.
  static let homeStageAttach = Notification.Name("homeStageAttach")
  /// Posted to show the over-usage-limit popup. userInfo["reason"] = "transcription" | "chat" | "floating_bar".
  static let showUsageLimitPopup = Notification.Name("showUsageLimitPopup")
  /// Posted to navigate to Rewind settings
  static let navigateToRewindSettings = Notification.Name("navigateToRewindSettings")
  /// Posted to navigate to Rewind page (global hotkey: Cmd+Option+R)
  static let navigateToRewind = Notification.Name("navigateToRewind")
  /// Posted to navigate to Rewind page with notes panel expanded
  static let navigateToRewindNotes = Notification.Name("navigateToRewindNotes")
  /// Posted to expand the transcript/notes panel on the Rewind page
  static let expandRewindTranscript = Notification.Name("expandRewindTranscript")
  /// Posted to navigate to Device settings
  static let navigateToDeviceSettings = Notification.Name("navigateToDeviceSettings")
  /// Posted to navigate to Task Assistant settings (Developer Settings)
  static let navigateToTaskSettings = Notification.Name("navigateToTaskSettings")
  /// Posted to navigate to Ask Omi Floating Bar settings
  static let navigateToFloatingBarSettings = Notification.Name("navigateToFloatingBarSettings")
  /// Posted to navigate to AI Chat settings
  static let navigateToAIChatSettings = Notification.Name("navigateToAIChatSettings")
  /// Posted when a new Rewind frame is captured (for live frame count updates)
  static let rewindFrameCaptured = Notification.Name("rewindFrameCaptured")
  /// Posted when Rewind page finishes loading initial data
  static let rewindPageDidLoad = Notification.Name("rewindPageDidLoad")
  /// Posted when Conversations page finishes loading initial data
  static let conversationsPageDidLoad = Notification.Name("conversationsPageDidLoad")
  /// Posted when Tasks page finishes loading initial data
  static let tasksPageDidLoad = Notification.Name("tasksPageDidLoad")
  /// Posted when Focus page finishes loading initial data
  static let focusPageDidLoad = Notification.Name("focusPageDidLoad")
  /// Posted when Advice page finishes loading initial data
  static let insightPageDidLoad = Notification.Name("insightPageDidLoad")
  /// Posted when Apps page finishes loading initial data
  static let appsPageDidLoad = Notification.Name("appsPageDidLoad")
  /// Posted when a goal is auto-created by GoalGenerationService
  static let goalAutoCreated = Notification.Name("goalAutoCreated")
  /// Posted when a goal is completed (current_value >= target_value)
  static let goalCompleted = Notification.Name("goalCompleted")
  /// Posted to navigate to AI Chat page
  static let navigateToChat = Notification.Name("navigateToChat")
  static let navigateToTasks = Notification.Name("navigateToTasks")
  /// Posted by keyboard shortcuts to navigate sidebar. userInfo: ["rawValue": Int]
  static let navigateToSidebarItem = Notification.Name("navigateToSidebarItem")
  /// idea-capture: posted when a start/stop idea-capture session begins or ends, so the
  /// menu-bar item and status icon can reflect the active/idle state immediately.
  static let ideaCaptureStateChanged = Notification.Name("ideaCaptureStateChanged")
  /// Posted by Cmd+R to refresh all data (conversations, chat, tasks, memories)
  static let refreshAllData = Notification.Name("refreshAllData")
  /// Posted after a conversation is deleted so dependent views can prune local state.
  static let conversationDeleted = Notification.Name("conversationDeleted")
  /// Posted by the local desktop automation bridge to request semantic navigation.
  static let desktopAutomationNavigateRequested = Notification.Name(
    "desktopAutomationNavigateRequested")
  /// Posted by the local desktop automation bridge to open a specific conversation detail.
  static let desktopAutomationOpenConversationRequested = Notification.Name(
    "desktopAutomationOpenConversationRequested")
  /// Posted by the local desktop automation bridge to expand the transcript drawer.
  static let desktopAutomationShowConversationTranscriptRequested = Notification.Name(
    "desktopAutomationShowConversationTranscriptRequested")
  /// Posted when file indexing completes (userInfo: ["totalFiles": Int])
  static let fileIndexingComplete = Notification.Name("fileIndexingComplete")
  /// Posted from Settings to trigger the file indexing sheet
  static let triggerFileIndexing = Notification.Name("triggerFileIndexing")
  /// Posted from menu bar to toggle transcription (userInfo: ["enabled": Bool])
  static let toggleTranscriptionRequested = Notification.Name("toggleTranscriptionRequested")
}
