import Combine
@preconcurrency import CoreBluetooth
import Foundation
import os.log

/// BLE transport implementation using CoreBluetooth
/// Ported from: omi/app/lib/services/devices/transports/ble_transport.dart
final class BleTransport: NSObject, DeviceTransport, @unchecked Sendable {

    // MARK: - DeviceTransport Protocol

    let deviceId: String

    var state: DeviceTransportState {
        _state
    }

    var connectionStatePublisher: AnyPublisher<DeviceTransportState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    // MARK: - Private Properties

    private let peripheral: CBPeripheral
    private let centralManager: CBCentralManager
    private let logger = Logger(subsystem: "me.omi.desktop", category: "BleTransport")

    private var _state: DeviceTransportState = .disconnected
    private let connectionStateSubject = PassthroughSubject<DeviceTransportState, Never>()

    private var discoveredServices: [CBService] = []
    private var characteristicContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var characteristicContinuationTokens: [CBUUID: UUID] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var writeContinuationTokens: [CBUUID: UUID] = [:]
    private var characteristicStreams: [String: CharacteristicStreamHandler] = [:]

    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var serviceDiscoveryContinuation: CheckedContinuation<[CBService], Error>?
    private var rssiContinuation: CheckedContinuation<Int, Error>?
    private var rssiOperationId: UUID?

    private var isDisposed = false
    private var centralManagerObservers: [NSObjectProtocol] = []
    private let connectionTimeout: TimeInterval = 10
    private let characteristicTimeout: TimeInterval = 5
    private let rssiTimeout: TimeInterval = 3

    // MARK: - Initialization

    init(peripheral: CBPeripheral, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.centralManager = centralManager
        self.deviceId = peripheral.identifier.uuidString
        super.init()
        peripheral.delegate = self
        setupConnectionObserver()
    }

    private func setupConnectionObserver() {
        // Observe connection state changes via NotificationCenter
        // BluetoothManager posts these when CBCentralManagerDelegate methods fire
        let connectedObserver = NotificationCenter.default.addObserver(
            forName: .bleDeviceConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let peripheralId = notification.userInfo?["peripheralId"] as? UUID,
                  peripheralId == self.peripheral.identifier else { return }

            self.handleConnectionSuccess()
        }
        centralManagerObservers.append(connectedObserver)

        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: .bleDeviceDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let peripheralId = notification.userInfo?["peripheralId"] as? UUID,
                  peripheralId == self.peripheral.identifier else { return }

            let error = notification.userInfo?["error"] as? Error
            self.handleDisconnection(error: error)
        }
        centralManagerObservers.append(disconnectedObserver)

