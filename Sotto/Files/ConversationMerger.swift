import Foundation

/// Merge-conversations (spec 2026-07-06): file-level merge of 2+ same-day conversations
/// into the earliest part's basename. Owns spec steps 1–4 (stitch → write merged .md →
/// move audio → delete parts); step 5 (`_day.json`) stays with `DayIndexStore.applyMerge`,
/// the actor that owns index writes. The merged file uses EXACTLY a recorded file's
/// frontmatter keys, so rebuild/list/preview/sync treat it as any other conversation.
enum ConversationMerger {
    enum MergeError: Error, Equatable {
        case needAtLeastTwoParts
        case missingTranscript(String)      // part id whose .md is unreadable
        case audioStitchFailed(String)
    }

    struct Outcome: Equatable {
        let mergedEntry: DaySegmentEntry
        let removedIDs: [String]            // part ids whose files were deleted
        let mergedM4AURL: URL               // exists only when mergedEntry.hasAudio
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func merge(dayDirectory: URL, entries: [DaySegmentEntry]) async throws -> Outcome {
        guard entries.count >= 2 else { throw MergeError.needAtLeastTwoParts }
        let parts = entries.sorted { ($0.startTime, $0.id) < ($1.startTime, $1.id) }

        // Parse every part BEFORE touching anything — an abort must leave disk untouched.
        var files: [TranscriptFile] = []
        for part in parts {
            guard let file = TranscriptFile.parse(
                url: dayDirectory.appendingPathComponent("\(part.id).md"))
            else { throw MergeError.missingTranscript(part.id) }
            files.append(file)
        }

        // Spec step 1 — stitch to a temp file, only when EVERY part still has its .m4a
        // (any part missing ⇒ transcript-only merge). Stitch failure aborts pre-write.
        // Temp extension is `.tmp`, NOT `.m4a`: if a crash leaves this file behind,
        // DayIndexRebuilder.rebuild's `.m4a` scan (and SegmentStore.orphanedCAFs's
        // `.caf` scan) must never see it and synthesize a bogus queued index entry.
        let m4aURLs = parts.map { dayDirectory.appendingPathComponent("\($0.id).m4a") }
        let allHaveAudio = m4aURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        var stitchedTempURL: URL?
        if allHaveAudio {
            let temp = dayDirectory.appendingPathComponent(".merge-\(parts[0].id).tmp")
            try? FileManager.default.removeItem(at: temp)
            do {
                try await AudioStitcher.stitch(parts: m4aURLs, to: temp)
                stitchedTempURL = temp
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw MergeError.audioStitchFailed(String(describing: error))
            }
        }

        let fronts = files.map(\.frontmatter)
        let durationSum = fronts.compactMap { $0["duration"].flatMap(Int.init) }.reduce(0, +)
        let backends = Set(fronts.compactMap { $0["backend"] })
        let backend = backends.count == 1 ? backends.first : (backends.isEmpty ? nil : "mixed")
        let speakers = fronts.compactMap { $0["speakers"].flatMap(Int.init) }.max()

        // Spec step 2 — merged .md atomically over the earliest part's.
        let mergedMDURL = dayDirectory.appendingPathComponent("\(parts[0].id).md")
        let markdown = renderMerged(
            parts: parts, files: files,
            durationSum: durationSum, backend: backend, speakers: speakers)
        try markdown.write(to: mergedMDURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mergedMDURL.path)

        // Spec step 3 — stitched audio over the earliest part's .m4a; transcript-only
        // merges drop a straggling part-1 .m4a (merged conversation has no audio).
        let mergedM4AURL = m4aURLs[0]
        var mergedHasAudio = false
        if let stitchedTempURL {
            do {
                _ = try FileManager.default.replaceItemAt(mergedM4AURL, withItemAt: stitchedTempURL)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: mergedM4AURL.path)
                mergedHasAudio = true
            } catch {
                // Move failed (e.g. disk full): fall back to a transcript-only merge —
                // hasAudio must stay truthful, and audio that matches only part of the
                // transcript must not survive (same rule as the any-part-missing path).
                try? FileManager.default.removeItem(at: stitchedTempURL)
                try? FileManager.default.removeItem(at: mergedM4AURL)
            }
        } else {
            try? FileManager.default.removeItem(at: mergedM4AURL)
        }

