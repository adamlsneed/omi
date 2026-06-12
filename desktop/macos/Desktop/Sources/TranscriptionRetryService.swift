import Foundation

/// Background service for retrying failed transcription uploads
/// Runs a periodic timer to check for pending/failed sessions and attempt upload
class TranscriptionRetryService {
    static let shared = TranscriptionRetryService()

    private var retryTimer: Timer?
    private var isProcessing = false
    private let retryInterval: TimeInterval = 60  // Check every 60 seconds
    private let maxRetries = 5
    /// Leave sessions updated this recently alone: the app may still be uploading them
    /// itself (uploadLocalSession runs async right after a local session stops), and a
    /// concurrent reconcile upload would duplicate the conversation on the backend.
    private let recentSessionGracePeriod: TimeInterval = 120
    private var consecutiveDBFailures = 0
    private let maxConsecutiveDBFailures = 3

    /// Backoff gate for retries, without a retry-count cap: reconcileSession can upload a
    /// session's locally stored segments, so no session is ever terminally failed. The
    /// exponential backoff (2^retryCount minutes) alone bounds retry pressure.
    private func retryBackoffElapsed(_ session: TranscriptionSessionRecord) -> Bool {
        Date().timeIntervalSince(session.updatedAt) >= session.retryBackoffSeconds
    }

    private init() {}

    // MARK: - Service Lifecycle

