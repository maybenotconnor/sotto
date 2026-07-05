import Foundation

/// The heart of M2: consumes 256 ms chunks, drives the five-state machine, owns the
/// pre-roll buffer, the VAD detector, and the segment writer — all off the MainActor.
/// Silence timing is measured in SAMPLE COUNTS (chunks arrive continuously while the
/// mic is live), so transitions are deterministic and wall-clock-free.
actor RecorderStateMachine: SegmentRecording {
    private let detector: any SpeechDetecting
    private let writerFactory: any SegmentWriterFactory
    private let store: SegmentStore
    private let config: RecorderConfig

    private var state: RecorderState = .idle
    private var preRoll: PreRollBuffer
    private var writer: (any SegmentWriting)?
    private var segmentStartDate: Date?
    private var lastSpeechEndSampleCount = 0    // written samples at the most recent speechEnd
    private var samplesSinceLastSpeech = 0
    private var finalizedCount = 0
    private var lastEvent: String?
    private var diskGuardActive = false
    private var segmentHandler: (@Sendable (FinalizedSegment) -> Void)?

    init(
        detector: any SpeechDetecting,
        writerFactory: any SegmentWriterFactory,
        store: SegmentStore,
        config: RecorderConfig = RecorderConfig()
    ) {
        precondition(config.preRollCapacity > 0, "preRollCapacity must be positive")
        precondition(config.silenceTimeout > 0, "silenceTimeout must be positive")
        precondition(config.maxSegmentDuration > 0, "maxSegmentDuration must be positive")
        self.detector = detector
        self.writerFactory = writerFactory
        self.store = store
        self.config = config
        self.preRoll = PreRollBuffer(capacity: config.preRollCapacity)
    }

    func setSegmentHandler(_ handler: @escaping @Sendable (FinalizedSegment) -> Void) {
        segmentHandler = handler
    }

    func beginListening() -> RecorderSnapshot {
        state = .listening
        lastEvent = nil
        diskGuardActive = false
        return snapshot()
    }

    func process(_ chunk: AudioChunk) async -> RecorderSnapshot {
        guard state == .listening || state == .recording || state == .silence else {
            return snapshot()
        }

        let event: SpeechEvent?
        do {
            event = try await detector.process(chunk)
        } catch {
            lastEvent = "VAD error: \(error)"
            if state == .listening {
                preRoll.append(chunk.samples)
            } else {
                write(chunk.samples)   // never drop audio mid-segment over a VAD hiccup
                if state == .silence {
                    samplesSinceLastSpeech += chunk.samples.count
                    if secondsOf(samplesSinceLastSpeech) >= config.silenceTimeout {
                        finalizeSegment()
                    }
                }
                rotateIfBeyondMaxDuration()
            }
            return snapshot()
        }

        switch state {
        case .listening:
            preRoll.append(chunk.samples)
            if case .speechStart = event {
                openSegment()
            }

        case .recording:
            write(chunk.samples)
            if case .speechEnd = event {
                state = .silence
                samplesSinceLastSpeech = 0
                lastSpeechEndSampleCount = writer?.writtenSampleCount ?? 0
            }
            rotateIfBeyondMaxDuration()

        case .silence:
            write(chunk.samples)
            samplesSinceLastSpeech += chunk.samples.count
            if case .speechStart = event {
                state = .recording
            } else if secondsOf(samplesSinceLastSpeech) >= config.silenceTimeout {
                finalizeSegment()
            }
            rotateIfBeyondMaxDuration()

        case .idle, .interrupted:
            break
        }
        return snapshot()
    }

    func finishAndFinalize() async -> RecorderSnapshot {
        if writer != nil {
            if state == .recording {
                lastSpeechEndSampleCount = writer?.writtenSampleCount ?? 0
            }
            finalizeSegment()
        }
        state = .idle
        preRoll.removeAll()
        await detector.reset()
        return snapshot()
    }

    func markInterrupted() async -> RecorderSnapshot {
        if writer != nil {
            if state == .recording {
                lastSpeechEndSampleCount = writer?.writtenSampleCount ?? 0
            }
            finalizeSegment()
        }
        state = .interrupted
        preRoll.removeAll()
        await detector.reset()
        lastEvent = "Interrupted"
        return snapshot()
    }

    // MARK: - Segment lifecycle

    private func openSegment() {
        guard store.freeDiskBytes() >= config.minFreeDiskBytes else {
            lastEvent = "Low disk space — not recording"
            diskGuardActive = true
            return
        }
        let startDate = Date()
        do {
            let newWriter = try writerFactory.makeWriter(startDate: startDate)
            writer = newWriter
            segmentStartDate = startDate
            lastSpeechEndSampleCount = 0
            samplesSinceLastSpeech = 0
            let flush = preRoll.snapshot()
            preRoll.removeAll()
            try newWriter.append(flush)
            state = .recording
            lastEvent = "Recording"
            diskGuardActive = false
        } catch {
            writer = nil
            // no writer ⇒ no open segment; a stale date would pin a phantom live row
            segmentStartDate = nil
            lastEvent = "Could not start segment: \(error)"
        }
    }

    private func write(_ samples: [Float]) {
        do {
            try writer?.append(samples)
        } catch {
            lastEvent = "Write failed: \(error)"
        }
    }

    private func rotateIfBeyondMaxDuration() {
        guard let writer,
              secondsOf(writer.writtenSampleCount) >= config.maxSegmentDuration else { return }
        // Force-finalize and continue seamlessly in a new segment (SPEC max-segment guard).
        let resumeState = state
        lastSpeechEndSampleCount = writer.writtenSampleCount
        finalizeSegment()
        openSegment()
        // NB: must check `self.writer`, not the `writer` local the guard above bound —
        // that local stays non-nil for the rest of this scope regardless of whether the
        // openSegment() attempt above actually produced a new writer.
        if self.writer != nil {
            state = resumeState == .silence ? .silence : .recording
        }
    }

    private func finalizeSegment() {
        guard let closing = writer, let startDate = segmentStartDate else { return }
        writer = nil
        segmentStartDate = nil
        state = .listening

        let speechDuration = secondsOf(lastSpeechEndSampleCount)
        if speechDuration < config.minSegmentSpeechDuration {
            closing.discard()
            lastEvent = "Discarded short segment (\(String(format: "%.1f", speechDuration)) s)"
            return
        }
        closing.close()
        finalizedCount += 1
        lastEvent = "Saved conversation"
        let segment = FinalizedSegment(
            cafURL: closing.cafURL,
            m4aURL: closing.m4aURL,
            startDate: startDate,
            duration: secondsOf(closing.writtenSampleCount),
            speechDuration: speechDuration)
        segmentHandler?(segment)
    }

    private func secondsOf(_ samples: Int) -> TimeInterval {
        Double(samples) / Double(VADConstants.sampleRate)
    }

    private func snapshot() -> RecorderSnapshot {
        RecorderSnapshot(
            state: state, finalizedCount: finalizedCount, lastEvent: lastEvent,
            diskGuardActive: diskGuardActive, currentSegmentStartDate: segmentStartDate)
    }
}
