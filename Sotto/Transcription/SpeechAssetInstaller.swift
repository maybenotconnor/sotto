import Foundation
import Speech

protocol SpeechAssetInstalling: Sendable {
    func assetsInstalled() async -> Bool
    /// Whether this device can run on-device transcription at all (Simulator and
    /// non-Apple-Intelligence hardware cannot — SPEC's model-download UI must never be shown
    /// there, since no download will ever succeed).
    func deviceSupported() async -> Bool
    /// Requests + downloads the speech model for the current locale, reporting 0…1.
    /// Throws on failure (incl. offline-at-first-run — SPEC requires explicit handling).
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
}

/// AssetInventory wrapper (SPEC "Model assets"): models are system-shared and often
/// pre-installed (Notes uses them) but never guaranteed. NEVER called from unit tests —
/// downloads are real; the app calls it from the Main screen / onboarding flow.
struct SpeechAssetInstaller: SpeechAssetInstalling {
    enum InstallerError: Error, Equatable { case unsupportedDevice, noRequestNeededButStillMissing }

    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func assetsInstalled() async -> Bool {
        await SpeechAnalyzerService.assetsInstalled(for: locale)
    }

    func deviceSupported() async -> Bool {
        SpeechTranscriber.isAvailable
    }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw InstallerError.unsupportedDevice }
        let base = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: base.transcriptionOptions,
            reportingOptions: base.reportingOptions,
            attributeOptions: base.attributeOptions)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) else {
            // Nothing to install — either already present, or the locale is unsupported.
            if await assetsInstalled() { return }
            throw InstallerError.noRequestNeededButStillMissing
        }
        // Progress observation: confirmed via `grep -n "AssetInstallationRequest" -A 6` on
        // Speech.framework's arm64-apple-ios-simulator.swiftinterface — the class exposes
        // `progress` (a Foundation `Progress`, via `ProgressReporting`) exactly as named
        // here; no ADAPT-ALLOWED deviation was needed. Poll it while downloadAndInstall() runs.
        let observation = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { observation.cancel() }
        try await request.downloadAndInstall()
        progress(1.0)
    }
}
