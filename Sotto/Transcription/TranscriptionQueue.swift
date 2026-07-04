import AVFoundation
import Foundation
import os

/// The result of one job's terminal transition, delivered synchronously (no suspension) so
/// the queue's actor isolation is never re-entered mid-notification. Fired only when a job
/// reaches `.done` (with its `result`) or `.failed` (nil) — never for `.blocked` outcomes or
/// still-pending retries (M5: consumed by retention + the day index).
struct JobTransition: Sendable {
    let job: TranscriptionJob            // state already updated (done/failed)
    let result: TranscriptionResult?     // non-nil on done
    let notes: PostProcessingResult?     // nil on failure/no processor (best-effort, M8)
}

/// SPEC "Transcription layer": persisted queue, never inline. Serial worker; drains
/// whenever the app runs; leftovers drain on next launch/foreground. Also the new home of
/// the CAF→m4a transcode (M3 review Critical #1 — moved OFF the interruption window).
actor TranscriptionQueue {
    private let storeURL: URL
    private let serviceProvider: @Sendable () -> any TranscriptionService
    private let postProcessorProvider: (@Sendable () -> (any PostProcessor)?)?
    private let maxAttempts: Int
    private let rootDirectory: URL
    private(set) var jobs: [TranscriptionJob] = []
    private var draining = false
    private var transitionHandler: (@Sendable (JobTransition) -> Void)?
    private let logger = Logger(subsystem: "com.decanlys.Sotto", category: "TranscriptionQueue")

    var pendingCount: Int { jobs.filter { $0.state == .pending }.count }

    /// `rootDirectory` relativizes persisted `caf`/`m4a` paths (M4 carryover — a container
    /// move, e.g. an iOS-managed app-data migration, invalidates absolute paths). Defaults
    /// to the Documents directory, the SPEC "File output" root everything else lives under.
    ///
    /// `serviceProvider` is resolved FRESH per job (in `step`, not here) — a backend change
    /// (Deepgram key added, M6 settings toggle) applies to all future jobs without
    /// reconstructing the queue (SPEC "changes affect only future segments").
    init(
        storeURL: URL? = nil, serviceProvider: @escaping @Sendable () -> any TranscriptionService,
        maxAttempts: Int = 3, rootDirectory: URL? = nil,
        postProcessorProvider: (@Sendable () -> (any PostProcessor)?)? = nil
    ) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.storeURL = support.appendingPathComponent("transcription-jobs.json")
        }
        self.serviceProvider = serviceProvider
        self.postProcessorProvider = postProcessorProvider
        self.maxAttempts = maxAttempts
        let resolvedRoot = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootDirectory = resolvedRoot
        if let data = try? Data(contentsOf: self.storeURL) {
            if let persisted = try? JSONDecoder().decode([PersistedJob].self, from: data) {
                jobs = persisted.map { $0.job(root: resolvedRoot) }
            } else if let loaded = try? JSONDecoder().decode([TranscriptionJob].self, from: data) {
                jobs = loaded   // safety-net fallback; PersistedJob already tolerates v1 shape
            } else {
                logger.error("transcription-jobs.json exists but failed to decode under both the v2 and legacy v1 formats — starting with an empty queue")
            }
        }
    }

    /// Fixed-service convenience: wraps `service` in a constant provider so every existing
    /// call site (tests included) keeps compiling unchanged.
    init(
        storeURL: URL? = nil, service: any TranscriptionService, maxAttempts: Int = 3,
        rootDirectory: URL? = nil,
        postProcessorProvider: (@Sendable () -> (any PostProcessor)?)? = nil
    ) {
        self.init(
            storeURL: storeURL, serviceProvider: { service }, maxAttempts: maxAttempts,
            rootDirectory: rootDirectory, postProcessorProvider: postProcessorProvider)
    }

    func setTransitionHandler(_ handler: @escaping @Sendable (JobTransition) -> Void) {
        transitionHandler = handler
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
    /// the audio; speechDuration unknown → duration. Returns the created job (nil on
    /// duplicate) so a caller (AppModel) can mirror it into the day index without
    /// re-parsing the store layout itself.
    @discardableResult
    func enqueueSalvaged(m4aURL: URL) -> TranscriptionJob? {
        guard !jobs.contains(where: { $0.m4aURL == m4aURL }) else { return nil }
        let (startDate, duration) = Self.parseStoreLayoutMetadata(m4aURL: m4aURL)
        let job = TranscriptionJob(
            id: UUID(), cafURL: nil, m4aURL: m4aURL, startDate: startDate,
            duration: duration, speechDuration: duration, attempts: 0, state: .pending)
        jobs.append(job)
        persist()
        return job
    }

    /// Store-layout fallback shared by `enqueueSalvaged` and `retranscribe`: parses
    /// `<yyyy-MM-dd>/<HH-mm-ss>.m4a` into a start date and reads the audio's own duration —
    /// used whenever no prior job exists to carry those fields forward from.
    private static func parseStoreLayoutMetadata(m4aURL: URL) -> (startDate: Date, duration: TimeInterval) {
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
        return (startDate, duration)
    }

    /// Failed-row retry (SPEC detail/list views): resets a `.failed` job to `.pending` with
    /// attempts 0 and kicks a drain.
    func retry(jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .failed else { return }
        jobs[index].state = .pending
        jobs[index].attempts = 0
        persist()
        await drain()
    }

    /// Row-level retry keyed by URL (List/Detail views track segments by m4a, not job IDs) —
    /// finds the matching `.failed` job (if any) and delegates to `retry(jobID:)`.
    func retry(m4aURL: URL) async {
        guard let job = jobs.first(where: { $0.m4aURL == m4aURL && $0.state == .failed }) else { return }
        await retry(jobID: job.id)
    }

    /// SPEC Detail view "Re-transcribe with current backend": ANY existing job for this URL
    /// (done, failed, or pending) is REPLACED — not appended alongside — with a fresh
    /// `.pending` job, then drained immediately. `cafURL` is nil (by the time a segment has a
    /// job at all, its CAF is long gone); `startDate`/`duration`/`speechDuration` carry over
    /// from the old job when one existed, else fall back to parsing the store layout exactly
    /// like `enqueueSalvaged` does.
    func retranscribe(m4aURL: URL) async {
        let old = jobs.first(where: { $0.m4aURL == m4aURL })
        jobs.removeAll { $0.m4aURL == m4aURL }

        let startDate: Date
        let duration: TimeInterval
        let speechDuration: TimeInterval
        if let old {
            startDate = old.startDate
            duration = old.duration
            speechDuration = old.speechDuration
        } else {
            let parsed = Self.parseStoreLayoutMetadata(m4aURL: m4aURL)
            startDate = parsed.startDate
            duration = parsed.duration
            speechDuration = parsed.duration
        }

        jobs.append(TranscriptionJob(
            id: UUID(), cafURL: nil, m4aURL: m4aURL, startDate: startDate,
            duration: duration, speechDuration: speechDuration, attempts: 0, state: .pending))
        persist()
        await drain()
    }

    /// Segment deletion (List swipe-delete / Detail delete): drops any job for this URL
    /// outright — the audio is gone, so no drain follows.
    func removeJob(m4aURL: URL) {
        jobs.removeAll { $0.m4aURL == m4aURL }
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
                transitionHandler?(JobTransition(job: jobs[index], result: nil, notes: nil))
                return .progressed
            }
            persist()
        }

        // Phase 2: transcribe + write the transcript. No suspension happens between here
        // and the transcribe call below, so `index` is still valid for reading `m4aURL`;
        // it's re-resolved via `jobID` immediately after that await (the queue's only
        // suspension point) since a future job-removal (M5 retention) must not corrupt it.
        do {
            let service = serviceProvider()
            let result = try await service.transcribe(file: jobs[index].m4aURL)
            guard let doneIndex = jobs.firstIndex(where: { $0.id == jobID }) else {
                return .progressed
            }
            // delete-mid-transcription: never resurrect a deleted conversation. If the user
            // deleted this segment while the transcribe() await above was in flight, the job
            // itself may already be gone (handled by the guard above, via `removeJob`) — but
            // if the job survived and only the m4a was removed, don't write a markdown
            // transcript back into a directory the user just cleared out.
            guard FileManager.default.fileExists(atPath: jobs[doneIndex].m4aURL.path) else {
                jobs.removeAll { $0.id == jobID }
                persist()
                return .progressed
            }
            // M8 post-processing: best-effort meeting notes, run while the m4a is confirmed to
            // still exist. This is another suspension point — a concurrent `removeJob` (row
            // deletion) during the await must not corrupt `doneIndex`, so it's re-resolved via
            // `jobID` immediately after, exactly like the transcribe() await above. Any throw
            // (model unavailable, transcript too short, provider absent) degrades to
            // `notes = nil` — never fails the job, never blocks the markdown write that follows.
            let audioURL = jobs[doneIndex].m4aURL
            let notes = try? await postProcessorProvider?()?.process(transcript: result, audio: audioURL)
            guard let finalIndex = jobs.firstIndex(where: { $0.id == jobID }) else {
                return .progressed
            }
            _ = try TranscriptMarkdownWriter.write(result: result, notes: notes, job: jobs[finalIndex])
            jobs[finalIndex].state = .done
            transitionHandler?(JobTransition(job: jobs[finalIndex], result: result, notes: notes))
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

    /// Burns one attempt; only marks `.failed` — and only fires the transition handler —
    /// once `maxAttempts` is reached. A retry that stays `.pending` is not a transition.
    private func fail(_ index: Int) {
        jobs[index].attempts += 1
        let reachedThreshold = jobs[index].attempts >= maxAttempts
        if reachedThreshold {
            jobs[index].state = .failed
        }
        persist()
        if reachedThreshold {
            transitionHandler?(JobTransition(job: jobs[index], result: nil, notes: nil))
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(jobs.map { PersistedJob(job: $0, root: rootDirectory) })
            try data.write(to: storeURL, options: .atomic)
        } catch {
            logger.error("Failed to persist transcription queue: \(error.localizedDescription)")
        }
    }

    /// Persistence format v2: paths are relative to `rootDirectory` when the job's files live
    /// under it (the common case), else stored absolute (M5 — a container move, e.g. an
    /// iOS-managed app-data migration, must not orphan in-flight jobs). Tolerates the v1
    /// format — `TranscriptionJob`'s own Codable conformance, i.e. absolute `cafURL`/`m4aURL`
    /// `URL` fields — written by builds before this change, by custom-decoding both shapes.
    private struct PersistedJob: Codable {
        let id: UUID
        let cafPath: String?
        let m4aPath: String
        let startDate: Date
        let duration: TimeInterval
        let speechDuration: TimeInterval
        let attempts: Int
        let state: TranscriptionJob.State

        enum CodingKeys: String, CodingKey {
            case id, cafPath, m4aPath, startDate, duration, speechDuration, attempts, state
            case cafURL, m4aURL
        }

        init(job: TranscriptionJob, root: URL) {
            id = job.id
            cafPath = job.cafURL.map { Self.relativize($0, root: root) }
            m4aPath = Self.relativize(job.m4aURL, root: root)
            startDate = job.startDate
            duration = job.duration
            speechDuration = job.speechDuration
            attempts = job.attempts
            state = job.state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            startDate = try container.decode(Date.self, forKey: .startDate)
            duration = try container.decode(TimeInterval.self, forKey: .duration)
            speechDuration = try container.decode(TimeInterval.self, forKey: .speechDuration)
            attempts = try container.decode(Int.self, forKey: .attempts)
            state = try container.decode(TranscriptionJob.State.self, forKey: .state)
            if let path = try container.decodeIfPresent(String.self, forKey: .m4aPath) {
                m4aPath = path
                cafPath = try container.decodeIfPresent(String.self, forKey: .cafPath)
            } else {
                // v1: absolute URL-encoded fields (no cafPath/m4aPath keys present at all).
                let m4a = try container.decode(URL.self, forKey: .m4aURL)
                m4aPath = m4a.path
                cafPath = try container.decodeIfPresent(URL.self, forKey: .cafURL)?.path
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(cafPath, forKey: .cafPath)
            try container.encode(m4aPath, forKey: .m4aPath)
            try container.encode(startDate, forKey: .startDate)
            try container.encode(duration, forKey: .duration)
            try container.encode(speechDuration, forKey: .speechDuration)
            try container.encode(attempts, forKey: .attempts)
            try container.encode(state, forKey: .state)
        }

        static func relativize(_ url: URL, root: URL) -> String {
            let path = url.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/")
                ? String(path.dropFirst(rootPath.count + 1))
                : path
        }

        func job(root: URL) -> TranscriptionJob {
            func resolve(_ path: String) -> URL {
                path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : root.appendingPathComponent(path)
            }
            return TranscriptionJob(
                id: id, cafURL: cafPath.map(resolve), m4aURL: resolve(m4aPath),
                startDate: startDate, duration: duration, speechDuration: speechDuration,
                attempts: attempts, state: state)
        }
    }
}
