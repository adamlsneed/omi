import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omi/backend/http/api_result.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/services/auth/auth_token_result.dart';

import 'watch_capture_worker.dart';

/// Uses the same hosted task, conversation and folder endpoints as the phone
/// and Mac. No global "process current conversation" call can touch a pendant.
class WatchCaptureApi implements WatchCaptureDestination {
  WatchCaptureApi({
    required this.baseUrl,
    required this.canSend,
    required this.cachedIdeaFolderId,
    required this.rememberIdeaFolder,
    required this.language,
    this.sessionSnapshot,
    ApiSend? send,
    Future<String> Function(WatchCapture)? transcribe,
  })  : _send = send,
        _transcribe = transcribe;

  final String baseUrl, language;
  final bool Function() canSend;
  final String Function() cachedIdeaFolderId;
  final void Function(String) rememberIdeaFolder;
  final AuthSessionSnapshot? sessionSnapshot;
  final ApiSend? _send;
  final Future<String> Function(WatchCapture)? _transcribe;

  Future<http.Response> _sendBound(ApiRequest request) async => http.Response.fromStream(await makeRawApiCall(
        url: request.url,
        method: request.method,
        headers: request.headers,
        body: request.body,
        sessionSnapshot: sessionSnapshot,
      ));

  Future<Object?> _request(String method, String path, {Object? body, Map<String, String> headers = const {}}) async {
    final result = await executeApi<Object?>(
      request: ApiRequest(
          url: '$baseUrl$path', method: method, headers: headers, body: body == null ? '' : jsonEncode(body)),
      decode: jsonDecode,
      send: _send ?? _sendBound,
      canSend: canSend,
    );
    if (!canSend()) throw const WatchCaptureFailure('account');
    return switch (result) {
      ApiSuccess(:final data) => data,
      ApiFailure(:final problem) => throw WatchCaptureFailure(problem.kind.name),
    };
  }

  static String _id(Object? response) {
    if (response is! Map || response['id'] is! String || (response['id'] as String).isEmpty) {
      throw const WatchCaptureFailure('invalid_receipt');
    }
    return response['id'] as String;
  }

  @override
  Future<String> transcribe(WatchCapture capture) async {
    if (!canSend()) throw const WatchCaptureFailure('account');
    if (_transcribe != null) return _transcribe!(capture);
    final response = await makeMultipartApiCallUnpooled(
      url: '${baseUrl}v2/voice-message/transcribe',
      files: [File(capture.path)],
      fields: {'language': language},
      sessionSnapshot: sessionSnapshot,
    );
    if (!canSend()) throw const WatchCaptureFailure('account');
    if (response.statusCode != 200) throw const WatchCaptureFailure('transcription');
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['transcript'] is! String) throw const WatchCaptureFailure('transcription');
    return decoded['transcript'] as String;
  }

  @override
  Future<String> createTask(WatchCapture capture) async {
    return _id(await _request('POST', 'v1/action-items',
        headers: {'Idempotency-Key': 'watch-capture:${capture.id}'},
        body: {'description': capture.transcript, 'completed': false, 'source': 'manual'}));
  }

  @override
  Future<String> createIdea(WatchCapture capture) async {
    final result = await _request('POST', 'v1/conversations/from-segments', body: {
      'client_session_id': 'watch-capture:${capture.id}',
      'source': 'apple_watch',
      'started_at': capture.createdAt.toIso8601String(),
      'finished_at': capture.createdAt.add(Duration(milliseconds: (capture.duration * 1000).round())).toIso8601String(),
      'language': language,
      'conversation_finalization_reason': 'user_done',
      'transcript_segments': [
        {'text': capture.transcript, 'speaker': 'SPEAKER_00', 'is_user': true, 'start': 0, 'end': capture.duration},
      ],
    });
    if (result is Map && result['status'] == 'deleted') throw const WatchCaptureFailure('deleted');
    return _id(result);
  }

  @override
  Future<void> fileIdea(WatchCapture capture) async {
    final path = 'v1/conversations/${Uri.encodeComponent(capture.conversationId)}';
    var conversation = await _request('GET', path);
    if (conversation is! Map || conversation['status'] != 'completed') {
      throw const WatchCaptureFailure('processing');
    }
    // An explicit idea must stay discoverable even when a very short recording
    // was discarded by the ordinary ambient-capture heuristic.
    if (conversation['discarded'] == true) {
      conversation = await _request('POST', '$path/reprocess');
      if (conversation is! Map || conversation['discarded'] != false || conversation['status'] != 'completed') {
        throw const WatchCaptureFailure('processing');
      }
    }
    final folders = await _request('GET', 'v1/folders');
    if (folders is! List) throw const WatchCaptureFailure('folders');
    final cached = cachedIdeaFolderId();
    final matches = folders
        .whereType<Map>()
        .where((f) => (cached.isNotEmpty && f['id'] == cached) || (f['name'] as String?)?.toLowerCase() == 'ideas');
    final folderId = matches.isNotEmpty
        ? _id(matches.first)
        : _id(await _request('POST', 'v1/folders', body: {
            'name': 'Ideas',
            'description': 'Captured ideas: intentional, fleeting thoughts saved from the pendant, app or Watch.',
            'color': '#22C55E',
            'icon': '💡',
          }));
    rememberIdeaFolder(folderId);
    await _request('PATCH', '$path/folder', body: {'folder_id': folderId});
    // A successful create or move alone does not prove the destination is visible.
    final saved = await _request('GET', path);
    if (saved is! Map ||
        saved['id'] != capture.conversationId ||
        saved['folder_id'] != folderId ||
        saved['discarded'] != false ||
        saved['status'] != 'completed') {
      throw const WatchCaptureFailure('invalid_receipt');
    }
  }
}
