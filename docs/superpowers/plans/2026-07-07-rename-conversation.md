# Rename Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user rename a conversation by tapping its title in the detail view (native iOS nav-title rename), persisting to `.md` frontmatter + H1, the day index, and the sync mirror.

**Architecture:** A renamed conversation is byte-shape-identical to one titled by the M8 post-processor — `title:` frontmatter, `# <title> — <time>` H1, `DaySegmentEntry.title`. New `ConversationMerger.applyTitle` rewrites the file (title only, body preserved verbatim); `DayIndexStore.setTitle` mutates the index entry; `AppModel.renameSegment` orchestrates file → index → mirror → history refresh, following the `regenerateNotes` precedent. `ConversationDetailView` binds the nav title via `navigationTitle(Binding<String>)`.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`@Test`/`#expect`), xcodegen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-07-07-rename-conversation-design.md`

## Global Constraints

- Test command (every task): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. Runs take minutes; not a hang. Simulator Busy → `xcrun simctl shutdown all`, retry. Scope with `-only-testing:SottoTests/<Suite>` while iterating.
- No xcodegen regeneration needed — no files are created, only existing ones modified (all four touched source files are already in the project).
- User input passes through `TranscriptMarkdownWriter.sanitizeInline` — the same choke point as model output. Never render an unsanitized title into frontmatter.
- File writes: atomic, then `FileProtectionType.completeUntilFirstUserAuthentication`, as everywhere in `Sotto/Files/`.
- Working directory: `/Users/connor/OpenCloud/Personal/GithubProjects/sotto`.

---

### Task 1: `ConversationMerger.applyTitle` + shared frontmatter renderer

**Files:**
- Modify: `Sotto/Files/ConversationMerger.swift` (applyNotes region, ~lines 124–188)
- Test: `SottoTests/ConversationMergerTests.swift` (append inside the struct)

**Interfaces:**
- Consumes: `TranscriptFile.parse(url:)`, `TranscriptMarkdownWriter.sanitizeInline(_:)`, existing private `static let timeFormatter` in `ConversationMerger`.
- Produces: `@discardableResult static func applyTitle(to mdURL: URL, title: String, startTime: Date) -> Bool` — Task 3 calls this.

- [ ] **Step 1: Write the failing tests**

Append inside `struct ConversationMergerTests` (before the closing brace):

```swift
    // A merged-and-noted file: title frontmatter, titled H1, Summary + Transcript sections,
    // plus a hand-edited unknown key — the hardest shape applyTitle must preserve.
    static let notedFile = """
    ---
    date: 2026-03-14T09:15:30-04:00
    duration: 270
    speechEnd: 2026-03-14T09:20:00-04:00
    backend: speechAnalyzer
    title: Planning the launch
    obsidian-tag: keepme
    ---

    # Planning the launch — 9:15 AM

    ## Summary

    We planned the launch.

    ## Transcript

    First part text one two three.
    """

    @Test func applyTitleReplacesTitleAndHeadingPreservingEverythingElse() async throws {
        let dir = try makeDay([("09-15-30", Self.notedFile)])
        let mdURL = dir.appendingPathComponent("09-15-30.md")
        let startTime = DayIndexRebuilder.rebuild(dayDirectory: dir).segments[0].startTime

        let ok = ConversationMerger.applyTitle(
            to: mdURL, title: "Launch retro", startTime: startTime)

        #expect(ok)
        let file = try #require(TranscriptFile.parse(url: mdURL))
        #expect(file.title == "Launch retro")
        // Untouched frontmatter — canonical and hand-edited unknown keys alike — survives.
        #expect(file.frontmatter["date"] == "2026-03-14T09:15:30-04:00")
        #expect(file.frontmatter["duration"] == "270")
        #expect(file.frontmatter["speechEnd"] == "2026-03-14T09:20:00-04:00")
        #expect(file.frontmatter["backend"] == "speechAnalyzer")
        #expect(file.frontmatter["obsidian-tag"] == "keepme")
        #expect(file.frontmatter.count == 6)
        // H1 re-rendered with the ORIGINAL start time; sections preserved verbatim.
        let started = timeFormatter.string(from: startTime)
        let headings = file.body.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        #expect(headings == ["# Launch retro — \(started)"])
        #expect(file.summary == "We planned the launch.")
        #expect(file.transcriptBody == "First part text one two three.")
    }

    @Test func applyTitleTitlesAPreviouslyUntitledFile() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne)])   // no title, plain body
        let mdURL = dir.appendingPathComponent("09-15-30.md")
        let startTime = DayIndexRebuilder.rebuild(dayDirectory: dir).segments[0].startTime

        let ok = ConversationMerger.applyTitle(
            to: mdURL, title: "Morning standup", startTime: startTime)

        #expect(ok)
        let file = try #require(TranscriptFile.parse(url: mdURL))
        #expect(file.title == "Morning standup")
        let started = timeFormatter.string(from: startTime)
        #expect(file.body.components(separatedBy: "\n")
            .contains("# Morning standup — \(started)"))
        #expect(file.transcriptBody == "First part text one two three.")
    }

    @Test func applyTitleSanitizesUserInputAndRejectsEmpty() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne)])
        let mdURL = dir.appendingPathComponent("09-15-30.md")
        let startTime = DayIndexRebuilder.rebuild(dayDirectory: dir).segments[0].startTime

        // Newline collapsed — user input cannot mint frontmatter keys (same choke point
        // as model output).
        #expect(ConversationMerger.applyTitle(
            to: mdURL, title: "Evil\ntitle: injected", startTime: startTime))
        let file = try #require(TranscriptFile.parse(url: mdURL))
        #expect(file.title == "Evil title: injected")

        // Sanitizes-to-empty aborts: file untouched.
        let before = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(!ConversationMerger.applyTitle(to: mdURL, title: "###", startTime: startTime))
        #expect(try String(contentsOf: mdURL, encoding: .utf8) == before)

        // Missing file aborts.
        #expect(!ConversationMerger.applyTitle(
            to: dir.appendingPathComponent("nope.md"), title: "X", startTime: startTime))
    }

    @Test func applyTitleSurvivesIndexRebuild() async throws {
        let dir = try makeDay([("09-15-30", Self.notedFile)])
        let mdURL = dir.appendingPathComponent("09-15-30.md")
        let rebuilt = DayIndexRebuilder.rebuild(dayDirectory: dir)

        _ = ConversationMerger.applyTitle(
            to: mdURL, title: "Launch retro", startTime: rebuilt.segments[0].startTime)

        // The rename lives in frontmatter, so a lost _day.json reproduces it — and the
        // rebuilt word count is unchanged (title is not transcript text).
        let after = DayIndexRebuilder.rebuild(dayDirectory: dir).segments[0]
        #expect(after.title == "Launch retro")
        #expect(after.wordCount == rebuilt.segments[0].wordCount)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `type 'ConversationMerger' has no member 'applyTitle'`.

- [ ] **Step 3: Implement `applyTitle` and factor `frontmatterLines`**

In `Sotto/Files/ConversationMerger.swift`, inside `applyNotes` (currently ~lines 141–151), replace the inline frontmatter rendering:

```swift
        var front = file.frontmatter
        front["title"] = sanitizedTitle
        var lines = ["---"]
        let canonical = ["date", "duration", "speechEnd", "backend", "speakers", "title"]
        for key in canonical {
            if let value = front[key] { lines.append("\(key): \(value)") }
        }
        // Unknown keys (hand-edited files — the folder is user-exposed) survive, sorted.
        for key in front.keys.filter({ !canonical.contains($0) }).sorted() {
            lines.append("\(key): \(front[key]!)")
        }
        lines.append("---")
```

with:

```swift
        var front = file.frontmatter
        front["title"] = sanitizedTitle
        var lines = frontmatterLines(front)
```

Then, after the closing brace of `applyNotes` (before `// MARK: - Rendering`), add:

```swift
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
```

Note: `timeFormatter` is the existing private static in `ConversationMerger` (used by `applyNotes` and `gapMarker`). Adding `source` to the canonical list is deliberate — `applyNotes` previously let a `source:` key fall into the unknown-sorted section; canonical order now matches `TranscriptMarkdownWriter` output. Parsing is order-insensitive, so no behavior change.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (all pre-existing merger tests still pass — the `frontmatterLines` refactor is covered by `applyNotesRewritesWithTitleSummaryAndPreservedTranscript`).

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/ConversationMerger.swift SottoTests/ConversationMergerTests.swift
git commit -m "feat: ConversationMerger.applyTitle — title-only .md rewrite for rename"
```

---

### Task 2: `DayIndexStore.setTitle`

**Files:**
- Modify: `Sotto/Files/DayIndexStore.swift` (after `setAudioRemoved`, ~line 70)
- Test: `SottoTests/DayIndexTests.swift` (append after `updateAndAudioRemovalMutateTheRightEntry`)

**Interfaces:**
- Consumes: existing private `mutateEntry(for:_:)` in `DayIndexStore`.
- Produces: `func setTitle(m4aURL: URL, title: String)` on actor `DayIndexStore` — Task 3 calls this.

- [ ] **Step 1: Write the failing test**

Append inside `struct DayIndexTests`, after `updateAndAudioRemovalMutateTheRightEntry` (line 68). It uses the suite's existing `tempRoot()` and `m4a(_:day:name:)` fixture helpers (lines 6–15):

```swift
    @Test func setTitleMutatesOnlyTheTitle() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)
        await store.updateSegment(
            m4aURL: url, transcriptionState: "done", backend: "speechAnalyzer", wordCount: 847,
            title: "Rollout sync")

        await store.setTitle(m4aURL: url, title: "Rollout retro")

        let entry = await store.index(forDay: url.deletingLastPathComponent())?.segments.first
        #expect(entry?.title == "Rollout retro")
        // Everything else untouched.
        #expect(entry?.transcriptionState == "done")
        #expect(entry?.backend == "speechAnalyzer")
        #expect(entry?.wordCount == 847)
        #expect(entry?.hasAudio == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/DayIndexTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `value of type 'DayIndexStore' has no member 'setTitle'`.