        let failedObserver = NotificationCenter.default.addObserver(
            forName: .bleDeviceFailedToConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let peripheralId = notification.userInfo?["peripheralId"] as? UUID,
                  peripheralId == self.peripheral.identifier else { return }

            let error = notification.userInfo?["error"] as? Error
            self.handleConnectionFailure(error: error)
        }
        centralManagerObservers.append(failedObserver)
    }

    private func handleConnectionSuccess() {
        connectionContinuation?.resume()
        connectionContinuation = nil
    }

    private func handleConnectionFailure(error: Error?) {
        let transportError = DeviceTransportError.connectionFailed(error?.localizedDescription ?? "Unknown error")
        connectionContinuation?.resume(throwing: transportError)
        connectionContinuation = nil
        updateState(.disconnected)
    }

    private func handleDisconnection(error: Error?) {
        if let continuation = connectionContinuation {
            continuation.resume(throwing: DeviceTransportError.connectionFailed("Disconnected during connection"))
            connectionContinuation = nil
        }
        serviceDiscoveryContinuation?.resume(throwing: DeviceTransportError.notConnected)
        serviceDiscoveryContinuation = nil
        for (_, continuation) in characteristicContinuations {
            continuation.resume(throwing: DeviceTransportError.notConnected)
        }
        characteristicContinuations.removeAll()
        characteristicContinuationTokens.removeAll()
        for (_, continuation) in writeContinuations {
            continuation.resume(throwing: DeviceTransportError.notConnected)
        }
        writeContinuations.removeAll()
        writeContinuationTokens.removeAll()
        rssiContinuation?.resume(throwing: DeviceTransportError.notConnected)
        rssiContinuation = nil
        rssiOperationId = nil
        updateState(.disconnected)
    }

    deinit {
        for observer in centralManagerObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        centralManagerObservers.removeAll()
    }

    // MARK: - Connection

    func connect() async throws {
        guard !isDisposed else { throw DeviceTransportError.disposed }
        guard _state != .connected else { return }

        updateState(.connecting)

        do {
            // Connect to the peripheral
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connectionContinuation = continuation
                self.centralManager.connect(self.peripheral, options: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.connectionTimeout) { [weak self] in
                    guard let self = self, let continuation = self.connectionContinuation else { return }
                    self.connectionContinuation = nil
                    self.centralManager.cancelPeripheralConnection(self.peripheral)
                    continuation.resume(throwing: DeviceTransportError.timeout)
                }
            }

            // Discover services
            discoveredServices = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CBService], Error>) in
                self.serviceDiscoveryContinuation = continuation
                self.peripheral.discoverServices(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.connectionTimeout) { [weak self] in
                    guard let self = self, let continuation = self.serviceDiscoveryContinuation else { return }
                    self.serviceDiscoveryContinuation = nil
                    continuation.resume(throwing: DeviceTransportError.timeout)
                }
            }

            // Discover characteristics for each service
            for service in discoveredServices {
                peripheral.discoverCharacteristics(nil, for: service)
            }

            // Wait briefly for characteristic discovery
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            updateState(.connected)
            logger.info("Connected to device \(self.deviceId)")

        } catch {
            centralManager.cancelPeripheralConnection(peripheral)
            updateState(.disconnected)
            throw DeviceTransportError.connectionFailed(error.localizedDescription)
        }
    }

    func disconnect() async {
        guard !isDisposed else { return }
        guard _state != .disconnected else { return }

        updateState(.disconnecting)

        // Cancel all characteristic streams
        for handler in characteristicStreams.values {
            handler.finish()
        }
        characteristicStreams.removeAll()

        // Cancel pending continuations
        connectionContinuation?.resume(throwing: CancellationError())
        connectionContinuation = nil
        serviceDiscoveryContinuation?.resume(throwing: CancellationError())
        serviceDiscoveryContinuation = nil

        for (_, continuation) in characteristicContinuations {
            continuation.resume(throwing: CancellationError())
        }
        characteristicContinuations.removeAll()
        characteristicContinuationTokens.removeAll()

        for (_, continuation) in writeContinuations {
            continuation.resume(throwing: CancellationError())
        }
        writeContinuations.removeAll()
        writeContinuationTokens.removeAll()

        rssiContinuation?.resume(throwing: CancellationError())
        rssiContinuation = nil
        rssiOperationId = nil

        // Disconnect
        centralManager.cancelPeripheralConnection(peripheral)
        updateState(.disconnected)

        logger.info("Disconnected from device \(self.deviceId)")
    }

    func isConnected() async -> Bool {
        peripheral.state == .connected
    }

    func ping() async -> Bool {
        guard peripheral.state == .connected else { return false }
        do {
            _ = try await readRSSI()
            return true
        } catch {
            logger.debug("Ping failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Characteristic Operations

    func getCharacteristicStream(
        serviceUUID: CBUUID,
        characteristicUUID: CBUUID
    ) -> AsyncThrowingStream<Data, Error> {
        let key = "\(serviceUUID.uuidString):\(characteristicUUID.uuidString)"

        // Return existing stream if available
        if let existing = characteristicStreams[key] {
            return existing.stream
        }

        // Create new stream handler
        let handler = CharacteristicStreamHandler()
        characteristicStreams[key] = handler

        // Set up characteristic notification
        Task {
            do {
                guard let characteristic = findCharacteristic(
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID
                ) else {
                    handler.finish(throwing: DeviceTransportError.characteristicNotFound(characteristicUUID))
                    return
                }

                peripheral.setNotifyValue(true, for: characteristic)
                logger.debug("Enabled notifications for \(characteristicUUID.uuidString)")
            }
        }

        return handler.stream
    }

    func readCharacteristic(
        serviceUUID: CBUUID,
        characteristicUUID: CBUUID
    ) async throws -> Data {
        guard !isDisposed else { throw DeviceTransportError.disposed }
        guard _state == .connected else { throw DeviceTransportError.notConnected }

        guard let characteristic = findCharacteristic(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID
        ) else {
            throw DeviceTransportError.characteristicNotFound(characteristicUUID)
        }

        let operationId = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            characteristicContinuations[characteristicUUID] = continuation
            characteristicContinuationTokens[characteristicUUID] = operationId
            peripheral.readValue(for: characteristic)
            DispatchQueue.main.asyncAfter(deadline: .now() + self.characteristicTimeout) { [weak self] in
                guard let self = self,
                      self.characteristicContinuationTokens[characteristicUUID] == operationId,
                      let continuation = self.characteristicContinuations.removeValue(forKey: characteristicUUID) else { return }
                self.characteristicContinuationTokens.removeValue(forKey: characteristicUUID)
                continuation.resume(throwing: DeviceTransportError.timeout)
            }
        }
    }

    func writeCharacteristic(
        data: Data,
        serviceUUID: CBUUID,
        characteristicUUID: CBUUID,
        withResponse: Bool
    ) async throws {
        guard !isDisposed else { throw DeviceTransportError.disposed }
        guard _state == .connected else { throw DeviceTransportError.notConnected }

        guard let characteristic = findCharacteristic(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID
        ) else {
            throw DeviceTransportError.characteristicNotFound(characteristicUUID)
        }

        let writeType: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse

        if withResponse {
            let operationId = UUID()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeContinuations[characteristicUUID] = continuation
                writeContinuationTokens[characteristicUUID] = operationId
                peripheral.writeValue(data, for: characteristic, type: writeType)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.characteristicTimeout) { [weak self] in
                    guard let self = self,
                          self.writeContinuationTokens[characteristicUUID] == operationId,
                          let continuation = self.writeContinuations.removeValue(forKey: characteristicUUID) else { return }
                    self.writeContinuationTokens.removeValue(forKey: characteristicUUID)
                    continuation.resume(throwing: DeviceTransportError.timeout)
                }
            }
        } else {
            peripheral.writeValue(data, for: characteristic, type: writeType)
        }
    }

    func dispose() async {
        guard !isDisposed else { return }
        isDisposed = true

        await disconnect()
        logger.debug("Transport disposed for device \(self.deviceId)")
    }

    // MARK: - Private Helpers

    private func updateState(_ newState: DeviceTransportState) {
        guard _state != newState else { return }
        _state = newState
        connectionStateSubject.send(newState)
    }

    private func findCharacteristic(serviceUUID: CBUUID, characteristicUUID: CBUUID) -> CBCharacteristic? {
        guard let service = discoveredServices.first(where: {
            $0.uuid.uuidString.lowercased() == serviceUUID.uuidString.lowercased()
        }) else {
            return nil
        }

        return service.characteristics?.first(where: {
            $0.uuid.uuidString.lowercased() == characteristicUUID.uuidString.lowercased()
        })
    }

    private func readRSSI() async throws -> Int {
        guard rssiContinuation == nil else {
            throw DeviceTransportError.connectionFailed("RSSI read already in progress")
        }

        let operationId = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            rssiContinuation = continuation
            rssiOperationId = operationId
            peripheral.readRSSI()
            DispatchQueue.main.asyncAfter(deadline: .now() + self.rssiTimeout) { [weak self] in
                guard let self = self,
                      self.rssiOperationId == operationId,
                      let continuation = self.rssiContinuation else { return }
                self.rssiContinuation = nil
                self.rssiOperationId = nil
                continuation.resume(throwing: DeviceTransportError.timeout)
            }
        }
    }

    /// Get all discovered services
    var services: [CBService] {
        discoveredServices
    }
}

