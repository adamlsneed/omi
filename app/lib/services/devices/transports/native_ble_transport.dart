import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices/bluetooth_readiness.dart';
import 'package:omi/services/devices/models.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

/// After reconnect, one CCCD re-subscribe is allowed if no audio bytes arrive.
const _captureAudioLivenessWindow = Duration(seconds: 4);
const _captureAudioSilenceResubscribeLimit = 1;

/// BLE transport backed by native platform APIs via Pigeon.
/// Uses the intent-based manageDevice/unmanageDevice API.
/// Native owns the connection lifecycle (retry, reconnect, bonding).
/// This transport is long-lived
class NativeBleTransport extends DeviceTransport {
  final String _peripheralUuid;
  final bool requiresBond;
  final BleHostApi _hostApi;
  final StreamController<DeviceTransportState> _connectionStateController =
      StreamController<DeviceTransportState>.broadcast();

  /// Characteristic notification streams, keyed by "serviceUuid:charUuid" (lowercased).
  final Map<String, StreamController<List<int>>> _streamControllers = {};

  /// Characteristics that currently have at least one Dart listener.
  /// Only these should keep native notifications enabled or be restored after reconnect.
  final Set<String> _activeSubscriptionKeys = {};

  /// Discovered services from native.
  List<BleService> _services = [];

  Completer<List<BleService>>? _deviceReadyCompleter;

  DeviceTransportState _state = DeviceTransportState.disconnected;
  bool _isManagedByNative = false;
  Timer? _audioLivenessTimer;
  int _audioSilenceResubscribes = 0;

  NativeBleTransport(this._peripheralUuid, {this.requiresBond = false, BleHostApi? hostApi})
      : _hostApi = hostApi ?? BleHostApi() {
    BleBridge.instance.registerPeripheral(
      peripheralUuid: _peripheralUuid,
      onConnectionState: _handleConnectionState,
      onDeviceReady: _handleDeviceReady,
      onCharacteristicValue: _handleCharacteristicValue,
    );
  }

  @override
  String get deviceId => _peripheralUuid;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  // MARK: - Connection

  @override
  Future<void> connect() async {
    if (_state == DeviceTransportState.connected) return;

    if (!await BluetoothReadiness.instance.ensureReady(BluetoothUse.connection)) {
      throw BluetoothAdapterUnavailableException(BluetoothReadiness.instance.state);
    }

    _updateState(DeviceTransportState.connecting);

    _deviceReadyCompleter = Completer<List<BleService>>();

    try {
      await _hostApi.manageDevice(_peripheralUuid, requiresBond);
      _isManagedByNative = true;
    } catch (e) {
      Logger.debug('[NativeBleTransport] manageDevice failed: $e');
      _deviceReadyCompleter = null;
      _isManagedByNative = false;
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }

    try {
      _services = await _deviceReadyCompleter!.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('Device ready timeout after 60s'),
      );
      _deviceReadyCompleter = null;
      _updateState(DeviceTransportState.connected);
    } catch (e) {
      Logger.debug('[NativeBleTransport] connect failed: $e');
      _deviceReadyCompleter = null;
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    final needsCleanup = _state != DeviceTransportState.disconnected ||
        _isManagedByNative ||
        _streamControllers.isNotEmpty ||
        _activeSubscriptionKeys.isNotEmpty;
    if (!needsCleanup) return;

    // A liveness watch pending from a prior connection must not fire into a
    // subsequent one and force a spurious CCCD re-subscribe.
    _audioLivenessTimer?.cancel();
    _audioSilenceResubscribes = 0;

    // Guarded: this transport also cleans up when the link is already down.
    if (_state != DeviceTransportState.disconnected) {
      _updateState(DeviceTransportState.disconnecting);
    }

    // Unsubscribe all active streams
    for (final key in _activeSubscriptionKeys.toList()) {
      final parts = key.split(':');
      if (parts.length == 2) {
        _unsubscribeCharacteristic(parts[0], parts[1]);
      }
    }

    _activeSubscriptionKeys.clear();
    _subscribedSubscriptionKeys.clear();
    _closeAllStreams();
    _services = [];

    try {
      if (_isManagedByNative) {
        await _hostApi.unmanageDevice(_peripheralUuid);
      }
    } catch (e) {
      Logger.debug('[NativeBleTransport] unmanageDevice failed: $e');
    } finally {
      _isManagedByNative = false;
    }

    _updateState(DeviceTransportState.disconnected);
  }