- [ ] **Step 3: Implement `setTitle`**

In `Sotto/Files/DayIndexStore.swift`, after `setAudioRemoved` (line ~70), add:

```swift
    /// Rename-conversation spec (2026-07-07): Detail-view retitle — title only; the
    /// caller has already rewritten the .md (the source of truth) via `applyTitle`.
    func setTitle(m4aURL: URL, title: String) {
        mutateEntry(for: m4aURL) { $0.title = title }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/DayIndexTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/DayIndexStore.swift SottoTests/DayIndexTests.swift
git commit -m "feat: DayIndexStore.setTitle for conversation rename"
```

---

### Task 3: `AppModel.renameSegment`

**Files:**
- Modify: `Sotto/App/AppModel.swift` (after `deleteSegment`, ~line 383)
- Test: `SottoTests/AppModelTests.swift` (append after `mergeSegmentsCombinesFilesIndexAndHistory`)

**Interfaces:**
- Consumes: `ConversationMerger.applyTitle(to:title:startTime:) -> Bool` (Task 1), `DayIndexStore.setTitle(m4aURL:title:)` (Task 2), existing `SyncDestinationStore().resolve()`, `SegmentExporter.export(m4aURL:to:)`, `refreshLoadedHistory()`.
- Produces: `func renameSegment(m4aURL: URL, title: String, startTime: Date) async` on `AppModel` — Task 4 calls this.

