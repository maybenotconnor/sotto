import SwiftUI

/// Settings "Pair Omi Device…" (Task 11): scans for Omi devices (by service UUID, see
/// `CoreBluetoothOmiTransport`) and pairs the tapped one.
///
/// The sheet owns its transport's scan lifecycle: relying on cancellation of the `.task` alone
/// wouldn't stop Core Bluetooth from scanning (the `for await` loop only ends when the stream
/// itself finishes, and we want scanning to actually stop, not just the loop to stop consuming
/// it), so `withTaskCancellationHandler` explicitly calls `stopScan()` when the sheet's `.task`
/// is cancelled (dismiss or cancel) — otherwise Core Bluetooth would keep scanning in the
/// background for as long as the transport instance lives.
struct OmiPairSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var discoveries: [OmiDiscovery] = []

    var body: some View {
        NavigationStack {
            List {
                if discoveries.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for Omi devices nearby…").foregroundStyle(.secondary)
                    }
                }
                ForEach(discoveries) { discovery in
                    Button {
                        Task {
                            await model.pairOmi(discovery)
                            dismiss()
                        }
                    } label: {
                        LabeledContent(discovery.name, value: "\(discovery.rssi) dBm")
                    }
                }
            }
            .navigationTitle("Pair Omi")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            let transport = model.makeOmiScanTransport()
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
