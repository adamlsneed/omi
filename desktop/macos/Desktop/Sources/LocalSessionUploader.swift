import Foundation

/// Uploads a finished transcription session's locally stored segments to the backend,
/// creating the conversation server-side and binding its id to the local session.
///
/// On-device (Parakeet) sessions never stream segments to /v4/listen, so the backend only
/// learns about them through this upload. Used right after a local session stops
/// (AppState.uploadLocalSession) and by TranscriptionRetryService to recover sessions whose
/// conversation never reached the backend (4-hour rotation, crash recovery, failed upload).
enum LocalSessionUploader {

  /// Upload the session's segments via POST /v1/conversations/from-segments and mark the
  /// local session completed with the returned conversation id.
  /// - Returns: the backend conversation id, or nil when the session is missing or has no
  ///   segments (nothing to upload).
  static func uploadSession(_ sessionId: Int64) async throws -> String? {
    guard let bundle = try await TranscriptionStorage.shared.getSessionWithSegments(id: sessionId)
    else { return nil }
    let session = bundle.session
    guard !bundle.segments.isEmpty else { return nil }

    let raw: [APIClient.UploadSegment] = bundle.segments.map { seg in
      APIClient.UploadSegment(
        text: seg.text,
        speaker: seg.speakerLabel ?? String(format: "SPEAKER_%02d", seg.speaker),
        speaker_id: seg.speaker,
        is_user: seg.isUser,
        person_id: seg.personId,
        start: seg.startTime,
        end: seg.endTime
      )
    }
    // Merge consecutive same-speaker segments to stay under the backend's 500-segment cap
    // (Parakeet emits ~1 segment per 10s window).
    var merged: [APIClient.UploadSegment] = []
    for seg in raw {
      if let last = merged.last, last.speaker_id == seg.speaker_id {
        merged[merged.count - 1] = APIClient.UploadSegment(
          text: last.text + " " + seg.text, speaker: last.speaker, speaker_id: last.speaker_id,
          is_user: last.is_user, person_id: last.person_id, start: last.start, end: seg.end)
      } else {
        merged.append(seg)
      }
    }
    if merged.count > 500 {
      log("LocalSessionUploader: Session \(sessionId) has \(merged.count) segments (>500), truncating")
      merged = Array(merged.prefix(500))
    }
    // The backend validates segments strictly (start >= 0, end > start). Local Parakeet
    // timestamps can carry float-epsilon negatives and zero-length or inverted sub-window
    // artifacts, and merging can inherit them, so clamp just before upload.
    merged = merged.map { seg in
      let start = max(0, seg.start)
      let end = max(seg.end, start + 0.01)
      return APIClient.UploadSegment(
        text: seg.text, speaker: seg.speaker, speaker_id: seg.speaker_id,
        is_user: seg.is_user, person_id: seg.person_id, start: start, end: end)
    }

    let iso = ISO8601DateFormatter()
    let request = APIClient.CreateConversationFromSegmentsRequest(
      transcript_segments: merged,
      source: "desktop",
      started_at: iso.string(from: session.startedAt),
      finished_at: session.finishedAt.map { iso.string(from: $0) },
      language: session.language,
      client_conversation_id: ConversationFinalizationService.localClientConversationId(
        session: session, sessionId: sessionId)
    )
    let response = try await APIClient.shared.createConversationFromSegments(request)
    try? await TranscriptionStorage.shared.markSessionCompleted(id: sessionId, backendId: response.id)
    log(
      "LocalSessionUploader: Uploaded session \(sessionId) → backend conversation \(response.id) (\(merged.count) segments)"
    )
    return response.id
  }
}