- [ ] **Step 1: Write the failing test**

Append to `SottoTests/AppModelTests.swift` (mirrors `mergeSegmentsCombinesFilesIndexAndHistory`'s fixture at line 207 — same temp-root + yesterday-folder pattern):

```swift
    @Test func renameSegmentRewritesFileIndexAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameModelTests-\(UUID().uuidString)")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()   // no _day.json → rebuilds; entry is "done"
        let entry = model.historySections[0].index.segments[0]
        #expect(entry.title == nil)

        await model.renameSegment(
            m4aURL: dir.appendingPathComponent("09-15-30.m4a"),
            title: "Morning standup", startTime: entry.startTime)

        // File is the source of truth…
        let file = try #require(TranscriptFile.parse(
            url: dir.appendingPathComponent("09-15-30.md")))
        #expect(file.title == "Morning standup")
        #expect(file.transcriptBody == "First part text one two three.")
        // …index followed…
        let indexed = await model.loadDayIndex(for: day)?.segments.first
        #expect(indexed?.title == "Morning standup")
        // …and the loaded history refreshed in place.
        #expect(model.historySections[0].index.segments[0].title == "Morning standup")
    }

    @Test func renameSegmentWithMissingFileChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameMissingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()

        // No .md on disk → applyTitle fails → the index must never run ahead of the file.
        await model.renameSegment(
            m4aURL: root.appendingPathComponent("2026-03-14/09-15-30.m4a"),
            title: "Ghost", startTime: Date())

        #expect(model.historySections.isEmpty)
    }
```

Note: `loadDayIndex(for:)` is an existing internal method on `AppModel` (line 339) — visible to the test via `@testable import`.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AppModelTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `value of type 'AppModel' has no member 'renameSegment'`.

- [ ] **Step 3: Implement `renameSegment`**

In `Sotto/App/AppModel.swift`, after `deleteSegment`'s closing brace (~line 383), add:

```swift
    /// Rename-conversation spec (2026-07-07): Detail-view retitle. The .md is the source
    /// of truth — rewrite it first; if that fails (file gone, title sanitizes to empty)
    /// the index is never touched. Then the same choreography as `regenerateNotes`:
    /// index title, best-effort detached mirror export, history refresh. PreviewCache is
    /// NOT invalidated — previews derive from summary/transcript text, which a rename
    /// never changes.
    func renameSegment(m4aURL: URL, title: String, startTime: Date) async {
        let mdURL = m4aURL.deletingPathExtension().appendingPathExtension("md")
        guard ConversationMerger.applyTitle(to: mdURL, title: title, startTime: startTime)
        else { return }
        await dayIndex?.setTitle(m4aURL: m4aURL, title: title)
        if let destination = SyncDestinationStore().resolve() {
            Task.detached(priority: .utility) {
                SegmentExporter.export(m4aURL: m4aURL, to: destination)
            }
        }
        await refreshLoadedHistory()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AppModelTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/AppModel.swift SottoTests/AppModelTests.swift
git commit -m "feat: AppModel.renameSegment — file, index, mirror, history choreography"
```

---

### Task 4: Editable nav title in `ConversationDetailView`

**Files:**
- Modify: `Sotto/App/ConversationDetailView.swift`

**Interfaces:**
- Consumes: `model.renameSegment(m4aURL:title:startTime:)` (Task 3), `TranscriptMarkdownWriter.sanitizeInline(_:)`.
- Produces: UI only — nothing downstream consumes this.

No unit test — the repo has no SwiftUI view tests; this task is verified by a clean build, the full existing suite, and a manual pass (Step 4).

- [ ] **Step 1: Restructure the view for a conditional editable title**

In `Sotto/App/ConversationDetailView.swift`:

**(a)** Add two state vars after `@State private var confirmDelete = false` (line 13):

```swift
    // Rename (2026-07-07 spec): nav-title binding + last-persisted value. `savedTitle`
    // is what commit no-ops and reverts compare against — it starts as the same
    // title-or-time fallback the static navigationTitle used to show.
    @State private var editableTitle = ""
    @State private var savedTitle = ""
```

**(b)** Replace the whole `body` (lines 19–45) with the version below. The scroll content is unchanged — it moves into `mainContent`, and `body` picks the title treatment: editable binding when a transcript exists (rename has somewhere durable to live), the original static title otherwise. `.task`/`.onDisappear`/`.confirmationDialog` hang off the *outer* `Group` so the branch switch when `transcript` loads doesn't re-run them:

```swift
    var body: some View {
        Group {
            if transcript != nil {
                mainContent
                    .navigationTitle($editableTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .onChange(of: editableTitle) { _, newValue in
                        commitRename(newValue)
                    }
            } else {
                mainContent
                    .navigationTitle(
                        entry.title ?? entry.startTime.formatted(.dateTime.hour().minute()))
            }
        }
        .task {
            transcript = TranscriptFile.parse(url: mdURL)
            savedTitle = entry.title ?? entry.startTime.formatted(.dateTime.hour().minute())
            editableTitle = savedTitle
            // hasAudio is advisory (M5 review): stat the file before offering playback.
            audioExists = FileManager.default.fileExists(atPath: m4aURL.path)
            if audioExists { player.load(url: m4aURL) }
        }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteSegment(m4aURL: m4aURL)
                    dismiss()
                }
            }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataRow
                if audioExists { playerControls }
                transcriptBody
            }
            .padding()
        }
        .toolbar { toolbarContent }
    }

    /// Commit rule (spec): persist only a non-empty value that differs from what was
    /// displayed. Unchanged commits (including the seeding write in `.task`) and inputs
    /// that trim/sanitize to empty revert silently — this also keeps the time placeholder
    /// from being persisted as a literal title.
    private func commitRename(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedTitle else { return }
        let sanitized = TranscriptMarkdownWriter.sanitizeInline(trimmed)
        guard !sanitized.isEmpty else {
            editableTitle = savedTitle
            return
        }
        savedTitle = sanitized
        editableTitle = sanitized   // reflect sanitization; re-entry no-ops via the guard
        Task {
            await model.renameSegment(
                m4aURL: m4aURL, title: sanitized, startTime: entry.startTime)
        }
    }
```

Everything else in the file (`metadataRow`, `playerControls`, `transcriptBody`, `toolbarContent`) stays as is.

- [ ] **Step 2: Build and run the full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sotto/App/ConversationDetailView.swift
git commit -m "feat: tap-to-rename conversation title in detail view"
```

- [ ] **Step 4: Manual verification (simulator)**

Build and run in the simulator, open a transcribed conversation, and verify:
1. Nav title shows the ▾ chevron; tap → Rename → inline edit; commit → title updates.
2. Back out to the Home list → the row shows the new title.
3. Re-open the conversation → new title persists; the `.md` on disk (Files app or `xcrun simctl get_app_container` path) has `title:` frontmatter + retitled H1 with the original time.
4. Clearing the field or committing unchanged text reverts with no write.
5. A still-transcribing (queued) conversation shows a plain, non-editable title.
