import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/api_result.dart';
import 'package:omi/services/watch/watch_capture_api.dart';
import 'package:omi/services/watch/watch_capture_worker.dart';

WatchCapture capture() => WatchCapture({
      'id': 'recording-1',
      'owner': 'owner',
      'destination': 'idea',
      'path': '/example.m4a',
      'createdAt': '1000',
      'duration': '4',
      'transcript': 'An idea worth keeping',
      'conversationId': 'conversation-1',
    });

void main() {
  late List<ApiRequest> requests;
  late bool current;
  late String cached;
  late Future<http.Response> Function(ApiRequest) reply;
  late WatchCaptureApi api;
  setUp(() {
    requests = [];
    current = true;
    cached = '';
    reply = (_) async => http.Response('{}', 200);
    api = WatchCaptureApi(
        baseUrl: 'https://example.com/',
        canSend: () => current,
        language: 'en',
        cachedIdeaFolderId: () => cached,
        rememberIdeaFolder: (id) => cached = id,
        send: (request) {
          requests.add(request);
          return reply(request);
        });
  });
  test('task retry carries a stable key without content in that key', () async {
    reply = (_) async => http.Response('{"id":"task-1"}', 200);
    await api.createTask(capture());
    await api.createTask(capture());
    expect(requests.every((r) => r.url.endsWith('/v1/action-items')), isTrue);
    expect(requests.map((r) => r.headers['Idempotency-Key']).toSet(), {'watch-capture:recording-1'});
    expect(jsonDecode(requests.first.body)['description'], 'An idea worth keeping');
  });
  test('idea ingest is isolated from live recording and keyed to the Watch capture', () async {
    reply = (_) async => http.Response('{"id":"conversation-1","status":"completed"}', 200);
    await api.createIdea(capture());
    expect(requests.single.url, endsWith('/v1/conversations/from-segments'));
    final body = jsonDecode(requests.single.body);
    expect(body['source'], 'apple_watch');
    expect(body['client_session_id'], 'watch-capture:recording-1');
    expect(body['transcript_segments'][0]['end'], 4);
  });
  test('existing Ideas destination is reused and read back before success', () async {
    var reads = 0;
    reply = (r) async {
      if (r.url.endsWith('/v1/folders')) return http.Response('[{"id":"ideas-1","name":"Ideas"}]', 200);
      if (r.method == 'PATCH') return http.Response('{"status":"ok"}', 200);
      reads++;
      return http.Response(
          jsonEncode({
            'id': 'conversation-1',
            'status': 'completed',
            'discarded': false,
            'folder_id': reads == 1 ? null : 'ideas-1'
          }),
          200);
    };
    await api.fileIdea(capture());
    expect(requests.map((r) => r.method), ['GET', 'GET', 'PATCH', 'GET']);
    expect(cached, 'ideas-1');
    expect(jsonDecode(requests[2].body), {'folder_id': 'ideas-1'});
    expect(requests.every((r) => !r.url.contains('memories')), isTrue);
  });
  test('a failed folder lookup never creates a duplicate collection', () async {
    reply = (r) async => r.url.endsWith('/v1/folders')
        ? http.Response('{}', 503)
        : http.Response('{"id":"conversation-1","status":"completed","discarded":false}', 200);
    await expectLater(api.fileIdea(capture()), throwsA(isA<WatchCaptureFailure>()));
    expect(requests.every((r) => r.method == 'GET'), isTrue);
  });
  test('an unconfirmed move is not saved', () async {
    reply = (r) async {
      if (r.url.endsWith('/v1/folders')) return http.Response('[{"id":"ideas-1","name":"Ideas"}]', 200);
      return http.Response('{"id":"conversation-1","status":"completed","discarded":false}', 200);
    };
    await expectLater(api.fileIdea(capture()), throwsA(isA<WatchCaptureFailure>()));
  });
  test('short discarded idea is restored before filing', () async {
    var restored = false;
    reply = (r) async {
      if (r.url.endsWith('/v1/folders')) return http.Response('[{"id":"ideas-1","name":"Ideas"}]', 200);
      if (r.url.endsWith('/reprocess')) restored = true;
      return http.Response(
          jsonEncode({'id': 'conversation-1', 'status': 'completed', 'discarded': !restored, 'folder_id': 'ideas-1'}),
          200);
    };
    await api.fileIdea(capture());
    expect(restored, isTrue);
    expect(requests[1].url, endsWith('/reprocess'));
  });
  test('deleted retry and account change never claim saved', () async {
    reply = (_) async => http.Response('{"id":"conversation-1","status":"deleted"}', 200);
    await expectLater(api.createIdea(capture()), throwsA(isA<WatchCaptureFailure>()));
    requests.clear();
    current = false;
    await expectLater(api.createTask(capture()), throwsA(isA<WatchCaptureFailure>()));
    expect(requests, isEmpty);
  });
}
