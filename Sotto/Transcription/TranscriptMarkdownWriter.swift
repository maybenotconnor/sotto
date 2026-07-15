import Foundation

/// Renders the SPEC markdown transcript (YAML frontmatter + body) and writes it atomically
/// next to the m4a (same basename, `.md`). Plain body for on-device backends (no speaker
/// labels available); speaker-turn body for `deepgram`, which diarizes.
enum TranscriptMarkdownWriter {
    static func write(
        result: TranscriptionResult, notes: PostProcessingResult? = nil, job: TranscriptionJob
    ) throws -> URL {
        let url = job.m4aURL.deletingPathExtension().appendingPathExtension("md")

        // ISO8601DateFormatter with an explicit non-UTC `timeZone` DOES render that zone's
        // offset (verified: e.g. "2026-03-08T16:00:00-04:00", colon-separated) rather than
        // "Z" — the SPEC requires the local UTC offset on frontmatter timestamps, and this
        // satisfies it directly, so no `Date.ISO8601FormatStyle` detour was needed.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]   // local offset included below
        iso.timeZone = .current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"

        // M8 hardening Fix 2: model output is untrusted text; never let it alter frontmatter
        // or section structure. Sanitized once, here at the writer boundary — the single
        // choke point every notes value passes through before landing in the file.
        let sanitizedTitle = notes?.title.map(Self.sanitizeInline).flatMap { $0.isEmpty ? nil : $0 }
        let sanitizedSummary = notes?.summary.map(Self.sanitizeBlock)
        let sanitizedActionItems = notes?.actionItems?.map(Self.sanitizeBlock)

        var lines: [String] = ["---"]
        lines.append("date: \(iso.string(from: job.startDate))")
        lines.append("duration: \(Int(job.duration.rounded()))")
        lines.append("speechEnd: \(iso.string(from: job.startDate.addingTimeInterval(job.speechDuration)))")
        lines.append("backend: \(result.backend.rawValue)")
        // M12 BINDING byte-compat: phone-mic segments (the pre-M12 default) must render
        // IDENTICAL frontmatter — only .omi gets an explicit `source:` line.
        if job.source != .phoneMic {
            lines.append("source: \(job.source.rawValue)")
        }
        let speakers = Set(result.segments.compactMap(\.speaker))
        if result.backend == .deepgram {
            lines.append("speakers: \(max(speakers.count, 1))")
        }
        if let sanitizedTitle {
            lines.append("title: \(sanitizedTitle)")
        }
        lines.append("---")
        lines.append("")
        if let sanitizedTitle {
            lines.append("# \(sanitizedTitle) — \(timeFormatter.string(from: job.startDate))")
        } else {
            lines.append("# Conversation — \(timeFormatter.string(from: job.startDate))")
        }
        lines.append("")

        // Byte-compatibility (BINDING invariant): with no notes body the helper returns [],
        // so the transcript body below renders in EXACTLY today's shape (no "## Transcript"
        // heading) and every pre-M8 markdown/rebuild test keeps passing unmodified.
        lines.append(contentsOf: Self.summarySection(
            summary: sanitizedSummary, actionItems: sanitizedActionItems,
            truncated: notes?.truncated ?? false))

        if result.backend == .deepgram, !result.segments.isEmpty {
            for segment in result.segments {
                let speaker = segment.speaker.map { "**Speaker \($0):** " } ?? ""
                lines.append(speaker + segment.text)
                lines.append("")
            }
        } else {
            lines.append(result.text)
            lines.append("")
        }
        try lines.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        // Explicit per SPEC — must never become `.complete`, which would make the
        // transcript unreadable while the device is locked.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)

        return url
    }

    /// Trusted app text (NOT model output — bypasses the sanitizers) shown when the notes were
    /// built from head+tail excerpts of a long transcript. `excerptDisclaimerText` is the plain
    /// wording the in-app UI renders as a small, de-emphasized note (a verbatim summary `Text`
    /// can't interpret markdown); `excerptDisclaimer` wraps it in markdown emphasis for the
    /// on-disk Summary section, so Obsidian/Files viewers still render it italic. One source of
    /// truth for the sentence.
    static let excerptDisclaimerText =
        "Summary based on excerpts of the transcript. Important information may have been omitted."
    static let excerptDisclaimer = "_\(excerptDisclaimerText)_"

    /// The `## Summary` … `## Transcript` block, shared by the transcription writer and
    /// `ConversationMerger.applyNotes`. Inputs are already sanitized. Returns `[]` when there
    /// is no notes body, so the caller's transcript body renders in the exact pre-notes shape
    /// (byte-compat invariant). The disclaimer is appended before `## Transcript` when truncated.
    static func summarySection(summary: String?, actionItems: [String]?, truncated: Bool) -> [String] {
        let hasNotesBody = summary != nil || actionItems?.isEmpty == false
        guard hasNotesBody else { return [] }
        var lines: [String] = ["## Summary", ""]
        if let summary {
            lines.append(summary)
            lines.append("")
        }
        if let actionItems, !actionItems.isEmpty {
            lines.append("Action items:")
            for item in actionItems {
                lines.append("- \(item)")
            }
            lines.append("")
        }
        if truncated {
            lines.append(excerptDisclaimer)
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        return lines
    }

    // model output is untrusted text; never let it alter frontmatter or section structure
    static func sanitizeInline(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        let stripped = collapsed.drop { $0 == "#" || $0 == "-" }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }

    // model output is untrusted text; never let it alter frontmatter or section structure
    static func sanitizeBlock(_ text: String) -> String {
        text.replacingOccurrences(of: "\n## ", with: "\n")
    }
}
