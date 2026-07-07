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
final class CoreBluetoothOmiTransport: NSObject, OmiTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.decanlys.Sotto.omi-ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var targetDeviceID: UUID?
    private var eventContinuation: AsyncStream<OmiTransportEvent>.Continuation?
    private var scanContinuation: AsyncStream<OmiDiscovery>.Continuation?
    private var audioCharacteristic: CBCharacteristic?

    private var audioServiceUUID: CBUUID { CBUUID(string: OmiConstants.audioServiceUUID) }

    // MARK: OmiTransport

    func scan() async -> AsyncStream<OmiDiscovery> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmiDiscovery.self)
        queue.async { [self] in
            scanContinuation?.finish()
            scanContinuation = continuation
            ensureCentral()
            startScanIfPoweredOn()
        }
        return stream
    }

    func stopScan() async {
        queue.async { [self] in
            central?.stopScan()
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
        central.scanForPeripherals(withServices: [audioServiceUUID])
    }

    private func connectIfPoweredOn() {
        guard let central, central.state == .poweredOn, let targetDeviceID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [targetDeviceID]).first {
            peripheral = known
            known.delegate = self
            eventContinuation?.yield(.connecting)
            central.connect(known)
        } else {
            // Paired device iOS no longer knows (e.g. after Bluetooth reset): rediscover
            // by service UUID, connect on sight (didDiscover checks targetDeviceID).
            eventContinuation?.yield(.connecting)
            central.scanForPeripherals(withServices: [audioServiceUUID])
        }
    }
}

extension CoreBluetoothOmiTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanIfPoweredOn()   // no-op unless a scan consumer exists
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
        scanContinuation?.yield(OmiDiscovery(
            id: peripheral.identifier,
            name: peripheral.name ?? "Omi device",
            rssi: RSSI.intValue))
        if peripheral.identifier == targetDeviceID {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([
            audioServiceUUID,
            CBUUID(string: OmiConstants.batteryServiceUUID),
        ])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        eventContinuation?.yield(.disconnected)
        if peripheral.identifier == targetDeviceID {
            central.connect(peripheral)      // pending retry, completes on reappearance
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        audioCharacteristic = nil
        eventContinuation?.yield(.disconnected)
        if peripheral.identifier == targetDeviceID {
            eventContinuation?.yield(.connecting)
            central.connect(peripheral)      // immediate pending re-connect (spec)
        }
    }
}

extension CoreBluetoothOmiTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
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