    /// Start the retry service (call on app launch)
    func start() {
        guard retryTimer == nil else { return }

        log("TranscriptionRetryService: Starting retry timer (interval: \(retryInterval)s)")

        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.processRetryQueue()
            }
        }
    }

    /// Stop the retry service (call on app termination)
    func stop() {
        log("TranscriptionRetryService: Stopping")
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Recovery

    /// Recover pending transcriptions on app launch
    /// Call this after database initialization
    func recoverPendingTranscriptions() async {
        log("TranscriptionRetryService: Checking for pending transcriptions...")

        do {
            // First, find any crashed sessions (status = 'recording' from previous run)
            let crashedSessions = try await TranscriptionStorage.shared.getCrashedSessions()
            if !crashedSessions.isEmpty {
                log("TranscriptionRetryService: Found \(crashedSessions.count) crashed sessions")
                for session in crashedSessions {
                    // Skip sessions that are too recent - they might be actively recording
                    // (race condition: recovery runs before segments arrive)
                    let sessionAge = Date().timeIntervalSince(session.createdAt)
                    if sessionAge < 30 {
                        log("TranscriptionRetryService: Skipping recent session \(session.id!) (age: \(String(format: "%.1f", sessionAge))s)")
                        continue
                    }

                    // Check if session has segments - if not, delete it
                    let segmentCount = try await TranscriptionStorage.shared.getSegmentCount(sessionId: session.id!)
                    if segmentCount == 0 {
                        log("TranscriptionRetryService: Deleting empty crashed session \(session.id!)")
                        try await TranscriptionStorage.shared.deleteSession(id: session.id!)
                    } else {
                        // Mark as pending upload so it will be retried
                        log("TranscriptionRetryService: Marking crashed session \(session.id!) as pending upload (\(segmentCount) segments)")
                        try await TranscriptionStorage.shared.finishSession(id: session.id!)
                    }
                }
            }

            // Now process any pending sessions
            let pendingSessions = try await TranscriptionStorage.shared.getPendingUploadSessions()
            if !pendingSessions.isEmpty {
                log("TranscriptionRetryService: Found \(pendingSessions.count) pending sessions to reconcile")
                for session in pendingSessions {
                    await reconcileSession(session)
                }
            }

            // Recover sessions stuck in 'uploading' (app quit/crash during upload, or markSessionCompleted failed)
            let stuckUploadingSessions = try await TranscriptionStorage.shared.getStuckUploadingSessions(olderThan: 300)
            if !stuckUploadingSessions.isEmpty {
                log("TranscriptionRetryService: Found \(stuckUploadingSessions.count) stuck uploading sessions")
                for session in stuckUploadingSessions {
                    await recoverStuckSession(session)
                }
            }

            // Also check for failed sessions that can be retried. No retry cap here (or in
            // the periodic queue): reconcileSession can upload locally stored segments when
            // the backend never saw the conversation, so sessions that exhausted the old
            // cap are still recoverable.
            let failedSessions = try await TranscriptionStorage.shared.getFailedSessions(maxRetries: Int.max)
            if !failedSessions.isEmpty {
                log("TranscriptionRetryService: Found \(failedSessions.count) failed sessions to retry")
                for session in failedSessions {
                    if retryBackoffElapsed(session) {
                        await reconcileSession(session)
                    } else {
                        log("TranscriptionRetryService: Session \(session.id!) not ready for retry (backoff)")
                    }
                }
            }

            // Log stats
            let stats = try await TranscriptionStorage.shared.getStats()
            log("TranscriptionRetryService: Stats - total=\(stats.totalSessions), pending=\(stats.pendingCount), failed=\(stats.failedCount), completed=\(stats.completedCount)")

        } catch {
            logError("TranscriptionRetryService: Recovery failed", error: error)
        }
    }

    // MARK: - Retry Queue Processing

    /// Process the retry queue (called periodically by timer)
    private func processRetryQueue() async {
        // Skip if user is signed out (tokens are cleared)
        guard await AuthState.shared.isSignedIn else { return }
        guard !isProcessing else {
            log("TranscriptionRetryService: Already processing, skipping")
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            // Get pending sessions
            let pendingSessions = try await TranscriptionStorage.shared.getPendingUploadSessions()
            consecutiveDBFailures = 0 // DB query succeeded, reset counter

            for session in pendingSessions {
                await reconcileSession(session)
            }

            // Recover sessions stuck in 'uploading' for more than 5 minutes
            let stuckSessions = try await TranscriptionStorage.shared.getStuckUploadingSessions(olderThan: 300)
            for session in stuckSessions {
                await recoverStuckSession(session)
            }

            // Get failed sessions that are ready for retry (uncapped, backoff-gated; see
            // recoverPendingTranscriptions)
            let failedSessions = try await TranscriptionStorage.shared.getFailedSessions(maxRetries: Int.max)
            for session in failedSessions {
                if retryBackoffElapsed(session) {
                    await reconcileSession(session)
                }
            }

        } catch {
            consecutiveDBFailures += 1
            // Report to RewindDatabase for runtime corruption detection
            await RewindDatabase.shared.reportQueryError(error)
            if consecutiveDBFailures >= maxConsecutiveDBFailures {
                log("TranscriptionRetryService: \(consecutiveDBFailures) consecutive DB failures, stopping timer to avoid error flood")
                stop()
            } else {
                logError("TranscriptionRetryService: Queue processing failed (\(consecutiveDBFailures)/\(maxConsecutiveDBFailures))", error: error)
            }
        }
    }

    // MARK: - Stuck Session Recovery

    /// Recover a session stuck in 'uploading' — check if backend already has it before re-uploading
    private func recoverStuckSession(_ session: TranscriptionSessionRecord) async {
        guard let sessionId = session.id else { return }

        log("TranscriptionRetryService: Recovering stuck session \(sessionId)")

        // Check if the backend already has a conversation for this time window
        // (upload succeeded but markSessionCompleted failed silently)
        do {
            let finishedAt = session.finishedAt ?? session.startedAt.addingTimeInterval(1)
            let existing = try await APIClient.shared.getConversations(
                limit: 5,
                startDate: session.startedAt.addingTimeInterval(-2),
                endDate: finishedAt.addingTimeInterval(2)
            )

            // Look for a desktop conversation with matching started_at/finished_at
            if let match = existing.first(where: { conv in
                guard let convStarted = conv.startedAt, let convFinished = conv.finishedAt else { return false }
                guard conv.source == .desktop else { return false }
                return abs(convStarted.timeIntervalSince(session.startedAt)) < 5
                    && abs(convFinished.timeIntervalSince(finishedAt)) < 5
            }) {
                log("TranscriptionRetryService: Session \(sessionId) already exists on backend as \(match.id), marking completed")
                try await TranscriptionStorage.shared.markSessionCompleted(id: sessionId, backendId: match.id)
                return
            }
        } catch {
            log("TranscriptionRetryService: Could not check backend for session \(sessionId), will re-upload: \(error.localizedDescription)")
        }

        // No match found — mark as pending so it gets re-uploaded
        log("TranscriptionRetryService: Session \(sessionId) not found on backend, marking as pending upload")
        do {
            try await TranscriptionStorage.shared.finishSession(id: sessionId)
        } catch {
            logError("TranscriptionRetryService: Failed to mark session \(sessionId) as pending", error: error)
        }
    }

    // MARK: - Reconciliation

    /// Reconcile a pending session with the backend.
    /// Cloud-STT sessions stream segments to /v4/listen, so the backend usually already has
    /// the conversation: find it by timestamp and bind its id, no re-upload needed.
    /// On-device (Parakeet) sessions never reach the backend on their own. When the backend
    /// confirms it has no matching conversation, the locally stored segments are the only
    /// copy of the recording, so upload them to create the conversation (the same POST
    /// AppState.uploadLocalSession does right after a local session stops).
    private func reconcileSession(_ session: TranscriptionSessionRecord) async {
        guard let sessionId = session.id else { return }
        // Skip when signed out: backend queries would fail and burn retry attempts.
        guard await AuthState.shared.isSignedIn else { return }

        if Date().timeIntervalSince(session.updatedAt) < recentSessionGracePeriod {
            log("TranscriptionRetryService: Session \(sessionId) updated recently, waiting before reconcile")
            return
        }

        log("TranscriptionRetryService: Reconciling session \(sessionId) (retryCount: \(session.retryCount))")

        do {
            // Check if backend already has a conversation for this time window
            let finishedAt = session.finishedAt ?? session.startedAt.addingTimeInterval(1)
            let existing = try await APIClient.shared.getConversations(
                limit: 5,
                includeDiscarded: true,
                startDate: session.startedAt.addingTimeInterval(-5),
                endDate: finishedAt.addingTimeInterval(5)
            )
            if let match = existing.first(where: { conv in
                DesktopConversationMatchPolicy.matchesDesktopConversation(
                    startedAt: conv.startedAt,
                    source: conv.source,
                    sessionStartedAt: session.startedAt
                )
            }) {
                // Sub-10-second rotated sessions start within the match tolerance of their
                // neighbor, so the matched conversation can belong to the previous session.
                // If another local session already claims it, this session's segments exist
                // nowhere else: fall through and upload them instead of folding them away.
                let claimant = try await TranscriptionStorage.shared.getSessionByBackendId(match.id)
                if claimant == nil || claimant?.id == sessionId {
                    log("TranscriptionRetryService: Session \(sessionId) found on backend as \(match.id), marking completed")
                    try await TranscriptionStorage.shared.markSessionCompleted(id: sessionId, backendId: match.id)
                    return
                }
                log("TranscriptionRetryService: Backend match \(match.id) already bound to session \(claimant!.id!), not binding session \(sessionId)")
            }

            // The backend confirmed it has no matching conversation.
            // Do NOT call force-process here — it acts on the user's current in-progress
            // conversation which may belong to another device or a new recording session.
            // Force-process is only safe immediately after stopping (in AppState.stopTranscription).
            let segmentCount = try await TranscriptionStorage.shared.getSegmentCount(sessionId: sessionId)
            guard segmentCount > 0 else {
                // Nothing was recorded (silent session): nothing to recover, drop the row
                // like launch recovery does for empty crashed sessions.
                log("TranscriptionRetryService: Session \(sessionId) has no segments and no backend match, deleting")
                try await TranscriptionStorage.shared.deleteSession(id: sessionId)
                return
            }

            log("TranscriptionRetryService: No backend match for session \(sessionId), uploading \(segmentCount) local segments")
            try await TranscriptionStorage.shared.markSessionUploading(id: sessionId)
            if let backendId = try await LocalSessionUploader.uploadSession(sessionId) {
                log("TranscriptionRetryService: Session \(sessionId) uploaded as conversation \(backendId)")
            }

        } catch {
            logError("TranscriptionRetryService: Reconciliation failed for session \(sessionId)", error: error)
            try? await TranscriptionStorage.shared.incrementRetryCount(id: sessionId)
            try? await TranscriptionStorage.shared.markSessionFailed(
                id: sessionId, error: error.localizedDescription)

            // Fire error event when the standard retry budget is first exhausted
            if session.retryCount + 1 == maxRetries {
                await AnalyticsManager.shared.recordingError(
                    error: "Session \(sessionId) could not be reconciled after \(maxRetries) attempts")
            }
        }
    }

}