// MARK: - CBPeripheralDelegate

extension BleTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            serviceDiscoveryContinuation?.resume(throwing: error)
        } else {
            serviceDiscoveryContinuation?.resume(returning: peripheral.services ?? [])
        }
        serviceDiscoveryContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logger.warning("Failed to discover characteristics for \(service.uuid): \(error.localizedDescription)")
        } else {
            logger.debug("Discovered \(service.characteristics?.count ?? 0) characteristics for \(service.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        // Handle pending read continuation
        if let continuation = characteristicContinuations.removeValue(forKey: uuid) {
            characteristicContinuationTokens.removeValue(forKey: uuid)
            if let error = error {
                continuation.resume(throwing: DeviceTransportError.readFailed(error.localizedDescription))
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
            return
        }

        // Handle stream notification
        let key = "\(characteristic.service?.uuid.uuidString ?? ""):\(uuid.uuidString)"
        if let handler = characteristicStreams[key], let value = characteristic.value {
            handler.yield(value)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        if let continuation = writeContinuations.removeValue(forKey: uuid) {
            writeContinuationTokens.removeValue(forKey: uuid)
            if let error = error {
                continuation.resume(throwing: DeviceTransportError.writeFailed(error.localizedDescription))
            } else {
                continuation.resume()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.warning("Failed to update notification state for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            logger.debug("Notification state updated for \(characteristic.uuid): \(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let continuation = rssiContinuation else { return }
        rssiContinuation = nil
        rssiOperationId = nil
        if let error = error {
            continuation.resume(throwing: DeviceTransportError.readFailed(error.localizedDescription))
        } else {
            continuation.resume(returning: RSSI.intValue)
        }
    }
}

// MARK: - Characteristic Stream Handler

/// Helper class to manage AsyncThrowingStream for characteristic notifications
private final class CharacteristicStreamHandler: @unchecked Sendable {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    let stream: AsyncThrowingStream<Data, Error>

    init() {
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        stream = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func finish(throwing error: Error? = nil) {
        if let error = error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }
}
