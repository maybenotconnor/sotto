import CoreBluetooth
import Foundation

/// Real OmiTransport over CoreBluetooth. Design notes:
/// - Scans by SERVICE UUID (never name — survives the Friend→Omi rebrand and is required
///   for background scanning).
/// - Maintains the connection: on disconnect it immediately re-issues connect(), which
///   CoreBluetooth holds pending until the peripheral reappears — no scan loop.
/// - State restoration identifier is set so iOS can relaunch the app on BLE activity
///   after a background kill (spec stretch S2; willRestoreState reattaches minimally).
/// - All CBCentralManagerDelegate callbacks arrive on `queue`; every mutation happens
///   there, and results cross to consumers only via Sendable AsyncStream yields.
/// - Session gating: `cancelPeripheralConnection` (in stopEvents) is not instantaneous, so a
///   cancelled session's callbacks can still arrive after a new session has started. Every
///   CBPeripheralDelegate callback and the CBCentralManagerDelegate connect/disconnect
///   callbacks are gated on `peripheral.identifier == targetDeviceID`; stopEvents nils
///   targetDeviceID first, so a stale callback for a peripheral no session cares about (or
///   for the previous device once a new one is targeted) is dropped outright. When the
///   stale callback is for the SAME device as the new session (identity check alone can't
///   distinguish old vs. new session), `didConnectThisSession` filters out the resulting
///   phantom disconnect.
/// - Scan ownership: the public scan() and the events()-driven rediscovery fallback share
///   one CBCentralManager scan. `publicScanActive`/`rediscoveryScanActive` track who wants
///   the radio on, so stopping one doesn't silently kill the other, and the radio only
///   stops once both are done.
final class CoreBluetoothOmiTransport: NSObject, OmiTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.decanlys.Sotto.omi-ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var targetDeviceID: UUID?
    private var eventContinuation: AsyncStream<OmiTransportEvent>.Continuation?
    private var scanContinuation: AsyncStream<WearableDiscovery>.Continuation?
    private var audioCharacteristic: CBCharacteristic?

    /// True once `didConnect` has fired for the current session's peripheral, until either a
    /// real disconnect is handled or the session ends. Distinguishes a genuine "connection
    /// dropped" disconnect from a phantom one delivered late for a connect that never
    /// completed (or belonged to a prior, cancelled session for the same device).
    private var didConnectThisSession = false

    /// Whether the public scan() consumer currently wants the radio scanning.
    private var publicScanActive = false
    /// Whether the events() reconnect-by-rediscovery fallback currently wants the radio scanning.
    private var rediscoveryScanActive = false

    private var audioServiceUUID: CBUUID { CBUUID(string: OmiConstants.audioServiceUUID) }

    // MARK: OmiTransport

    func scan() async -> AsyncStream<WearableDiscovery> {
        let (stream, continuation) = AsyncStream.makeStream(of: WearableDiscovery.self)
        queue.async { [self] in
            scanContinuation?.finish()
            scanContinuation = continuation
            publicScanActive = true
            ensureCentral()
            startScanIfPoweredOn()
        }
        return stream
    }

    func stopScan() async {
        queue.async { [self] in
            publicScanActive = false
            if !rediscoveryScanActive {
                central?.stopScan()
            }
            scanContinuation?.finish()
            scanContinuation = nil
        }
    }

    func events(deviceID: UUID) async -> AsyncStream<OmiTransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmiTransportEvent.self)
        queue.async { [self] in
            eventContinuation?.finish()
            eventContinuation = continuation
            targetDeviceID = deviceID
            didConnectThisSession = false
            ensureCentral()
            connectIfPoweredOn()
        }
        return stream
    }

    func stopEvents() async {
        queue.async { [self] in
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            targetDeviceID = nil
            audioCharacteristic = nil
            didConnectThisSession = false
            if rediscoveryScanActive {
                rediscoveryScanActive = false
                if !publicScanActive {
                    central?.stopScan()
                }
            }
            eventContinuation?.finish()
            eventContinuation = nil
        }
    }

    // MARK: internals (queue-confined)

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.decanlys.Sotto.omi"])
    }

    private func startScanIfPoweredOn() {
        guard let central, central.state == .poweredOn else { return }
        guard publicScanActive || rediscoveryScanActive else { return }
        central.scanForPeripherals(withServices: [audioServiceUUID])
    }

    private func connectIfPoweredOn() {
        guard let central, central.state == .poweredOn, let targetDeviceID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [targetDeviceID]).first {
            peripheral = known
            known.delegate = self
            didConnectThisSession = false
            eventContinuation?.yield(.connecting)
            central.connect(known)
        } else {
            // Paired device iOS no longer knows (e.g. after Bluetooth reset): rediscover
            // by service UUID, connect on sight (didDiscover checks targetDeviceID).
            rediscoveryScanActive = true
            eventContinuation?.yield(.connecting)
            central.scanForPeripherals(withServices: [audioServiceUUID])
        }
    }
}

