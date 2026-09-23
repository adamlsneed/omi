import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/env/env.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/platform/platform_manager.dart';

class _TestEnvFields implements EnvFields {
  @override
  String? get posthogApiKey => null;
  @override
  String? get apiBaseUrl => null;
  @override
  String? get intercomAppId => null;
  @override
  String? get intercomIOSApiKey => null;
  @override
  String? get intercomAndroidApiKey => null;
  @override
  String? get googleClientId => null;
  @override
  String? get googleClientSecret => null;
  @override
  bool? get useWebAuth => false;
  @override
  bool? get useAuthCustomToken => false;
}

// Fork firmware sends button state 6 on a press-and-hold (idea capture ENTER)
// and 7 when the hold mode ends (EXIT). The pendant enters idea-capture mode on
// its own, so the app must follow those signals even when upstream's Omi button
// actions toggle is off.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => {'appName': 'omi', 'packageName': 'com.omi.test', 'version': '0.0.0', 'buildNumber': '1'},
    );
    try {
      Env.init(_TestEnvFields());
    } catch (_) {}
    try {
      await ServiceManager.init();
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'deviceIdHash': 'test-device-hash'});
    await SharedPreferencesUtil.init();
    await PlatformManager.initializeServices();
  });

  test('hold signals drive idea capture while Omi button actions are disabled', () async {
    var processCalls = 0;
    final provider = CaptureProvider(
      speakerHaptic: (_, __) async => true,
      processInProgressConversation: () async {
        processCalls++;
        return null;
      },
    );
    provider.updateRecordingDevice(BtDevice(name: 'Omi', id: 'test-id', type: DeviceType.omi, rssi: -40));
    SharedPreferencesUtil().omiButtonActionsEnabled = false;

    provider.handleButtonEventForTesting('test-id', 6);
    await pumpEventQueue();
    expect(provider.isIdeaCaptureActive, isTrue);

    provider.handleButtonEventForTesting('test-id', 7);
    await pumpEventQueue();
    expect(provider.isIdeaCaptureActive, isFalse);
    expect(processCalls, 1, reason: 'leaving idea capture force-processes the captured window');

    provider.dispose();
  });
}
