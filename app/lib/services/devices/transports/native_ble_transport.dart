import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

/// BLE transport backed by native platform APIs via Pigeon.
/// Uses the intent-based manageDevice/unmanageDevice API.
/// Native owns the connection lifecycle (retry, reconnect, bonding).
/// This transport is long-lived
class NativeBleTransport extends DeviceTransport {
  final String _peripheralUuid;
  final bool requiresBond;
  final BleHostApi _hostApi = BleHostApi();
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

  NativeBleTransport(this._peripheralUuid, {this.requiresBond = false}) {
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
      return _hostApi.isPeripheralConnected(_peripheralUuid);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> ping() async {
    try {
      return _hostApi.isPeripheralConnected(_peripheralUuid);
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

  void _subscribeCharacteristic(String serviceUuid, String characteristicUuid) {
    _hostApi.subscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid).catchError((e) {
      Logger.debug('[NativeBleTransport] Failed to subscribe $serviceUuid:$characteristicUuid: $e');
    });
  }

  void _unsubscribeCharacteristic(String serviceUuid, String characteristicUuid) {
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
    await disconnect();
    BleBridge.instance.unregisterPeripheral(_peripheralUuid);
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

  void _handleConnectionState(bool connected, String? error) {
    if (!connected) {
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
      _deviceReadyCompleter!.complete(services);
    } else {
      // Auto-reconnect from native — re-subscribe to characteristics
      _resubscribeAfterReconnect(services);
    }
  }

  bool _isResubscribing = false;

  void _resubscribeAfterReconnect(List<BleService> services) {
    if (_isResubscribing) return;
    _isResubscribing = true;

    try {
      _services = services;

      // Re-create stream controllers and re-subscribe to previously active characteristics
      for (final key in _activeSubscriptionKeys) {
        final parts = key.split(':');
        if (parts.length == 2) {
          _streamControllers[key] ??= _createStreamController(parts[0], parts[1], key);
          _subscribeCharacteristic(parts[0], parts[1]);
        }
      }

      _updateState(DeviceTransportState.connected);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to re-subscribe after reconnect: $e');
      _updateState(DeviceTransportState.disconnected);
    } finally {
      _isResubscribing = false;
    }
  }

  void _handleCharacteristicValue(String serviceUuid, String characteristicUuid, Uint8List value) {
    _addToStream(serviceUuid, characteristicUuid, value);
  }
}