        // Spec step 4 — delete the other parts' files (new truth exists; old goes last).
        for (part, m4a) in zip(parts, m4aURLs).dropFirst() {
            try? FileManager.default.removeItem(
                at: dayDirectory.appendingPathComponent("\(part.id).md"))
            try? FileManager.default.removeItem(at: m4a)
        }

        // Parse the just-written file so wordCount comes from the SAME function on the
        // SAME text the rebuilder would use — rebuild parity by construction.
        let mergedFile = TranscriptFile.parse(url: mergedMDURL)
        let mergedEntry = DaySegmentEntry(
            id: parts[0].id,
            startTime: parts[0].startTime,
            duration: Double(durationSum),
            backend: backend,
            hasAudio: mergedHasAudio,
            wordCount: mergedFile.map { DayIndexRebuilder.wordCount(of: $0.transcriptBody) },
            transcriptionState: "done",
            title: nil)
        return Outcome(
            mergedEntry: mergedEntry,
            removedIDs: parts.dropFirst().map(\.id),
            mergedM4AURL: mergedM4AURL)
    }

    // MARK: - Notes regeneration rewrite

    /// Rewrites a merged file with regenerated notes — `title:` frontmatter, titled H1,
    /// `## Summary` / `## Transcript` sections (the exact M8 shape). Frontmatter keys are
    /// preserved (canonical order; `title` replaced); the transcript body — gap markers
    /// included — is preserved verbatim. Model output passes through the SAME sanitizers
    /// as the transcription writer (M8 hardening Fix 2's single choke point). Returns
    /// false when the file can't be parsed or written; never throws — notes are
    /// best-effort everywhere in this app.
    @discardableResult
    static func applyNotes(to mdURL: URL, notes: PostProcessingResult, startTime: Date) -> Bool {
        guard let file = TranscriptFile.parse(url: mdURL) else { return false }
        let sanitizedTitle = notes.title.map(TranscriptMarkdownWriter.sanitizeInline)
            .flatMap { $0.isEmpty ? nil : $0 }
        let sanitizedSummary = notes.summary.map(TranscriptMarkdownWriter.sanitizeBlock)
        let sanitizedActionItems = notes.actionItems?.map(TranscriptMarkdownWriter.sanitizeBlock)

        var front = file.frontmatter
        front["title"] = sanitizedTitle
        var lines = frontmatterLines(front)
        lines.append("")
        let headingTime = timeFormatter.string(from: startTime)
        lines.append("# \(sanitizedTitle ?? "Conversation") — \(headingTime)")
        lines.append("")
        let hasNotesBody = sanitizedSummary != nil || sanitizedActionItems?.isEmpty == false
        if hasNotesBody {
            lines.append("## Summary")
            lines.append("")
            if let sanitizedSummary {
                lines.append(sanitizedSummary)
                lines.append("")
            }
            if let sanitizedActionItems, !sanitizedActionItems.isEmpty {
                lines.append("Action items:")
                for item in sanitizedActionItems {
                    lines.append("- \(item)")
                }
                lines.append("")
            }
            lines.append("## Transcript")
            lines.append("")
        }
        // partBody, not file.transcriptBody: a pre-notes-shape merged file still carries
        // its H1 inside transcriptBody, and the H1 is re-emitted above with the title.
        lines.append(partBody(file))
        lines.append("")
        do {
            try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mdURL.path)
        return true
    }

    /// Canonical frontmatter rendering shared by `applyNotes`/`applyTitle` — the writer's
    /// key order (TranscriptMarkdownWriter puts `source` before `speakers`), with unknown
    /// keys (hand-edited files — the folder is user-exposed) surviving at the end, sorted.
    private static func frontmatterLines(_ front: [String: String]) -> [String] {
        var lines = ["---"]
        let canonical = ["date", "duration", "speechEnd", "backend", "source", "speakers", "title"]
        for key in canonical {
            if let value = front[key] { lines.append("\(key): \(value)") }
        }
        for key in front.keys.filter({ !canonical.contains($0) }).sorted() {
            lines.append("\(key): \(front[key]!)")
        }
        lines.append("---")
        return lines
    }

    // MARK: - Rename (2026-07-07 spec)

