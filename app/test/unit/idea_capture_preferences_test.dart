import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/capture_provider.dart';

// idea-capture: the press & hold action + Ideas folder cache must persist and
// default so the pendant hold gesture captures ideas out of the box.
void main() {
  group('Idea capture preferences', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    test('hold action defaults to capture idea (0)', () {
      expect(SharedPreferencesUtil().holdAction, CaptureProvider.holdActionCaptureIdea);
      expect(SharedPreferencesUtil().holdAction, 0);
    });

    test('hold action persists when remapped', () {
      SharedPreferencesUtil().holdAction = CaptureProvider.holdActionProcess;
      expect(SharedPreferencesUtil().holdAction, CaptureProvider.holdActionProcess);

      SharedPreferencesUtil().holdAction = CaptureProvider.holdActionNone;
      expect(SharedPreferencesUtil().holdAction, CaptureProvider.holdActionNone);
    });

    test('ideas folder id defaults empty and round-trips', () {
      expect(SharedPreferencesUtil().ideaFolderId, '');

      SharedPreferencesUtil().ideaFolderId = 'folder-abc';
      expect(SharedPreferencesUtil().ideaFolderId, 'folder-abc');
    });
  });
}
