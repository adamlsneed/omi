import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/utils/logger.dart';

import 'watch_capture_api.dart';
import 'watch_capture_worker.dart';

/// Foreground and headless background workers share the same save pipeline.
/// Native coordination admits only one engine to the durable inbox at a time.
class WatchCaptureRuntime implements WatchCaptureFlutterAPI {
  final _host = WatchCaptureHostAPI();
  Timer? _timer;
  StreamSubscription<User?>? _auth;
  bool _busy = false;
  bool _disposed = false;
  Completer<void>? _drain;
  void Function()? onSaved;

  void start() {
    if (!Platform.isIOS) return;
    WatchCaptureFlutterAPI.setUp(this);
    _auth = FirebaseAuth.instance.authStateChanges().listen((_) => unawaited(tick()));
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(tick()));
    unawaited(tick());
  }

  String _owner() {
    final snapshot = AuthService.instance.captureSessionSnapshot();
    if (snapshot == null) return '';
    return sha256.convert(utf8.encode('${snapshot.ownerUid}\n${Env.apiBaseUrl}')).toString();
  }

  Future<void> tick() async {
    if (!Platform.isIOS || _disposed) return;
    try {
      final owner = _owner();
      // Clear/update native admission even if an old upload is still finishing.
      await _host.setCaptureOwner(owner);
      if (_busy) return await _drain?.future;
      if (owner.isEmpty || _disposed) return;
      _busy = true;
      _drain = Completer<void>();
      try {
        final snapshot = AuthService.instance.captureSessionSnapshot();
        if (snapshot == null) return;
        final api = WatchCaptureApi(
          baseUrl: Env.apiBaseUrl!,
          canSend: () => !_disposed && _owner() == owner && AuthService.instance.isSessionSnapshotCurrent(snapshot),
          sessionSnapshot: snapshot,
          cachedIdeaFolderId: () => SharedPreferencesUtil().ideaFolderId,
          rememberIdeaFolder: (id) => SharedPreferencesUtil().ideaFolderId = id,
          language: SharedPreferencesUtil().userPrimaryLanguage,
        );
        await WatchCaptureWorker(
          inbox: _NativeInbox(_host, () => onSaved?.call()),
          destination: api,
          currentOwner: () => _disposed ? '' : _owner(),
        ).drain();
      } finally {
        _busy = false;
        _drain?.complete();
        _drain = null;
      }
    } catch (error) {
      // Audio remains in the native inbox. No content, paths or tokens in logs.
      Logger.debug('Watch capture processing deferred: ${error.runtimeType}');
    }
  }

  @override
  Future<void> processPendingCaptures() => tick();

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_auth?.cancel());
  }
}

class _NativeInbox implements WatchCaptureInbox {
  _NativeInbox(this.host, this.onSaved);
  final WatchCaptureHostAPI host;
  final void Function() onSaved;

  @override
  Future<List<WatchCapture>> pending() async => (await host.pendingCaptures())
      .map((item) => WatchCapture({
            'id': item.id,
            'owner': item.owner,
            'destination': item.destination,
            'path': item.path,
            'createdAt': item.createdAt.toString(),
            'duration': item.duration.toString(),
            'transcript': item.transcript,
            'conversationId': item.conversationId,
          }))
      .toList();
  @override
  Future<void> checkpoint(WatchCapture capture) =>
      host.checkpointCapture(capture.id, capture.owner, capture.transcript, capture.conversationId);
  @override
  Future<void> failed(WatchCapture capture, String reason) => host.failCapture(capture.id, capture.owner, reason);
  @override
  Future<void> saved(WatchCapture capture, String resultId) async {
    await host.finishCapture(capture.id, capture.owner, resultId);
    try {
      onSaved();
    } catch (error) {
      Logger.debug('Watch capture view refresh deferred: ${error.runtimeType}');
    }
  }
}