    /// User retitle from the Detail view. Sets `title:` frontmatter and re-renders the H1
    /// with the ORIGINAL start time; everything else in the body — Summary, action items,
    /// Transcript, gap markers — survives verbatim (unlike `applyNotes`, which re-renders
    /// the section structure). Same sanitizer choke point as model output. Returns false
    /// when the title sanitizes to empty or the file can't be parsed/written.
    @discardableResult
    static func applyTitle(to mdURL: URL, title: String, startTime: Date) -> Bool {
        guard let file = TranscriptFile.parse(url: mdURL) else { return false }
        let sanitized = TranscriptMarkdownWriter.sanitizeInline(title)
        guard !sanitized.isEmpty else { return false }

        var front = file.frontmatter
        front["title"] = sanitized
        var lines = frontmatterLines(front)
        lines.append("")
        let heading = "# \(sanitized) — \(timeFormatter.string(from: startTime))"
        // "# " matches the H1 only, never "## " section headings.
        var bodyLines = file.body.components(separatedBy: "\n")
        if let h1 = bodyLines.firstIndex(where: { $0.hasPrefix("# ") }) {
            bodyLines[h1] = heading
        } else {
            bodyLines.insert(contentsOf: [heading, ""], at: 0)
        }
        // If the body has no "## Transcript" section, add one to structure the content
        // and ensure transcriptBody returns only text after it (consistent with post-applyNotes files).
        let hasTranscriptSection = bodyLines.contains { $0.hasPrefix("## Transcript") }
        if !hasTranscriptSection {
            // Insert "## Transcript" after the H1 (and any blank lines following it).
            var insertIndex = 1
            while insertIndex < bodyLines.count, bodyLines[insertIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                insertIndex += 1
            }
            bodyLines.insert(contentsOf: ["## Transcript", ""], at: insertIndex)
        }
        lines.append(contentsOf: bodyLines)
        lines.append("")
        do {
            try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mdURL.path)
        return true
    }

    // MARK: - Rendering

    private static func renderMerged(
        parts: [DaySegmentEntry], files: [TranscriptFile],
        durationSum: Int, backend: String?, speakers: Int?
    ) -> String {
        var lines = ["---"]
        if let date = files[0].frontmatter["date"] { lines.append("date: \(date)") }
        lines.append("duration: \(durationSum)")
        if let speechEnd = files[files.count - 1].frontmatter["speechEnd"] {
            lines.append("speechEnd: \(speechEnd)")
        }
        if let backend { lines.append("backend: \(backend)") }
        if let speakers { lines.append("speakers: \(speakers)") }
        lines.append("---")
        lines.append("")
        lines.append("# Conversation — \(timeFormatter.string(from: parts[0].startTime))")
        lines.append("")
        for index in parts.indices {
            if index > 0 {
                lines.append(gapMarker(
                    previousEntry: parts[index - 1], previousFile: files[index - 1],
                    nextEntry: parts[index], nextFile: files[index]))
                lines.append("")
            }
            lines.append(partBody(files[index]))
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A part's transcript with its own H1 heading dropped (`transcriptBody` already
    /// excludes any per-part Summary section; pre-notes files carry the H1 inside it).
    private static func partBody(_ file: TranscriptFile) -> String {
        file.transcriptBody
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("# ") }        // "# " matches H1 only, never "## "
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gapMarker(
        previousEntry: DaySegmentEntry, previousFile: TranscriptFile,
        nextEntry: DaySegmentEntry, nextFile: TranscriptFile
    ) -> String {
        let iso = ISO8601DateFormatter()
        let previousEnd = previousFile.frontmatter["speechEnd"].flatMap { iso.date(from: $0) }
            ?? previousEntry.startTime.addingTimeInterval(previousEntry.duration)
        let gap = max(0, nextEntry.startTime.timeIntervalSince(previousEnd))
        var marker = "> \(gapText(gap)) gap — resumed "
            + timeFormatter.string(from: nextEntry.startTime)
        // Reset note only when BOTH sides carry Deepgram speaker labels — between an
        // unlabeled part and a labeled one there is no numbering to "restart".
        if hasSpeakerLabels(previousFile), hasSpeakerLabels(nextFile) {
            marker += " · speaker numbers restart"
        }
        return marker
    }

    private static func gapText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private static func hasSpeakerLabels(_ file: TranscriptFile) -> Bool {
        file.transcriptBody.range(
            of: #"\*\*Speaker \d+:\*\*"#, options: .regularExpression) != nil
    }
}
