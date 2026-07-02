import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';

// Pins the defaults and key mappings of fork-added SharedPreferencesUtil fields.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('Apple Reminders auto-export defaults to disabled until the user opts in', () {
    expect(SharedPreferencesUtil().appleRemindersAutoExportEnabled, isFalse);

    SharedPreferencesUtil().appleRemindersAutoExportEnabled = true;
    expect(SharedPreferencesUtil().appleRemindersAutoExportEnabled, isTrue);
  });

  // idea-capture: the Ideas folder cache must persist so captured ideas are filed
  // into the same folder across sessions.
  test('ideas folder id defaults empty and round-trips', () {
    expect(SharedPreferencesUtil().ideaFolderId, '');

    SharedPreferencesUtil().ideaFolderId = 'folder-abc';
    expect(SharedPreferencesUtil().ideaFolderId, 'folder-abc');
  });
}
