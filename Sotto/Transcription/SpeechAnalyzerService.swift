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

    static func assetsInstalled(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
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

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let segments = try await collected
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: text, segments: segments, duration: duration, backend: backend)
    }
}
