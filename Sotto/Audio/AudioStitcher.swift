import AVFoundation
import Foundation

/// Merge-conversations (spec 2026-07-06): concatenates same-pipeline .m4a segments into
/// one file. Passthrough preset first — every part comes from the same
/// CAFSegmentWriter→AAC pipeline, so a re-encode is normally unnecessary — with an AAC
/// re-encode fallback for environments that reject passthrough (seen on simulators).
/// Throws when any part is unreadable or both exports fail; callers treat any throw as
/// "abort the merge, nothing changed".
enum AudioStitcher {
    enum StitchError: Error {
        case noParts
        case unreadablePart(URL)
        case exportFailed(String)
    }

    static func stitch(parts: [URL], to output: URL) async throws {
        guard !parts.isEmpty else { throw StitchError.noParts }
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                throw StitchError.unreadablePart(part)
            }
            guard duration > .zero else { throw StitchError.unreadablePart(part) }
            do {
                try await composition.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            } catch {
                throw StitchError.unreadablePart(part)
            }
            cursor = cursor + duration
        }
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            do {
                try await export(composition, preset: AVAssetExportPresetAppleM4A, to: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
    }

    private static func export(
        _ composition: AVMutableComposition, preset: String, to output: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw StitchError.exportFailed("no export session for \(preset)")
        }
        try await session.export(to: output, as: .m4a)
    }
}
