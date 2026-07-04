import Foundation

/// Renders the SPEC markdown transcript (YAML frontmatter + body) and writes it atomically
/// next to the m4a (same basename, `.md`). Plain body for on-device backends (no speaker
/// labels available); speaker-turn body for `deepgram`, which diarizes.
enum TranscriptMarkdownWriter {
    static func write(result: TranscriptionResult, job: TranscriptionJob) throws -> URL {
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

        var lines: [String] = ["---"]
        lines.append("date: \(iso.string(from: job.startDate))")
        lines.append("duration: \(Int(job.duration.rounded()))")
        lines.append("speechEnd: \(iso.string(from: job.startDate.addingTimeInterval(job.speechDuration)))")
        lines.append("backend: \(result.backend.rawValue)")
        let speakers = Set(result.segments.compactMap(\.speaker))
        if result.backend == .deepgram {
            lines.append("speakers: \(max(speakers.count, 1))")
        }
        lines.append("---")
        lines.append("")
        lines.append("# Conversation — \(timeFormatter.string(from: job.startDate))")
        lines.append("")
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
}
