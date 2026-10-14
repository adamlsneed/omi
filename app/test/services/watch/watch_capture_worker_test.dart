import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/watch/watch_capture_worker.dart';

WatchCapture capture({String destination = 'idea'}) => WatchCapture({
      'id': 'recording-1',
      'owner': 'account-a',
      'destination': destination,
      'path': '/example.m4a',
      'createdAt': '1000',
      'duration': '4',
    });

class Inbox implements WatchCaptureInbox {
  final items = <WatchCapture>[];
  final events = <String>[];
  bool acknowledged = false;
  @override
  Future<List<WatchCapture>> pending() async => acknowledged ? [] : items;
  @override
  Future<void> checkpoint(WatchCapture capture) async => events.add('checkpoint:${capture.conversationId}');
  @override
  Future<void> failed(WatchCapture capture, String reason) async => events.add('failed:$reason');
  @override
  Future<void> saved(WatchCapture capture, String resultId) async {
    events.add('saved:$resultId');
    acknowledged = true;
  }
}

class Destination implements WatchCaptureDestination {
  Destination(this.events);
  final List<String> events;
  Future<String> Function()? transcription;
  bool failFiling = false;
  String text = 'Try a weekly idea review';
  @override
  Future<String> transcribe(WatchCapture capture) async {
    events.add('transcribe');
    if (transcription == null) return text;
    return await transcription!();
  }

  @override
  Future<String> createIdea(WatchCapture capture) async {
    events.add('idea');
    return 'conversation-1';
  }

  @override
  Future<void> fileIdea(WatchCapture capture) async {
    events.add('file');
    if (failFiling) throw const WatchCaptureFailure('folders');
  }

  @override
  Future<String> createTask(WatchCapture capture) async {
    events.add('task');
    return 'task-1';
  }
}

void main() {
  late Inbox inbox;
  late Destination destination;
  late String owner;
  late WatchCaptureWorker worker;
  setUp(() {
    inbox = Inbox();
    destination = Destination(inbox.events);
    owner = 'account-a';
    worker = WatchCaptureWorker(inbox: inbox, destination: destination, currentOwner: () => owner);
  });
  test('an idea is confirmed only after it is filed; delivery replay does not write again', () async {
    inbox.items.add(capture());
    await worker.drain();
    await worker.drain();
    expect(inbox.events,
        ['transcribe', 'checkpoint:', 'idea', 'checkpoint:conversation-1', 'file', 'saved:conversation-1']);
  });
  test('task gesture creates exactly a task and no idea', () async {
    inbox.items.add(capture(destination: 'task'));
    await worker.drain();
    expect(inbox.events, ['transcribe', 'checkpoint:', 'task', 'saved:task-1']);
  });
  test('folder failure retains checkpoint and retry resumes filing without a second conversation', () async {
    inbox.items.add(capture());
    destination.failFiling = true;
    await worker.drain();
    expect(inbox.acknowledged, isFalse);
    destination.failFiling = false;
    await worker.drain();
    expect(inbox.events.where((e) => e == 'transcribe').length, 1);
    expect(inbox.events.where((e) => e == 'idea').length, 1);
    expect(inbox.events.last, 'saved:conversation-1');
  });
  test('silence is retained with an honest error and never creates a destination', () async {
    inbox.items.add(capture());
    destination.text = '  ';
    await worker.drain();
    expect(inbox.events, ['transcribe', 'failed:no_speech']);
  });
  test('account switch during transcription cannot save or acknowledge under another account', () async {
    inbox.items.add(capture());
    destination.transcription = () async {
      owner = 'account-b';
      return 'private idea';
    };
    await worker.drain();
    expect(inbox.events, ['transcribe']);
  });
  test('overlapping drains share one writer', () async {
    inbox.items.add(capture(destination: 'task'));
    final gate = Completer<String>();
    destination.transcription = () => gate.future;
    final first = worker.drain();
    await Future<void>.delayed(Duration.zero);
    await worker.drain();
    gate.complete('Call the dentist');
    await first;
    expect(inbox.events.where((e) => e == 'task').length, 1);
  });
  test('too-long task is not truncated or marked saved', () async {
    inbox.items.add(capture(destination: 'task'));
    destination.text = 'x' * 4097;
    await worker.drain();
    expect(inbox.events.last, 'failed:too_long');
    expect(inbox.events, isNot(contains('task')));
  });
}
