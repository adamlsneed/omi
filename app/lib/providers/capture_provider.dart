import 'package:flutter/foundation.dart';

import 'package:omi/services/capture/capture_controller.dart';
import 'package:omi/services/capture/capture_external_actions.dart';

class CaptureProvider extends CaptureController {
  CaptureProvider({
    CaptureExternalActions? externalActions,
    @visibleForTesting Future<void> Function(bool paused)? recordingPauseRequesterForTesting,
  }) : super(
          externalActions: externalActions,
          recordingPauseRequesterForTesting: recordingPauseRequesterForTesting,
        );
}
