import SwiftUI

/// Settings device pairing (Task 11): scans for devices of one wearable family (by
/// service UUID — see the family's transport, e.g. `CoreBluetoothOmiTransport`) and
/// pairs the tapped one.
///
/// The sheet owns its transport's scan lifecycle: relying on cancellation of the `.task` alone
/// wouldn't stop Core Bluetooth from scanning (the `for await` loop only ends when the stream
/// itself finishes, and we want scanning to actually stop, not just the loop to stop consuming
/// it), so `withTaskCancellationHandler` explicitly calls `stopScan()` when the sheet's `.task`
/// is cancelled (dismiss or cancel) — otherwise Core Bluetooth would keep scanning in the
/// background for as long as the transport instance lives.
struct PairDeviceSheet: View {
    let model: AppModel
    /// The device family this sheet scans for. One kind per presentation — a future
    /// multi-device picker unions per-kind scans instead of widening this sheet.
    let kind: DeviceKind
    @Environment(\.dismiss) private var dismiss
    @State private var discoveries: [WearableDiscovery] = []

    var body: some View {
        NavigationStack {
            List {
                if discoveries.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for \(kind.displayName) devices nearby…").foregroundStyle(.secondary)
                    }
                }
                ForEach(discoveries) { discovery in
                    Button {
                        Task {
                            await model.pairDevice(discovery)
                            dismiss()
                        }
                    } label: {
                        LabeledContent(discovery.name, value: "\(discovery.rssi) dBm")
                    }
                }
            }
            .navigationTitle("Pair \(kind.displayName)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            let transport = model.makeScanTransport(for: kind)
            await withTaskCancellationHandler {
                for await discovery in await transport.scan() {
                    // Dedup: CoreBluetooth's didDiscover fires repeatedly for the same
                    // peripheral as advertisements arrive (RSSI updates etc).
                    if !discoveries.contains(where: { $0.id == discovery.id }) {
                        discoveries.append(discovery)
                    }
                }
            } onCancel: {
                Task { await transport.stopScan() }
            }
        }
    }
}