extension CoreBluetoothOmiTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanIfPoweredOn()   // no-op unless a scan consumer (public or rediscovery) exists
            connectIfPoweredOn()
        case .poweredOff:
            eventContinuation?.yield(.bluetoothUnavailable(.poweredOff))
        case .unauthorized:
            eventContinuation?.yield(.bluetoothUnavailable(.unauthorized))
        case .unsupported:
            eventContinuation?.yield(.bluetoothUnavailable(.unsupported))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Minimal S2 support: reattach restored peripherals so a background BLE relaunch
        // has a delegate. Full pipeline restart from restoration is user-verified (Task 13).
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            peripheral = restored.first
            peripheral?.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if publicScanActive {
            scanContinuation?.yield(WearableDiscovery(
                id: peripheral.identifier,
                name: peripheral.name ?? "Omi device",
                rssi: RSSI.intValue,
                kind: .omi))
        }
        if peripheral.identifier == targetDeviceID {
            rediscoveryScanActive = false
            if !publicScanActive {
                central.stopScan()
            }
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == targetDeviceID else { return }
        didConnectThisSession = true
        peripheral.discoverServices([
            audioServiceUUID,
            CBUUID(string: OmiConstants.batteryServiceUUID),
        ])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        eventContinuation?.yield(.disconnected)
        central.connect(peripheral)      // pending retry, completes on reappearance
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        audioCharacteristic = nil
        if didConnectThisSession {
            didConnectThisSession = false
            eventContinuation?.yield(.disconnected)
            eventContinuation?.yield(.connecting)
            central.connect(peripheral)      // immediate pending re-connect (spec)
        }
    }
}

extension CoreBluetoothOmiTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        for service in peripheral.services ?? [] {
            if service.uuid == audioServiceUUID {
                peripheral.discoverCharacteristics([
                    CBUUID(string: OmiConstants.audioDataCharacteristicUUID),
                    CBUUID(string: OmiConstants.codecCharacteristicUUID),
                ], for: service)
            } else if service.uuid == CBUUID(string: OmiConstants.batteryServiceUUID) {
                peripheral.discoverCharacteristics(
                    [CBUUID(string: OmiConstants.batteryLevelCharacteristicUUID)], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: OmiConstants.codecCharacteristicUUID):
                peripheral.readValue(for: characteristic)   // codec FIRST — gates decode setup
            case CBUUID(string: OmiConstants.audioDataCharacteristicUUID):
                audioCharacteristic = characteristic        // notify enabled after codec read
            case CBUUID(string: OmiConstants.batteryLevelCharacteristicUUID):
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)   // newer fw notifies
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: OmiConstants.codecCharacteristicUUID):
            let codecValue = value.first ?? OmiConstants.codecOpusAt16kHz
            eventContinuation?.yield(.connected(codecValue: codecValue))
            if let audioCharacteristic {
                peripheral.setNotifyValue(true, for: audioCharacteristic)
            }
        case CBUUID(string: OmiConstants.audioDataCharacteristicUUID):
            eventContinuation?.yield(.audioNotification(value))
        case CBUUID(string: OmiConstants.batteryLevelCharacteristicUUID):
            if let level = value.first {
                eventContinuation?.yield(.batteryLevel(Int(level)))
            }
        default:
            break
        }
    }
}
