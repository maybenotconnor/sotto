import Foundation

/// WebDAV backup (design 2026-07-09): the first additional provider behind the sink seam.
/// Fresh per event like every sink — so settings changes apply on the very next event —
/// with all I/O forwarded to the shared WebDAVExecutor, whose strict FIFO prevents a
/// DELETE racing a slow PUT from resurrecting a deleted file on the server. `wifiOnly`
/// is snapshotted from settings at construction (per event), checked at execution.
struct WebDAVSyncSink: TranscriptSyncSink {
    let config: WebDAVConfig
    let wifiOnly: Bool
    var executor: WebDAVExecutor = .shared

    func upsert(_ segment: SyncSegment) async {
        await executor.upsert(segment, config: config, wifiOnly: wifiOnly)
    }

    func remove(day: String, basename: String) async {
        await executor.remove(day: day, basename: basename, config: config, wifiOnly: wifiOnly)
    }
}
