import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const peripheralUuid = '11111111-2222-3333-4444-555555555555';
  const serviceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
  const characteristicUuid = '19b10001-e8f2-537e-4f6c-d104768a1214';

  late List<String> hostCalls;

  void setBleHostHandler(String method, Future<Object?> Function(Object? message) handler) {
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.omi_pigeon.BleHostApi.$method',
      BleHostApi.pigeonChannelCodec,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      channel,
      handler,
    );
  }

  setUp(() {
    hostCalls = [];

    setBleHostHandler('manageDevice', (message) async {
      hostCalls.add('manageDevice');
      return wrapResponse();
    });
    setBleHostHandler('subscribeCharacteristic', (message) async {
      final args = (message as List<Object?>).cast<Object?>();
      hostCalls.add('subscribe:${args[1]}:${args[2]}');
      return wrapResponse();
    });
    setBleHostHandler('unsubscribeCharacteristic', (message) async {
      final args = (message as List<Object?>).cast<Object?>();
      hostCalls.add('unsubscribe:${args[1]}:${args[2]}');
      return wrapResponse();
    });
    setBleHostHandler('unmanageDevice', (message) async {
      hostCalls.add('unmanageDevice');
      return wrapResponse();
    });
  });

  tearDown(() {
    for (final method in [
      'manageDevice',
      'subscribeCharacteristic',
      'unsubscribeCharacteristic',
      'unmanageDevice',
    ]) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.omi_pigeon.BleHostApi.$method',
        BleHostApi.pigeonChannelCodec,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        channel,
        null,
      );
    }
  });

  test('cancelling the last characteristic listener disables native notifications', () async {
    final transport = NativeBleTransport(peripheralUuid);
    addTearDown(transport.dispose);

    final connect = transport.connect();
    BleBridge.instance.onDeviceReady(peripheralUuid, [
      BleService(
        uuid: serviceUuid,
        characteristicUuids: [characteristicUuid],
      ),
    ]);
    await connect;

    final subscription = transport.getCharacteristicStream(serviceUuid, characteristicUuid).listen((_) {});
    await pumpEventQueue();

    expect(hostCalls, contains('subscribe:$serviceUuid:$characteristicUuid'));

    await subscription.cancel();
    await pumpEventQueue();

    expect(hostCalls, contains('unsubscribe:$serviceUuid:$characteristicUuid'));
  });

  test('explicit disconnect cleans up subscriptions after a native disconnect', () async {
    final transport = NativeBleTransport(peripheralUuid);
    addTearDown(transport.dispose);

    final connect = transport.connect();
    BleBridge.instance.onDeviceReady(peripheralUuid, [
      BleService(
        uuid: serviceUuid,
        characteristicUuids: [characteristicUuid],
      ),
    ]);
    await connect;

    final subscription = transport.getCharacteristicStream(serviceUuid, characteristicUuid).listen((_) {});
    addTearDown(subscription.cancel);
    await pumpEventQueue();

    BleBridge.instance.onPeripheralDisconnected(peripheralUuid, null);
    await pumpEventQueue();

    hostCalls.clear();
    await transport.disconnect();
    await pumpEventQueue();

    expect(hostCalls, contains('unsubscribe:$serviceUuid:$characteristicUuid'));
    expect(hostCalls, contains('unmanageDevice'));
  });

  test('dispose cleans up native management after a native disconnect', () async {
    final transport = NativeBleTransport(peripheralUuid);

    final connect = transport.connect();
    BleBridge.instance.onDeviceReady(peripheralUuid, [
      BleService(
        uuid: serviceUuid,
        characteristicUuids: [characteristicUuid],
      ),
    ]);
    await connect;

    final subscription = transport.getCharacteristicStream(serviceUuid, characteristicUuid).listen((_) {});
    addTearDown(subscription.cancel);
    await pumpEventQueue();

    BleBridge.instance.onPeripheralDisconnected(peripheralUuid, null);
    await pumpEventQueue();

    hostCalls.clear();
    await transport.dispose();
    await pumpEventQueue();

    expect(hostCalls, contains('unsubscribe:$serviceUuid:$characteristicUuid'));
    expect(hostCalls, contains('unmanageDevice'));
  });
}
