import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native inbox items survive the actual platform codec', () async {
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.omi_pigeon.WatchCaptureHostAPI.pendingCaptures',
      WatchCaptureHostAPI.pigeonChannelCodec,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      channel,
      (_) async => [
        [
          WatchCaptureItem(
              id: 'capture-1',
              owner: 'account-a',
              destination: 'idea',
              path: '/capture.m4a',
              createdAt: 1000,
              duration: 4,
              transcript: 'A saved idea',
              conversationId: 'conversation-1'),
        ],
      ],
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, null));

    final items = await WatchCaptureHostAPI().pendingCaptures();
    expect(items.single.id, 'capture-1');
    expect(items.single.transcript, 'A saved idea');
    expect(items.single.conversationId, 'conversation-1');
    expect(items.single.duration, 4);
  });
}
