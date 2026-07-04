import Foundation

/// SPEC "Transcription layer": persisted queue, never inline. Serial worker; drains
/// whenever the app runs; leftovers drain on next launch/foreground. Also the new home of
/// the CAF→m4a transcode (M3 review Critical #1 — moved OFF the interruption window).
actor TranscriptionQueue {
    private let storeURL: URL
    private let service: any TranscriptionService
    private let maxAttempts: Int
    private(set) var jobs: [TranscriptionJob] = []
    private var draining = false

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

    func drain() async {
        guard !draining else { return }   // serial: one worker at a time
        draining = true
        defer { draining = false }

        // Loop until quiescent: jobs enqueued during an in-flight pass (actor reentrancy
        // at the transcribe await) are picked up by the next pass instead of stranding.
        while let index = jobs.firstIndex(where: { $0.state == .pending }) {
            let before = jobs[index]
            await step(index)
            // Progress guarantee: step() always mutates the job (state, attempts, or
            // cafURL) — if it ever didn't, bail rather than spin.
            if jobs.indices.contains(index), jobs[index] == before { break }
        }
    }

    /// Worker step for one job: (1) ensure the m4a exists — transcode if the CAF is still
    /// there, tolerate a CAF already salvaged by the launch sweep, fail if both are gone.
    /// (2) transcribe the m4a and write the markdown transcript. Any throw increments
    /// `attempts` and fails the job only once `maxAttempts` is reached; either way `persist()`
    /// runs before returning so this never crashes the drain loop.
    private func step(_ index: Int) async {
        // Phase 1: ensure the m4a exists (deferred transcode; self-heals with salvage).
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
                    return
                }
            } else if m4aExists {
                jobs[index].cafURL = nil   // launch salvage got here first — fine
            } else {
                jobs[index].state = .failed
                persist()
                return
            }
            persist()
        }

        // Phase 2: transcribe + write the transcript.
        do {
            let result = try await service.transcribe(file: jobs[index].m4aURL)
            _ = try TranscriptMarkdownWriter.write(result: result, job: jobs[index])
            jobs[index].state = .done
        } catch {
            fail(index)
        }
        persist()
    }

    private func fail(_ index: Int) {
        jobs[index].attempts += 1
        if jobs[index].attempts >= maxAttempts {
            jobs[index].state = .failed
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