  @override
  Future<bool> isConnected() async {
    try {
      return await _hostApi.isPeripheralConnected(_peripheralUuid);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> ping() async {
    try {
      return await _hostApi.isPeripheralConnected(_peripheralUuid);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> requestBond() async {
    try {
      return await _hostApi.requestBond(_peripheralUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] requestBond failed: $e');
      return false;
    }
  }

  // MARK: - Characteristic Streams

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';

    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = _createStreamController(serviceUuid, characteristicUuid, key);
    }

    return _streamControllers[key]!.stream;
  }

  StreamController<List<int>> _createStreamController(String serviceUuid, String characteristicUuid, String key) {
    return StreamController<List<int>>.broadcast(
      onListen: () {
        _activeSubscriptionKeys.add(key);
        if (_hasCharacteristic(serviceUuid, characteristicUuid)) {
          _subscribeCharacteristic(serviceUuid, characteristicUuid);
        }
      },
      onCancel: () {
        _activeSubscriptionKeys.remove(key);
        if (_hasCharacteristic(serviceUuid, characteristicUuid)) {
          _unsubscribeCharacteristic(serviceUuid, characteristicUuid);
        }
      },
    );
  }

  Future<void> _subscribeCharacteristic(String serviceUuid, String characteristicUuid, {bool force = false}) async {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';
    if (!force && _subscribedSubscriptionKeys.contains(key)) return;
    _subscribedSubscriptionKeys.add(key);
    _hostApi.subscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid).catchError((e) {
      _subscribedSubscriptionKeys.remove(key);
      Logger.debug('[NativeBleTransport] Failed to subscribe $serviceUuid:$characteristicUuid: $e');
    });
  }

  void _unsubscribeCharacteristic(String serviceUuid, String characteristicUuid) {
    _subscribedSubscriptionKeys.remove('${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}');
    _hostApi.unsubscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid).catchError((e) {
      Logger.debug('[NativeBleTransport] Failed to unsubscribe $serviceUuid:$characteristicUuid: $e');
    });
  }

  bool _hasCharacteristic(String serviceUuid, String characteristicUuid) {
    final sUuid = serviceUuid.toLowerCase();
    final cUuid = characteristicUuid.toLowerCase();
    for (final service in _services) {
      if (service.uuid.toLowerCase() == sUuid) {
        return service.characteristicUuids.any((c) => c.toLowerCase() == cUuid);
      }
    }
    return false;
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    if (!_hasCharacteristic(serviceUuid, characteristicUuid)) return [];
    try {
      final data = await _hostApi.readCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
      return data.toList();
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to read $serviceUuid:$characteristicUuid: $e');
      return [];
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    if (!_hasCharacteristic(serviceUuid, characteristicUuid)) {
      Logger.debug('[NativeBleTransport] writeCharacteristic skipped: $characteristicUuid not available');
      return;
    }
    try {
      await _hostApi.writeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid, Uint8List.fromList(data));
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to write characteristic: $e');
      rethrow;
    }
  }

  // MARK: - Dispose

  @override
  Future<void> dispose() async {
    _audioLivenessTimer?.cancel();
    // Unregister before the first await. `disconnect()` yields, and a caller that
    // replaces this transport with a new one for the same peripheral registers in
    // that gap; unregistering afterwards would tear down the replacement's
    // callbacks and leave the new transport deaf to every native event.
    BleBridge.instance.unregisterPeripheral(_peripheralUuid);
    await disconnect();
    _activeSubscriptionKeys.clear();
    _subscribedSubscriptionKeys.clear();
    _closeAllStreams();
    await _connectionStateController.close();
  }

