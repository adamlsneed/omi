/// One user-requested recording. The native inbox owns its durable checkpoints.
class WatchCapture {
  WatchCapture(Map<String, String> value)
      : id = value['id']!,
        owner = value['owner']!,
        destination = value['destination']!,
        path = value['path']!,
        createdAt =
            DateTime.fromMillisecondsSinceEpoch((double.parse(value['createdAt']!) * 1000).round(), isUtc: true),
        duration = double.parse(value['duration']!),
        transcript = value['transcript'] ?? '',
        conversationId = value['conversationId'] ?? '';

  final String id, owner, destination, path;
  final DateTime createdAt;
  final double duration;
  String transcript, conversationId;
}

class WatchCaptureFailure implements Exception {
  const WatchCaptureFailure(this.reason);
  final String reason;
}

abstract interface class WatchCaptureInbox {
  Future<List<WatchCapture>> pending();
  Future<void> checkpoint(WatchCapture capture);
  Future<void> saved(WatchCapture capture, String resultId);
  Future<void> failed(WatchCapture capture, String reason);
}

abstract interface class WatchCaptureDestination {
  Future<String> transcribe(WatchCapture capture);
  Future<String> createTask(WatchCapture capture);
  Future<String> createIdea(WatchCapture capture);
  Future<void> fileIdea(WatchCapture capture);
}

/// A single drain owns writes. Only the destination's verified result earns a
/// saved receipt; transcription and file transfer alone are insufficient.
class WatchCaptureWorker {
  WatchCaptureWorker({required this.inbox, required this.destination, required this.currentOwner});
  final WatchCaptureInbox inbox;
  final WatchCaptureDestination destination;
  final String Function() currentOwner;
  bool _busy = false;

  Future<void> drain() async {
    if (_busy) return;
    _busy = true;
    try {
      for (final capture in await inbox.pending()) {
        bool owned() => capture.owner.isNotEmpty && capture.owner == currentOwner();
        void requireOwner() {
          if (!owned()) throw const WatchCaptureFailure('account');
        }

        if (!owned()) continue;
        try {
          if (capture.transcript.isEmpty) {
            capture.transcript = (await destination.transcribe(capture)).trim();
            requireOwner();
            if (capture.transcript.isEmpty) throw const WatchCaptureFailure('no_speech');
            // Checkpoint before the first write so every retry uses the exact same text.
            await inbox.checkpoint(capture);
          }
          requireOwner();
          String resultId;
          if (capture.destination == 'task') {
            if (capture.transcript.length > 4096) throw const WatchCaptureFailure('too_long');
            resultId = await destination.createTask(capture);
          } else if (capture.destination == 'idea') {
            if (capture.conversationId.isEmpty) {
              capture.conversationId = await destination.createIdea(capture);
              requireOwner();
              if (capture.conversationId.isEmpty) throw const WatchCaptureFailure('invalid_receipt');
              await inbox.checkpoint(capture);
            }
            requireOwner();
            await destination.fileIdea(capture);
            resultId = capture.conversationId;
          } else {
            throw const WatchCaptureFailure('invalid_destination');
          }
          requireOwner();
          if (resultId.isEmpty) throw const WatchCaptureFailure('invalid_receipt');
          await inbox.saved(capture, resultId);
        } catch (error) {
          if (owned()) {
            await inbox.failed(capture, error is WatchCaptureFailure ? error.reason : 'save_failed');
          }
        }
      }
    } finally {
      _busy = false;
    }
  }
}
