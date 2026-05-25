import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';

void main() {
  group('Apple Reminders auto-export preference', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    test('defaults to disabled until the user opts in', () {
      expect(SharedPreferencesUtil().appleRemindersAutoExportEnabled, isFalse);
    });

    test('persists when enabled', () {
      SharedPreferencesUtil().appleRemindersAutoExportEnabled = true;

      expect(SharedPreferencesUtil().appleRemindersAutoExportEnabled, isTrue);
    });

    test('persists when disabled', () {
      SharedPreferencesUtil().appleRemindersAutoExportEnabled = false;

      expect(SharedPreferencesUtil().appleRemindersAutoExportEnabled, isFalse);
    });
  });
}
