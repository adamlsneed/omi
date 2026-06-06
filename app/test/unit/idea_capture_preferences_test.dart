import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';

// idea-capture: the Ideas folder cache must persist so captured ideas are filed
// into the same folder across sessions. (The press & hold gesture itself is
// hardwired in firmware to idea-capture, so there is no app-side hold setting.)
void main() {
  group('Idea capture preferences', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    test('ideas folder id defaults empty and round-trips', () {
      expect(SharedPreferencesUtil().ideaFolderId, '');

      SharedPreferencesUtil().ideaFolderId = 'folder-abc';
      expect(SharedPreferencesUtil().ideaFolderId, 'folder-abc');
    });
  });
}