  // MARK: - Private Helpers

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(_state);
    }
  }

  void _closeAllStreams() {
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
    _activeSubscriptionKeys.clear();
  }

  void _addToStream(String serviceUuid, String characteristicUuid, List<int> data) {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';
    final controller = _streamControllers[key];
    if (controller != null && !controller.isClosed) {
      controller.add(data);
    }
  }

  // MARK: - Native Callbacks

  /// Characteristics with a native subscription currently in place; dedups
  /// subscribe calls and is reset when the link drops.
  final Set<String> _subscribedSubscriptionKeys = {};

  void _handleConnectionState(bool connected, String? error) {
    if (!connected) {
      // Native subscriptions died with the link. _activeSubscriptionKeys is
      // listener-driven and survives so ready/reconnect can re-subscribe.
      _subscribedSubscriptionKeys.clear();
      _audioLivenessTimer?.cancel();
      _audioSilenceResubscribes = 0;
      _services = [];
      _updateState(DeviceTransportState.disconnected);

      // Fail pending completer
      if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
        _deviceReadyCompleter!.completeError(error ?? 'Disconnected before ready');
      }
    }
  }

  void _handleDeviceReady(List<BleService> services) {
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      // Initial connection
      _services = services;
      _deviceReadyCompleter!.complete(services);
      _subscribeActiveCharacteristics();
    } else {
      // Auto-reconnect from native — re-subscribe to characteristics
      _resubscribeAfterReconnect(services);
    }
  }

  bool _isResubscribing = false;

  void _subscribeActiveCharacteristics() {
    for (final key in _activeSubscriptionKeys) {
      final parts = key.split(':');
      if (parts.length == 2 && _hasCharacteristic(parts[0], parts[1])) {
        _subscribeCharacteristic(parts[0], parts[1]);
      }
    }
  }

  void _resubscribeAfterReconnect(List<BleService> services) {
    if (_isResubscribing) return;
    _isResubscribing = true;

    try {
      _services = services;

      // Native re-emits ready for a link that is already up, so keep live controllers.
      for (final key in _activeSubscriptionKeys) {
        final parts = key.split(':');
        if (parts.length == 2) {
          final controller = _streamControllers[key];
          if (controller == null || controller.isClosed) {
            _streamControllers[key] = _createStreamController(parts[0], parts[1], key);
          }
          if (_hasCharacteristic(parts[0], parts[1])) {
            _subscribeCharacteristic(parts[0], parts[1]);
          }
        }
      }

      _updateState(DeviceTransportState.connected);
      _audioSilenceResubscribes = 0;
      _armAudioLivenessWatch();
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to re-subscribe after reconnect: $e');
      _updateState(DeviceTransportState.disconnected);
    } finally {
      _isResubscribing = false;
    }
  }

  void _handleCharacteristicValue(String serviceUuid, String characteristicUuid, Uint8List value) {
    if (isBleAudioCharacteristicUuid(characteristicUuid) && value.isNotEmpty) {
      _audioSilenceResubscribes = 0;
      _audioLivenessTimer?.cancel();
    }
    _addToStream(serviceUuid, characteristicUuid, value);
  }

  bool get _hasAudioSubscription {
    return _activeSubscriptionKeys.any((key) {
      final parts = key.split(':');
      return parts.length == 2 && isBleAudioCharacteristicUuid(parts[1]);
    });
  }

  void _armAudioLivenessWatch() {
    _audioLivenessTimer?.cancel();
    if (_state != DeviceTransportState.connected || !_hasAudioSubscription) {
      return;
    }
    _audioLivenessTimer = Timer(_captureAudioLivenessWindow, _onAudioLivenessTimeout);
  }

  void _onAudioLivenessTimeout() {
    if (_state != DeviceTransportState.connected) return;
    if (_audioSilenceResubscribes < _captureAudioSilenceResubscribeLimit) {
      _audioSilenceResubscribes++;
      Logger.debug('[NativeBleTransport] no audio after reconnect, retrying CCCD subscribe once');
      for (final key in _activeSubscriptionKeys) {
        final parts = key.split(':');
        if (parts.length == 2 && isBleAudioCharacteristicUuid(parts[1]) && _hasCharacteristic(parts[0], parts[1])) {
          unawaited(_subscribeCharacteristic(parts[0], parts[1], force: true));
        }
      }
      _armAudioLivenessWatch();
      return;
    }
    Logger.debug('[NativeBleTransport] audio path silent after reconnect — GATT connected is not capturing');
  }
}
