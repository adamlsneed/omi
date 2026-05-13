import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/apple_health_service.dart';

void main() {
  group('AppleHealthService.connect', () {
    test('connects when HealthKit authorization succeeds but sample probe finds no recent data', () async {
      final calls = <String>[];
      final service = AppleHealthService.test(
        isAvailable: true,
        invokeMethod: <T>(method, [arguments]) async {
          calls.add(method);
          switch (method) {
            case 'requestPermission':
              return true as T;
            case 'probeAccess':
              return false as T;
            default:
              throw StateError('Unexpected method $method');
          }
        },
      );

      final result = await service.connect();

      expect(result, AppleHealthResult.success);
      expect(calls, ['requestPermission', 'probeAccess']);
    });

    test('returns permissionDenied when HealthKit authorization fails', () async {
      final service = AppleHealthService.test(
        isAvailable: true,
        invokeMethod: <T>(method, [arguments]) async {
          expect(method, 'requestPermission');
          return false as T;
        },
      );

      final result = await service.connect();

      expect(result, AppleHealthResult.permissionDenied);
    });
  });
}
