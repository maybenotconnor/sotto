import AVFoundation
import Foundation
import Speech

/// On-device transcription via SpeechAnalyzer/SpeechTranscriber (iOS 26). No permission
/// prompt exists for this API — SPEC: never add NSSpeechRecognitionUsageDescription.
/// Custom preset per SPEC: `.transcription` + `.audioTimeRange` for time-coded segments.
struct SpeechAnalyzerService: TranscriptionService {
    let backend = TranscriptionBackend.speechAnalyzer
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Language+region comparison, NOT full bcp47 strings: Locale.current often carries
    /// extension subtags (-u-rg-…, -u-ca-… from Region/calendar overrides) that never
    /// appear in the framework's plain identifiers — exact matching false-negatives and
    /// wrongly reports the installed model as missing (review finding).
    ///
    /// `locale.language.region` reads the region embedded in the language subtag itself
    /// (e.g. "US" in "en-US-u-rg-cazzzz") and ignores the `-u-rg-` override; the top-level
    /// `locale.region` honors that override instead (e.g. "CA" for the same identifier,
    /// verified via `swift -e` probe). We want the former, so it's tried first — the
    /// `locale.region` fallback only fires for locales lacking a region in the language
    /// subtag at all.
    static func matchKey(for locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? ""
        let region = locale.language.region?.identifier ?? locale.region?.identifier ?? ""
        return "\(language)-\(region)"
    }

    static func assetsInstalled(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let installed = await SpeechTranscriber.installedLocales
        let target = matchKey(for: locale)
        return installed.contains { matchKey(for: $0) == target }
    }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard await Self.assetsInstalled(for: locale) else { throw TranscriptionError.unavailable }

        let base = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: base.transcriptionOptions,
            reportingOptions: base.reportingOptions,
            attributeOptions: base.attributeOptions.union([.audioTimeRange]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile = try AVAudioFile(forReading: file)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        // Collect results concurrently with analysis; the sequence finishes after
        // finalizeAndFinishThroughEndOfInput().
        async let collected: [TranscriptionSegment] = {
            var segments: [TranscriptionSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.isEmpty else { continue }
                // ADAPT-ALLOWED zone, resolved: SpeechTranscriber.Result exposes the time
                // range directly as a non-optional `let range: CMTimeRange` (confirmed via
                // the Speech.swiftinterface — `grep -n "struct Result" -A 15` on
                // Speech.framework's arm64-apple-ios-simulator.swiftinterface), so no
                // optional binding or AttributedString-run fallback is needed.
                let range = result.range
                let start = range.start.seconds
                let end = range.end.seconds
                segments.append(TranscriptionSegment(
                    speaker: nil, text: text, startTime: start, endTime: end))
            }
            return segments
        }()

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // End the results sequence so the concurrent collection task terminates —
            // otherwise the async-let cleanup at scope exit hangs forever and wedges the
            // transcription queue's serial drain (review finding).
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let segments = try await collected
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: text, segments: segments, duration: duration, backend: backend)
    }
}
