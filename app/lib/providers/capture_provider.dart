import 'package:flutter/foundation.dart';

import 'package:omi/services/capture/capture_controller.dart';

class CaptureProvider extends CaptureController {
  CaptureProvider({
    super.externalActions,
    super.conversationLocationCapture,
    super.inProgressConversationLoader,
    super.audioCodecLoader,
    @visibleForTesting super.recordingPauseRequesterForTesting,
    super.microphonePermissionRequester,
    super.phoneMicBatchRecorder,
  });
}
