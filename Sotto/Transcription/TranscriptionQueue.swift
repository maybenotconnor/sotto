import AVFoundation
import Foundation
import os

/// SPEC "Transcription layer": persisted queue, never inline. Serial worker; drains
/// whenever the app runs; leftovers drain on next launch/foreground. Also the new home of
/// the CAF→m4a transcode (M3 review Critical #1 — moved OFF the interruption window).
actor TranscriptionQueue {
    private let storeURL: URL
    private let service: any TranscriptionService
    private let maxAttempts: Int
    private(set) var jobs: [TranscriptionJob] = []
    private var draining = false
    private let logger = Logger(subsystem: "com.decanlys.Sotto", category: "TranscriptionQueue")

    var pendingCount: Int { jobs.filter { $0.state == .pending }.count }

    init(storeURL: URL? = nil, service: any TranscriptionService, maxAttempts: Int = 3) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.storeURL = support.appendingPathComponent("transcription-jobs.json")
        }
        self.service = service
        self.maxAttempts = maxAttempts
        if let data = try? Data(contentsOf: self.storeURL),
           let loaded = try? JSONDecoder().decode([TranscriptionJob].self, from: data) {
            jobs = loaded
        }
    }

    func enqueue(_ segment: FinalizedSegment) {
        jobs.append(TranscriptionJob(
            id: UUID(), cafURL: segment.cafURL, m4aURL: segment.m4aURL,
            startDate: segment.startDate, duration: segment.duration,
            speechDuration: segment.speechDuration, attempts: 0, state: .pending))
        persist()
    }

    /// SPEC "Recording writer": salvaged audio must be transcribed, not just recovered.
    /// startDate parsed from the store layout (<yyyy-MM-dd>/<HH-mm-ss>.m4a); duration from
    /// the audio; speechDuration unknown → duration.
    func enqueueSalvaged(m4aURL: URL) {
        guard !jobs.contains(where: { $0.m4aURL == m4aURL }) else { return }
        let day = m4aURL.deletingLastPathComponent().lastPathComponent
        let time = m4aURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let startDate = formatter.date(from: "\(day) \(String(time.prefix(8)))") ?? Date()
        let duration: TimeInterval = (try? AVAudioFile(forReading: m4aURL)).map {
            Double($0.length) / $0.processingFormat.sampleRate
        } ?? 0
        jobs.append(TranscriptionJob(
            id: UUID(), cafURL: nil, m4aURL: m4aURL, startDate: startDate,
            duration: duration, speechDuration: duration, attempts: 0, state: .pending))
        persist()
    }

    private enum StepOutcome {
        case progressed          // job mutated (done, failed, attempts++, cafURL cleared)
        case blocked             // environmental: nothing about the job changed; stop draining
    }

    private func isEnvironmental(_ error: Error) -> Bool {
        // Environmental = retrying immediately cannot help; the JOB is fine.
        // Content failures (bad audio, 4xx, parse errors) burn attempts as before.
        if let transcription = error as? TranscriptionError {
            switch transcription {
            case .unavailable, .missingAPIKey: return true
            case .badResponse, .emptyAudio: return false
            }
        }
        return error is URLError
    }

    func drain() async {
        guard !draining else { return }   // serial: one worker at a time
        draining = true
        defer { draining = false }

        // Loop until quiescent: jobs enqueued during an in-flight pass (actor reentrancy
        // at the transcribe await) are picked up by the next pass instead of stranding. An
        // environmental block (assets not installed, offline) stops the drain outright —
        // retrying immediately cannot help, and later pending jobs shouldn't be probed
        // pointlessly either; a later drain (next launch/foreground/enqueue) retries.
        while let jobID = jobs.first(where: { $0.state == .pending })?.id {
            if await step(jobID) == .blocked { break }
        }
    }

    /// Worker step for one job: (1) ensure the m4a exists — transcode if the CAF is still
    /// there, tolerate a CAF already salvaged by the launch sweep, fail if both are gone.
    /// (2) transcribe the m4a and write the markdown transcript. Content failures increment
    /// `attempts` and fail the job only once `maxAttempts` is reached; environmental
    /// failures (Fix 1) leave the job untouched and signal the drain to stop. Looked up by
    /// ID (not index) and re-resolved after the transcribe await — a future job-removal
    /// (M5 retention) must not corrupt indices.
    private func step(_ jobID: UUID) async -> StepOutcome {
        // Phase 1: ensure the m4a exists (deferred transcode; self-heals with salvage).
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return .progressed }
        if let caf = jobs[index].cafURL {
            let cafExists = FileManager.default.fileExists(atPath: caf.path)
            let m4aExists = FileManager.default.fileExists(atPath: jobs[index].m4aURL.path)
            if cafExists {
                do {
                    try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: jobs[index].m4aURL)
                    try? FileManager.default.removeItem(at: caf)
                    jobs[index].cafURL = nil
                } catch {
                    fail(index)
                    return .progressed
                }
            } else if m4aExists {
                jobs[index].cafURL = nil   // launch salvage got here first — fine
            } else {
                jobs[index].state = .failed
                persist()
                return .progressed
            }
            persist()
        }

        // Phase 2: transcribe + write the transcript. No suspension happens between here
        // and the transcribe call below, so `index` is still valid for reading `m4aURL`;
        // it's re-resolved via `jobID` immediately after that await (the queue's only
        // suspension point) since a future job-removal (M5 retention) must not corrupt it.
        do {
            let result = try await service.transcribe(file: jobs[index].m4aURL)
            guard let doneIndex = jobs.firstIndex(where: { $0.id == jobID }) else {
                return .progressed
            }
            _ = try TranscriptMarkdownWriter.write(result: result, job: jobs[doneIndex])
            jobs[doneIndex].state = .done
        } catch {
            if isEnvironmental(error) {
                return .blocked   // stays .pending, attempts untouched; a later drain retries
            }
            guard let failIndex = jobs.firstIndex(where: { $0.id == jobID }) else {
                return .progressed
            }
            fail(failIndex)
        }
        persist()
        return .progressed
    }

    private func fail(_ index: Int) {
        jobs[index].attempts += 1
        if jobs[index].attempts >= maxAttempts {
            jobs[index].state = .failed
        }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            logger.error("Failed to persist transcription queue: \(error.localizedDescription)")
        }
    }
}
