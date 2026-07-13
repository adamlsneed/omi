import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BasedHardware endpoint defaults', () {
    test('frontend app-management and app streaming defaults do not fall back to local or fork URLs', () {
      final disallowed = <String>[
        'https://omi-backend.ngrok.app/',
        'https://api.omiapi.com/',
      ];

      final files = <String>[
        'lib/env/env.dart',
        'lib/providers/capture_provider.dart',
        'android/app/src/main/kotlin/com/friend/ios/batch/OmiBackgroundAudioStreamer.kt',
        'setup.sh',
        'setup/scripts/setup.ps1',
      ];

      for (final relativePath in files) {
        final contents = File(relativePath).readAsStringSync();
        for (final needle in disallowed) {
          expect(
            contents.contains(needle),
            isFalse,
            reason: '$relativePath must not default to $needle',
          );
        }
      }
    });

    test('web marketplace frontend defaults to the hosted BasedHardware API', () {
      final disallowed = <String>[
        'http://localhost:8000',
        'http://127.0.0.1:8787',
      ];

      final files = <String>[
        '../web/frontend/.env.template',
        '../web/frontend/src/constants/envConfig.ts',
        '../web/frontend/src/actions/apps/get-app-initialization-data.ts',
        '../web/frontend/src/actions/apps/submit-app.ts',
        '../web/frontend/src/actions/apps/generate-description.ts',
        '../web/frontend/src/actions/apps/upload-thumbnail.ts',
        '../web/frontend/src/app/my-apps/page.tsx',
      ];

      for (final relativePath in files) {
        final contents = File(relativePath).readAsStringSync();
        for (final needle in disallowed) {
          expect(
            contents.contains(needle),
            isFalse,
            reason: '$relativePath must not default to $needle',
          );
        }
      }
    });
  });
}
