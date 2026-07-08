# Backup & Restore — iCloud Phase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dead-end folder-picker sync with a default-on iCloud transcript backup + additive restore, built on an extensible `TranscriptSyncSink` seam that WebDAV (next phase) slots into.

**Architecture:** Extract the existing `SegmentExporter`'s coordinated file I/O into a reusable `CoordinatedMirror`. Define a `TranscriptSyncSink` protocol (`upsert`/`remove`) with a `SyncSinkRegistry` that fans each of AppModel's five mutation events out to every active sink, detached and failure-isolated. Ship one sink — `ICloudSyncSink` (transcripts-only, into an app-owned ubiquity container) — plus `ICloudRestore` for launch/manual inbound hydration. Local `Documents/Sotto` stays canonical; iCloud is a backup vault, never source of truth.

**Tech Stack:** Swift 6, SwiftUI, `NSFileCoordinator` + `FileManager` ubiquity-container APIs, Swift Testing (`import Testing`), xcodegen.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from the design (`docs/superpowers/specs/2026-07-07-backup-restore-icloud-design.md`) and `project.yml`.

- **Swift 6.0**, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`. iOS deployment target **26.0**. **Zero new warnings.**
- **Container identifier:** `iCloud.com.decanlys.Sotto`. **Layout:** `<container>/Transcripts/<day>/<basename>.md` — where `<day>` is `yyyy-MM-dd` and `<basename>` is `HH-mm-ss`. **`.md` transcripts ONLY — never audio, never `_day.json`, never `.caf`.**
- **Best-effort contract:** every sink op is `async` and MUST NEVER throw into the caller, fail a transcription job, block the queue, delay a transition handler, or ride the main actor. All fan-out is `Task.detached(priority: .utility)`.
- **Deletes are event-driven only** — emitted by explicit user actions (delete/merge), NEVER by diffing local against the container. An empty local store produces zero delete events.
- **Restore is additive + idempotent** — copy container `.md` only where the local counterpart is missing; never overwrite an existing local file (local is canonical).
- **Container is NOT document-scope-public** — do NOT add `NSUbiquitousContainers` to Info.plist; the backup stays invisible in Files.app.
- **Bundle id / logger subsystem:** `com.decanlys.Sotto`.
- **Test command:** `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → expect `** TEST SUCCEEDED **`. **After creating ANY new file, run `xcodegen generate` before building** (the `.xcodeproj` is generated; xcodegen globs `Sotto/` and `SottoTests/`).
- **The `.xcodeproj` is gitignored** (`*.xcodeproj` in `.gitignore`) — it is regenerated locally via `xcodegen generate` and **never committed**. Do NOT `git add Sotto.xcodeproj`; stage only source/test/doc files. (Commit-step `git add` lines below list source/test files only.)

---

## File Structure

**New production files** (all under `Sotto/Files/` unless noted):
- `CoordinatedMirror.swift` — reusable `NSFileCoordinator` copy/remove primitives into a destination root. Extracted from the deleted `SegmentExporter`; the security-scoped-bookmark specifics go away (a ubiquity container is app-owned, needs no access scoping).
- `TranscriptSyncSink.swift` — the `TranscriptSyncSink` protocol, `SyncSegment` value + `SyncSegment(m4aURL:)`, and `SyncSinkRegistry` (active-sink assembly + fan-out helpers + a DEBUG-only test seam).
- `ICloudSyncSink.swift` — the iCloud sink: `upsert`/`remove`/`backupAll`/`removeAllBackups`/`hasBackups`, resolving the ubiquity container lazily.
- `ICloudRestore.swift` — inbound hydration: enumerate container transcripts, copy those missing locally, rebuild affected `_day.json`.
- `Sotto/Sotto.entitlements` — iCloud container entitlements.

**Modified production files:**
- `Sotto/Files/RetentionPolicy.swift` — add `SettingsStore.iCloudBackupEnabled` (default on).
- `Sotto/App/AppModel.swift` — rewire 5 mutation sites to the fan-out; add backup/restore/remove/availability entry points; launch restore; restore status; clear stale keys.
- `Sotto/App/SettingsView.swift` — remove folder-picker block; add **Backup & Restore** section.
- `project.yml` — wire `CODE_SIGN_ENTITLEMENTS` via the `entitlements` key.

**Deleted:**
- `Sotto/Files/SyncDestination.swift` — `SyncDestinationStore` + `SegmentExporter`, replaced by the sink files (deleted in Task 8, once the last reference is gone).

**Test files:**
- `SottoTests/CoordinatedMirrorTests.swift` (new).
- `SottoTests/ICloudSyncSinkTests.swift` (new — repurposes `SyncDestinationTests.swift`, which is deleted).
- `SottoTests/SyncFanOutTests.swift` (new — a single `@Suite(.serialized)`: `RecordingSink` helper, registry-toggle tests, fan-out mechanics, and (Task 7) AppModel wiring. Every test reads/writes the process-global `testSinks` seam, so they MUST share one serialized suite — a sibling non-serialized suite would race it.)
- `SottoTests/ICloudRestoreTests.swift` (new).

---

## Task 1: `SettingsStore.iCloudBackupEnabled` flag

The one persisted bit the whole feature toggles on. Default **on** (opt-out) — Sotto is an ambient recorder and the safety net must protect users who never open Settings.

**Files:**
- Modify: `Sotto/Files/RetentionPolicy.swift` (add to the `extension SettingsStore` block, ~line 104 near `wifiOnlyUpload`)
- Test: `SottoTests/RetentionPolicyTests.swift` if it exists, else add a small `SettingsStoreICloudTests.swift`

**Interfaces:**
- Produces: `SettingsStore.iCloudBackupEnabled: Bool` (get/nonmutating set) — read by `SyncSinkRegistry.activeSinks` (Task 5) and AppModel's launch restore (Task 7).

- [ ] **Step 1: Write the failing test**

Create `SottoTests/SettingsStoreICloudTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct SettingsStoreICloudTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "settings-icloud-\(UUID().uuidString)")!
    }

    @Test func iCloudBackupDefaultsOnWhenUnset() {
        let settings = SettingsStore(defaults: freshSuite())
        #expect(settings.iCloudBackupEnabled == true)   // opt-out: default on
    }

    @Test func iCloudBackupRoundTripsFalse() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.iCloudBackupEnabled = false
        #expect(settings.iCloudBackupEnabled == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SettingsStoreICloudTests 2>&1 | tail -5`
Expected: FAIL — `value of type 'SettingsStore' has no member 'iCloudBackupEnabled'`.

- [ ] **Step 3: Add the accessor**

In `Sotto/Files/RetentionPolicy.swift`, inside `extension SettingsStore { ... }`, after the `wifiOnlyUpload` accessor:

```swift
    /// iCloud backup phase (design 2026-07-07): whether finalized transcripts mirror to the
    /// app's iCloud ubiquity container. Default ON (opt-out) — Sotto is an ambient recorder,
    /// so the "don't lose your data on a new phone" safety net protects the majority who never
    /// open Settings; `object(forKey:) == nil` distinguishes "never set" (→ true) from an
    /// explicit false, matching the wifiOnlyUpload precedent above.
    var iCloudBackupEnabled: Bool {
        get {
            defaults.object(forKey: "iCloudBackupEnabled") == nil
                ? true : defaults.bool(forKey: "iCloudBackupEnabled")
        }
        nonmutating set { defaults.set(newValue, forKey: "iCloudBackupEnabled") }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SettingsStoreICloudTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/RetentionPolicy.swift SottoTests/SettingsStoreICloudTests.swift
git commit -m "feat: SettingsStore.iCloudBackupEnabled (default on)"
```

---

## Task 2: `CoordinatedMirror` — reusable coordinated copy/remove

The reusable core of the old `SegmentExporter`, minus the folder-picker's security-scoped-bookmark handling (a ubiquity container is app-owned). Operates on a plain destination root, preserving the `<root>/<day>/<file>` layout.

**Files:**
- Create: `Sotto/Files/CoordinatedMirror.swift`
- Test: `SottoTests/CoordinatedMirrorTests.swift`

**Interfaces:**
- Produces:
  - `CoordinatedMirror.copy(_ source: URL, day: String, into root: URL) -> Bool` (`@discardableResult`) — coordinated copy of `source` into `<root>/<day>/`, creating the day dir, replacing an existing file of the same name; `true` when the copy landed, `false` if the source is missing or the copy failed.
  - `CoordinatedMirror.remove(_ names: [String], day: String, from root: URL)` — coordinated removal of `<root>/<day>/<name>` for each name; absent files are fine.
- Consumed by: `ICloudSyncSink` (Task 4).

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/CoordinatedMirrorTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct CoordinatedMirrorTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatedMirror-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ text: String, at url: URL) {
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func copyCreatesDayDirAndCopies() {
        let src = tempDir(), dest = tempDir()
        let source = src.appendingPathComponent("09-15-00.md")
        writeFile("body", at: source)

        let ok = CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)

        #expect(ok == true)
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-05/09-15-00.md").path))
    }

    @Test func copyReplacesExisting() throws {
        let src = tempDir(), dest = tempDir()
        let source = src.appendingPathComponent("09-15-00.md")
        writeFile("v1", at: source)
        CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)
        writeFile("v2", at: source)

        CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)

        let landed = dest.appendingPathComponent("2026-07-05/09-15-00.md")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "v2")
    }

    @Test func copyOfMissingSourceReturnsFalse() {
        let dest = tempDir()
        let missing = tempDir().appendingPathComponent("nope.md")
        #expect(CoordinatedMirror.copy(missing, day: "2026-07-05", into: dest) == false)
    }

    @Test func removeDeletesNamedFilesAndToleratesAbsence() {
        let src = tempDir(), dest = tempDir()
        let source = src.appendingPathComponent("09-15-00.md")
        writeFile("body", at: source)
        CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)
        let landed = dest.appendingPathComponent("2026-07-05/09-15-00.md")
        #expect(FileManager.default.fileExists(atPath: landed.path))

        CoordinatedMirror.remove(["09-15-00.md"], day: "2026-07-05", from: dest)
        #expect(!FileManager.default.fileExists(atPath: landed.path))

        // Second remove of the now-absent file: silent no-op, never a crash.
        CoordinatedMirror.remove(["09-15-00.md"], day: "2026-07-05", from: dest)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/CoordinatedMirrorTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'CoordinatedMirror' in scope`.

- [ ] **Step 3: Create `CoordinatedMirror.swift`**

```swift
import Foundation

/// Coordinated (NSFileCoordinator) file mirroring into a destination root that preserves the
/// `<root>/<day>/<file>` day-directory layout. Extracted from the deleted M11 `SegmentExporter`;
/// the security-scoped-bookmark handling went with the folder picker — a ubiquity container is
/// app-owned and needs no access scoping. Best-effort: every failure degrades to "didn't
/// mirror"; nothing here ever throws into a caller.
enum CoordinatedMirror {
    /// Coordinated copy of `source` into `<root>/<day>/`, creating the day directory and
    /// replacing any existing file of the same name. Returns true when the file landed;
    /// false when the source is missing or the copy failed.
    @discardableResult
    static func copy(_ source: URL, day: String, into root: URL) -> Bool {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        var copied = false
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            copied = copyReplacing(from: source, into: dir)
        }
        return copied
    }

    /// Coordinated removal of `<root>/<day>/<name>` for each name. Missing files are fine
    /// (never mirrored, or already gone) — local state is truth.
    static func remove(_ names: [String], day: String, from root: URL) {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            for name in names {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private static func copyReplacing(from source: URL, into directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let target = directory.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/CoordinatedMirrorTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/CoordinatedMirror.swift SottoTests/CoordinatedMirrorTests.swift
git commit -m "feat: CoordinatedMirror — reusable coordinated copy/remove core"
```

---

## Task 3: `TranscriptSyncSink` protocol + `SyncSegment`

The abstraction every backup provider conforms to, and the value that carries one finalized conversation through the fan-out.

**Files:**
- Create: `Sotto/Files/TranscriptSyncSink.swift`
- Test: `SottoTests/SyncSegmentTests.swift`

**Interfaces:**
- Produces:
  - `protocol TranscriptSyncSink: Sendable { func upsert(_ segment: SyncSegment) async; func remove(day: String, basename: String) async }`
  - `struct SyncSegment: Sendable { let day: String; let basename: String; let markdown: URL; let audio: URL? }` (keeps its synthesized memberwise init)
  - `extension SyncSegment { init(m4aURL: URL) }` — derives `day`/`basename`/`markdown` from `<root>/<day>/<basename>.m4a`; `audio` is the `.m4a` only when it still exists on disk.
- Consumed by: `ICloudSyncSink` (Task 4), `SyncSinkRegistry` (Task 5).

- [ ] **Step 1: Write the failing test**

Create `SottoTests/SyncSegmentTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct SyncSegmentTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSegment-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func derivesDayBasenameMarkdownFromM4A() {
        let root = tempDir()
        let m4a = root.appendingPathComponent("2026-07-05/09-15-00.m4a")

        let segment = SyncSegment(m4aURL: m4a)

        #expect(segment.day == "2026-07-05")
        #expect(segment.basename == "09-15-00")
        #expect(segment.markdown.lastPathComponent == "09-15-00.md")
    }

    @Test func audioPresentOnlyWhenFileExists() throws {
        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")

        #expect(SyncSegment(m4aURL: m4a).audio == nil)   // retention deleted it → nil
        try Data([0x01]).write(to: m4a)
        #expect(SyncSegment(m4aURL: m4a).audio == m4a)   // kept → present
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncSegmentTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'SyncSegment' in scope`.

- [ ] **Step 3: Create `TranscriptSyncSink.swift`** (protocol + value only — `SyncSinkRegistry` lands in Task 5)

```swift
import Foundation

/// A destination that mirrors finalized transcripts out of the canonical local store. All
/// methods are best-effort and MUST NEVER throw into the caller: a slow/failed backup can
/// never fail a transcription job, block the queue, or ride the main actor.
///
/// The surface is `upsert`/`remove` only — permanently. No Sotto feature performs a
/// filesystem-level rename/move: merge reuses the earliest part's existing basename
/// (`upsert(earliest) + remove(others)`), and rename rewrites the `.md` content in place
/// without changing the filename (a plain `upsert`). So no `move` verb is ever needed.
protocol TranscriptSyncSink: Sendable {
    /// Mirror a finalized conversation. `markdown` is always present; `audio` is present only
    /// when retention kept it. Sinks that don't back up audio (iCloud) ignore it.
    func upsert(_ segment: SyncSegment) async
    /// Propagate a local deletion or a merge-consumed part.
    func remove(day: String, basename: String) async
}

/// One finalized conversation, as the fan-out sees it. `day`/`basename` are the store-layout
/// coordinates (`<root>/<day>/<basename>.{md,m4a}`).
struct SyncSegment: Sendable {
    let day: String        // "2026-07-07" (day-directory name)
    let basename: String   // "09-15-00"  (filename stem, shared by .md/.m4a)
    let markdown: URL      // local source .md
    let audio: URL?        // local source .m4a; nil when retention deleted it
}

extension SyncSegment {
    /// Derives the segment from a conversation's `.m4a` URL (`<root>/<day>/<basename>.m4a`).
    /// `audio` is included only when the file still exists — retention may have deleted it
    /// before the mirror runs, and the transcript must still ship.
    init(m4aURL: URL) {
        let day = m4aURL.deletingLastPathComponent().lastPathComponent
        let basename = m4aURL.deletingPathExtension().lastPathComponent
        let markdown = m4aURL.deletingPathExtension().appendingPathExtension("md")
        let audio = FileManager.default.fileExists(atPath: m4aURL.path) ? m4aURL : nil
        self.init(day: day, basename: basename, markdown: markdown, audio: audio)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncSegmentTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/TranscriptSyncSink.swift SottoTests/SyncSegmentTests.swift
git commit -m "feat: TranscriptSyncSink protocol + SyncSegment"
```

---

## Task 4: `ICloudSyncSink` — outbound backup + backfill/purge

The only sink this phase ships. Transcripts-only (never audio) into `<container>/Transcripts/`. Container resolution is behind an injected `@Sendable () -> URL?` closure so (a) the "iCloud unavailable → no-op" branch is deterministically testable and (b) resolution stays lazy/off-main (it's documented as slow).

**Files:**
- Create: `Sotto/Files/ICloudSyncSink.swift`
- Test: `SottoTests/ICloudSyncSinkTests.swift` (new; delete the now-obsolete `SottoTests/SyncDestinationTests.swift`)

**Interfaces:**
- Consumes: `TranscriptSyncSink`, `SyncSegment` (Task 3); `CoordinatedMirror` (Task 2).
- Produces:
  - `struct ICloudSyncSink: TranscriptSyncSink` with `static let containerIdentifier = "iCloud.com.decanlys.Sotto"`, `init(resolveContainer: @Sendable @escaping () -> URL? = <real container>)`.
  - `func upsert(_:) async`, `func remove(day:basename:) async` (protocol).
  - `func backupAll(localRoot: URL) async -> Int` — sweeps every local `<day>/*.md` into the container; returns count copied.
  - `func removeAllBackups() async` — coordinated removal of the whole `Transcripts/` prefix.
  - `func hasBackups() async -> Bool` — whether the container holds any transcript.
- Consumed by: `SyncSinkRegistry` (Task 5), `AppModel` (Task 7), `ICloudRestore` (Task 6 uses `containerIdentifier`).

- [ ] **Step 1: Delete the obsolete test file and write the new one**

```bash
git rm SottoTests/SyncDestinationTests.swift
```

Create `SottoTests/ICloudSyncSinkTests.swift` (layout/overwrite/skip-internal-files assertions carried over from the deleted file, retargeted at an injected container root; note the **transcripts-only** change — `.m4a` is never mirrored now):

```swift
import Foundation
import Testing
@testable import Sotto

struct ICloudSyncSinkTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudSyncSink-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<localRoot>/<day>/<name>.md [+ .m4a]`; returns the m4a URL (created iff `m4a`).
    @discardableResult
    private func makeSegment(
        root: URL, day: String, name: String, md: String? = "transcript", m4a: Bool = true
    ) throws -> URL {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4aURL = dayDir.appendingPathComponent("\(name).m4a")
        if m4a { try Data([0x01]).write(to: m4aURL) }
        if let md {
            try md.write(to: dayDir.appendingPathComponent("\(name).md"),
                         atomically: true, encoding: .utf8)
        }
        return m4aURL
    }

    private func sink(container: URL) -> ICloudSyncSink {
        ICloudSyncSink(resolveContainer: { container })
    }

    private func transcript(_ container: URL, _ day: String, _ base: String) -> URL {
        container.appendingPathComponent("Transcripts/\(day)/\(base).md")
    }

    @Test func upsertCopiesMarkdownOnlyIntoTranscriptsPrefix() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "09-15-00")

        await sink(container: container).upsert(SyncSegment(m4aURL: m4a))

        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-07-05", "09-15-00").path))
        // Audio is NEVER backed up to iCloud (quota + privacy).
        #expect(!FileManager.default.fileExists(
            atPath: container.appendingPathComponent("Transcripts/2026-07-05/09-15-00.m4a").path))
    }

    @Test func upsertOverwritesExistingTranscript() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "11-00-00", md: "v1")
        let s = sink(container: container)
        await s.upsert(SyncSegment(m4aURL: m4a))
        try "v2".write(to: m4a.deletingPathExtension().appendingPathExtension("md"),
                       atomically: true, encoding: .utf8)

        await s.upsert(SyncSegment(m4aURL: m4a))

        #expect(try String(contentsOf: transcript(container, "2026-07-05", "11-00-00"), encoding: .utf8) == "v2")
    }

    @Test func removeDeletesTranscriptAndToleratesAbsence() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-03-14", name: "09-15-30")
        let s = sink(container: container)
        await s.upsert(SyncSegment(m4aURL: m4a))
        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-03-14", "09-15-30").path))

        await s.remove(day: "2026-03-14", basename: "09-15-30")
        #expect(!FileManager.default.fileExists(atPath: transcript(container, "2026-03-14", "09-15-30").path))

        await s.remove(day: "2026-03-14", basename: "09-15-30")   // second remove: no-op, no crash
    }

    @Test func backupAllSweepsEveryDayMarkdownAndSkipsInternalFiles() async throws {
        let local = tempDir(), container = tempDir()
        try makeSegment(root: local, day: "2026-07-04", name: "08-00-00")             // md + m4a
        try makeSegment(root: local, day: "2026-07-05", name: "09-00-00", m4a: false) // md only
        try Data([1]).write(to: local.appendingPathComponent("2026-07-04/_day.json"))
        try Data([1]).write(to: local.appendingPathComponent("2026-07-04/08-30-00.caf"))

        let copied = await sink(container: container).backupAll(localRoot: local)

        #expect(copied == 2)   // 2 × .md only — never .m4a / _day.json / .caf
        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-07-04", "08-00-00").path))
        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-07-05", "09-00-00").path))
        #expect(!FileManager.default.fileExists(
            atPath: container.appendingPathComponent("Transcripts/2026-07-04/08-00-00.m4a").path))
    }

    @Test func removeAllBackupsClearsThePrefixAndHasBackupsTracksIt() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "09-15-00")
        let s = sink(container: container)
        #expect(await s.hasBackups() == false)
        await s.upsert(SyncSegment(m4aURL: m4a))
        #expect(await s.hasBackups() == true)

        await s.removeAllBackups()
        #expect(await s.hasBackups() == false)
    }

    @Test func unavailableContainerMakesEveryOpANoOp() async throws {
        let local = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "09-15-00")
        let s = ICloudSyncSink(resolveContainer: { nil })   // signed out / no entitlement

        await s.upsert(SyncSegment(m4aURL: m4a))    // no crash, nothing to assert but no throw
        await s.remove(day: "2026-07-05", basename: "09-15-00")
        #expect(await s.backupAll(localRoot: local) == 0)
        #expect(await s.hasBackups() == false)
        await s.removeAllBackups()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ICloudSyncSinkTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ICloudSyncSink' in scope`.

- [ ] **Step 3: Create `ICloudSyncSink.swift`**

```swift
import Foundation

/// iCloud transcript backup (design 2026-07-07): mirrors finalized `.md` transcripts — never
/// audio — into the app's private ubiquity container under a `Transcripts/` prefix. The
/// container is NOT document-scope-public, so the backup never appears in Files.app and can't
/// be confused with the canonical local store.
///
/// Best-effort and failure-isolated per `TranscriptSyncSink`: signed out / iCloud unavailable
/// → the resolver returns nil and every op is a silent no-op (the "sync off for now, never an
/// error" degrade). Retried implicitly by the next event or a manual "Back up now".
struct ICloudSyncSink: TranscriptSyncSink {
    static let containerIdentifier = "iCloud.com.decanlys.Sotto"

    /// Resolves `<container>` (NOT yet `Transcripts/`), or nil when iCloud is unavailable.
    /// Injected so tests can supply a temp dir or force the unavailable path (`{ nil }`).
    /// `url(forUbiquityContainerIdentifier:)` is documented as potentially slow — this closure
    /// is only ever CALLED from the async ops below (which the registry runs detached), never
    /// from `init`/`activeSinks` on the calling actor.
    private let resolveContainer: @Sendable () -> URL?

    init(resolveContainer: @Sendable @escaping () -> URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: ICloudSyncSink.containerIdentifier)
    }) {
        self.resolveContainer = resolveContainer
    }

    private func transcriptsRoot() -> URL? {
        resolveContainer()?.appendingPathComponent("Transcripts", isDirectory: true)
    }

    // MARK: TranscriptSyncSink

    func upsert(_ segment: SyncSegment) async {
        guard let root = transcriptsRoot() else { return }   // signed out → no-op
        CoordinatedMirror.copy(segment.markdown, day: segment.day, into: root)   // .md only; audio ignored
    }

    func remove(day: String, basename: String) async {
        guard let root = transcriptsRoot() else { return }
        CoordinatedMirror.remove(["\(basename).md"], day: day, from: root)
    }

    // MARK: Backfill / purge (Settings "Back up now" / "Remove iCloud backup")

    /// Sweeps every `<localRoot>/<day>/*.md` into the container, skipping `_day.json`/`.caf`/
    /// `.m4a`. Returns the number of transcripts copied. Container nil → 0.
    func backupAll(localRoot: URL) async -> Int {
        guard let root = transcriptsRoot() else { return 0 }
        guard let days = try? FileManager.default.contentsOfDirectory(
            at: localRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var copied = 0
        for day in days {
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: day, includingPropertiesForKeys: nil) else { continue }
            for md in files where md.pathExtension == "md" {
                if CoordinatedMirror.copy(md, day: day.lastPathComponent, into: root) { copied += 1 }
            }
        }
        return copied
    }

    /// Coordinated removal of the entire `Transcripts/` prefix — for the user who wants their
    /// transcripts GONE from iCloud, not just paused. Container nil → no-op.
    func removeAllBackups() async {
        guard let root = transcriptsRoot() else { return }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: root, options: .forDeleting, error: &coordinationError) { dir in
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Whether the container currently holds any transcript — drives showing the "Remove iCloud
    /// backup" action. Container nil → false.
    func hasBackups() async -> Bool {
        // Two-level walk (`Transcripts/<day>/*.md`) rather than `FileManager.enumerator`, whose
        // non-Sendable `DirectoryEnumerator` trips Swift 6 region isolation in this async context.
        guard let root = transcriptsRoot(),
              let days = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for day in days {
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: day, includingPropertiesForKeys: nil) else { continue }
            for md in files where md.pathExtension == "md" { return true }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ICloudSyncSinkTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/ICloudSyncSink.swift SottoTests/ICloudSyncSinkTests.swift
git commit -m "feat: ICloudSyncSink — transcripts-only iCloud backup + backfill/purge"
```

---

## Task 5: `SyncSinkRegistry` — active-sink assembly + fan-out

Assembles the active sinks from settings (resolved fresh per event so a toggle applies immediately) and provides the two fan-out helpers every AppModel site calls. A `#if DEBUG` test seam lets tests inject a recording sink.

**Files:**
- Modify: `Sotto/Files/TranscriptSyncSink.swift` (append `SyncSinkRegistry`)
- Test: `SottoTests/SyncSinkRegistryTests.swift` (activeSinks toggle) + `SottoTests/SyncFanOutTests.swift` (fan-out mechanics + `RecordingSink` helper)

**Interfaces:**
- Consumes: `SettingsStore.iCloudBackupEnabled` (Task 1); `ICloudSyncSink` (Task 4); `SyncSegment` (Task 3).
- Produces:
  - `SyncSinkRegistry.activeSinks(_ settings: SettingsStore) -> [any TranscriptSyncSink]`
  - `SyncSinkRegistry.upsert(m4aURL: URL, _ settings: SettingsStore)` — builds `SyncSegment(m4aURL:)`, fans out `upsert` to every active sink, each `Task.detached(priority: .utility)`.
  - `SyncSinkRegistry.remove(m4aURL: URL, _ settings: SettingsStore)` — derives `day`/`basename`, fans out `remove` detached.
  - `#if DEBUG` `SyncSinkRegistry.testSinks: [any TranscriptSyncSink]?` — when set, `activeSinks` returns it verbatim.
  - Test helper `RecordingSink` (in `SyncFanOutTests.swift`), reused by Task 7.
- Consumed by: all five AppModel choke points (Task 7).

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/SyncSinkRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct SyncSinkRegistryTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sink-registry-\(UUID().uuidString)")!
    }

    @Test func iCloudSinkPresentWhenEnabled() {
        let settings = SettingsStore(defaults: freshSuite())   // default on
        let sinks = SyncSinkRegistry.activeSinks(settings)
        #expect(sinks.count == 1)
        #expect(sinks.first is ICloudSyncSink)
    }

    @Test func noSinksWhenDisabled() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.iCloudBackupEnabled = false
        #expect(SyncSinkRegistry.activeSinks(settings).isEmpty)
    }
}
```

Create `SottoTests/SyncFanOutTests.swift` (the `.serialized` suite — it mutates the process-wide `SyncSinkRegistry.testSinks`, so its tests must not run in parallel with each other):

```swift
import Foundation
import Testing
@testable import Sotto

/// Test double: records the calls it receives so a test can assert the fan-out drove the
/// expected upsert/remove. An actor because the fan-out invokes it from detached tasks.
actor RecordingSink: TranscriptSyncSink {
    enum Call: Equatable, Sendable {
        case upsert(day: String, basename: String)
        case remove(day: String, basename: String)
    }
    private(set) var calls: [Call] = []

    func upsert(_ segment: SyncSegment) async {
        calls.append(.upsert(day: segment.day, basename: segment.basename))
    }
    func remove(day: String, basename: String) async {
        calls.append(.remove(day: day, basename: basename))
    }

    /// Polls until at least `n` calls have landed (fan-out is detached/async) or ~2 s elapses.
    func waitForCalls(_ n: Int) async -> [Call] {
        for _ in 0..<200 {
            if calls.count >= n { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return calls
    }
}

@Suite(.serialized)
struct SyncFanOutTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "fan-out-\(UUID().uuidString)")!
    }

    @Test func upsertFansOutDerivedSegmentToEverySink() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let m4a = URL(fileURLWithPath: "/tmp/Sotto/2026-07-05/09-15-00.m4a")
        SyncSinkRegistry.upsert(m4aURL: m4a, SettingsStore(defaults: freshSuite()))

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.upsert(day: "2026-07-05", basename: "09-15-00")])
    }

    @Test func removeFansOutDerivedCoordinatesToEverySink() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let m4a = URL(fileURLWithPath: "/tmp/Sotto/2026-07-05/09-15-00.m4a")
        SyncSinkRegistry.remove(m4aURL: m4a, SettingsStore(defaults: freshSuite()))

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.remove(day: "2026-07-05", basename: "09-15-00")])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncSinkRegistryTests -only-testing:SottoTests/SyncFanOutTests 2>&1 | tail -5`
Expected: FAIL — `type 'SyncSinkRegistry' has no member 'activeSinks'` / `'testSinks'`.

- [ ] **Step 3: Append `SyncSinkRegistry` to `TranscriptSyncSink.swift`**

Add at the end of `Sotto/Files/TranscriptSyncSink.swift`:

```swift
/// Assembles the active sinks from current settings and fans mutation events out to them.
/// Sinks are resolved FRESH per event (mirrors the existing per-job `serviceProvider`
/// pattern), so toggling a provider applies immediately with nothing to reconstruct.
enum SyncSinkRegistry {
    #if DEBUG
    /// Test seam: when non-nil, `activeSinks` returns this verbatim, letting a test inject a
    /// recording sink. Process-wide mutable state — tests that set it must be `.serialized`.
    nonisolated(unsafe) static var testSinks: [any TranscriptSyncSink]?
    #endif

    static func activeSinks(_ settings: SettingsStore) -> [any TranscriptSyncSink] {
        #if DEBUG
        if let testSinks { return testSinks }
        #endif
        var sinks: [any TranscriptSyncSink] = []
        if settings.iCloudBackupEnabled { sinks.append(ICloudSyncSink()) }
        // Later phases append here: WebDAVSyncSink(config:), GoogleDriveSyncSink(...)
        return sinks
    }

    /// Fan a finalized-conversation upsert out to every active sink — each detached and
    /// failure-isolated so no sink's slow/failed I/O rides the caller. Safe to call from the
    /// MainActor choke points AND the @Sendable transition closure: takes a Sendable
    /// `SettingsStore` and captures no actor state.
    static func upsert(m4aURL: URL, _ settings: SettingsStore) {
        let segment = SyncSegment(m4aURL: m4aURL)
        for sink in activeSinks(settings) {
            Task.detached(priority: .utility) { await sink.upsert(segment) }
        }
    }

    /// Fan a deletion/merge-consumed-part out to every active sink, detached + failure-isolated.
    static func remove(m4aURL: URL, _ settings: SettingsStore) {
        let day = m4aURL.deletingLastPathComponent().lastPathComponent
        let basename = m4aURL.deletingPathExtension().lastPathComponent
        for sink in activeSinks(settings) {
            Task.detached(priority: .utility) { await sink.remove(day: day, basename: basename) }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncSinkRegistryTests -only-testing:SottoTests/SyncFanOutTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/TranscriptSyncSink.swift SottoTests/SyncSinkRegistryTests.swift SottoTests/SyncFanOutTests.swift
git commit -m "feat: SyncSinkRegistry — active-sink assembly + detached fan-out"
```

---

## Task 6: `ICloudRestore` — inbound hydration

Backup's other half: on a new phone, copy container transcripts missing locally into `Documents/Sotto` and rebuild the affected `_day.json` so they appear in history. Additive, idempotent, never overwrites a local file. Handles evicted placeholders (every transcript starts un-downloaded on a fresh device).

**Files:**
- Create: `Sotto/Files/ICloudRestore.swift`
- Test: `SottoTests/ICloudRestoreTests.swift`

**Interfaces:**
- Consumes: `ICloudSyncSink.containerIdentifier` (Task 4); `DayIndexStore.rebuildAndPersist(dayDirectory:)` (existing, `Sotto/Files/DayIndexStore.swift:119`).
- Produces: `ICloudRestore.run(localRoot: URL, containerRoot: URL? = nil, dayIndex: DayIndexStore) async -> Int` — returns the number of transcripts restored. `containerRoot` nil resolves the real ubiquity container; tests inject a temp dir.
- Consumed by: `AppModel` launch restore + `restoreFromICloud()` (Task 7).

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/ICloudRestoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct ICloudRestoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudRestore-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A minimal valid transcript with parseable frontmatter so DayIndexRebuilder indexes it.
    private func transcriptBody(date: String) -> String {
        """
        ---
        date: \(date)
        duration: 12.0
        backend: speechAnalyzer
        title: Restored chat
        ---

        **Speaker 0:** hello there
        """
    }

    /// Writes `<container>/Transcripts/<day>/<base>.md`.
    private func seedContainer(_ container: URL, day: String, base: String, iso: String) throws {
        let dir = container.appendingPathComponent("Transcripts/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try transcriptBody(date: iso).write(
            to: dir.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
    }

    @Test func restoresMissingTranscriptAndRebuildsIndex() async throws {
        let local = tempDir(), container = tempDir()
        try seedContainer(container, day: "2026-07-05", base: "09-15-00", iso: "2026-07-05T09:15:00Z")
        let dayIndex = DayIndexStore(rootDirectory: local)

        let restored = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)

        #expect(restored == 1)
        #expect(FileManager.default.fileExists(
            atPath: local.appendingPathComponent("2026-07-05/09-15-00.md").path))
        // _day.json rebuilt from the restored .md, with hasAudio false (audio is never backed up).
        let index = await dayIndex.index(forDay: local.appendingPathComponent("2026-07-05"))
        #expect(index?.segments.count == 1)
        #expect(index?.segments.first?.hasAudio == false)
        #expect(index?.segments.first?.transcriptionState == "done")
    }

    @Test func neverOverwritesAnExistingLocalTranscript() async throws {
        let local = tempDir(), container = tempDir()
        try seedContainer(container, day: "2026-07-05", base: "09-15-00", iso: "2026-07-05T09:15:00Z")
        let localDay = local.appendingPathComponent("2026-07-05", isDirectory: true)
        try FileManager.default.createDirectory(at: localDay, withIntermediateDirectories: true)
        try "LOCAL WINS".write(
            to: localDay.appendingPathComponent("09-15-00.md"), atomically: true, encoding: .utf8)
        let dayIndex = DayIndexStore(rootDirectory: local)

        let restored = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)

        #expect(restored == 0)
        #expect(try String(contentsOf: localDay.appendingPathComponent("09-15-00.md"), encoding: .utf8) == "LOCAL WINS")
    }

    @Test func idempotentAcrossTwoRuns() async throws {
        let local = tempDir(), container = tempDir()
        try seedContainer(container, day: "2026-07-05", base: "09-15-00", iso: "2026-07-05T09:15:00Z")
        let dayIndex = DayIndexStore(rootDirectory: local)

        let first = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)
        let second = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)

        #expect(first == 1)
        #expect(second == 0)   // nothing new the second time
    }

    @Test func emptyContainerRestoresNothing() async throws {
        let local = tempDir(), container = tempDir()
        let dayIndex = DayIndexStore(rootDirectory: local)
        #expect(await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ICloudRestoreTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ICloudRestore' in scope`.

- [ ] **Step 3: Create `ICloudRestore.swift`**

```swift
import Foundation

/// iCloud restore (design 2026-07-07): the half that saves the user on a new phone. Copies
/// every container transcript missing locally into `Documents/Sotto`, then rebuilds the
/// affected `_day.json` so restored conversations appear in history.
///
/// Additive + idempotent: never overwrites an existing local `.md` (local is canonical), and
/// re-running restores only what's still missing. Bootstrap safety: because outbound deletes
/// are event-driven only, an empty local store emits zero deletes — a fresh install can never
/// wipe the backup before restoring from it.
enum ICloudRestore {
    /// Returns the number of transcripts copied in. `containerRoot` nil resolves the real
    /// ubiquity container; tests inject a temp dir.
    static func run(localRoot: URL, containerRoot: URL? = nil, dayIndex: DayIndexStore) async -> Int {
        let container = containerRoot ?? FileManager.default
            .url(forUbiquityContainerIdentifier: ICloudSyncSink.containerIdentifier)
        guard let transcripts = container?.appendingPathComponent("Transcripts", isDirectory: true),
              let dayDirs = try? FileManager.default.contentsOfDirectory(
                  at: transcripts, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }

        var restored = 0
        var touchedDays: Set<String> = []
        for dayDir in dayDirs {
            guard (try? dayDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let day = dayDir.lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: nil) else { continue }

            for md in files where md.pathExtension == "md" {
                // Evicted placeholder on a fresh device: request download; the coordinated read
                // below then blocks until it materializes. `try?` — a non-ubiquitous URL (tests,
                // already-local) simply isn't downloadable, which is fine.
                try? FileManager.default.startDownloadingUbiquitousItem(at: md)

                let localDay = localRoot.appendingPathComponent(day, isDirectory: true)
                let localMD = localDay.appendingPathComponent(md.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: localMD.path) else { continue }  // never overwrite

                try? FileManager.default.createDirectory(
                    at: localDay, withIntermediateDirectories: true)
                var copied = false
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                coordinator.coordinate(readingItemAt: md, options: [], error: &coordinationError) { src in
                    copied = (try? FileManager.default.copyItem(at: src, to: localMD)) != nil
                }
                if copied { restored += 1; touchedDays.insert(day) }
            }
        }

        // Rebuild _day.json from the restored .md frontmatter so history shows them. Restored
        // conversations have hasAudio = false — the rebuilder infers it from the (absent) .m4a.
        for day in touchedDays {
            _ = await dayIndex.rebuildAndPersist(
                dayDirectory: localRoot.appendingPathComponent(day, isDirectory: true))
        }
        return restored
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ICloudRestoreTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/ICloudRestore.swift SottoTests/ICloudRestoreTests.swift
git commit -m "feat: ICloudRestore — additive, idempotent inbound hydration"
```

---

## Task 7: AppModel rewiring — fan-out at the five sites + backup/restore entry points

Turn each of the five `SegmentExporter`/`SyncDestinationStore` call sites into a `SyncSinkRegistry` fan-out; replace `exportAllToSyncDestination()` with iCloud backup/restore/remove/availability entry points; add launch-time restore + a restore status line; clear the stale folder-picker UserDefaults keys. `SyncDestination.swift` is NOT deleted here — SettingsView still references it until Task 8.

**Files:**
- Modify: `Sotto/App/AppModel.swift` (sites at lines 377–381, 396–400, 437–448, 479–483, 737–743; method 514–520; property near 99; launch region near 783; top of `performSetUp` near 585)
- Test: `SottoTests/SyncFanOutTests.swift` (append AppModel-driven wiring tests to the existing `.serialized` suite)

**Interfaces:**
- Consumes: `SyncSinkRegistry.upsert/remove` (Task 5); `ICloudSyncSink` + `ICloudRestore` (Tasks 4/6); `SettingsStore.iCloudBackupEnabled` (Task 1); `loadInitialHistory()` (existing, `AppModel.swift:224`).
- Produces (new AppModel API for Settings, Task 8):
  - `func backupAllToICloud() async -> Int`
  - `func restoreFromICloud() async -> Int`
  - `func removeICloudBackup() async`
  - `func iCloudHasBackups() async -> Bool`
  - `func iCloudAvailable() async -> Bool`
  - `private(set) var restoreStatus: String?`
  - `func dismissRestoreStatus()`

- [ ] **Step 1: Write the failing AppModel wiring tests**

Append to `SottoTests/SyncFanOutTests.swift` (inside the existing `@Suite(.serialized) struct SyncFanOutTests`, reusing `RecordingSink`):

```swift
    // --- AppModel site wiring: each mutation drives the expected verb through the registry ---

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-out-appmodel-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor @Test func deleteSegmentFansOutRemove() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try! FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")
        try! Data([0x01]).write(to: m4a)
        try! "body".write(to: dayDir.appendingPathComponent("09-15-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(segmentRootOverride: root)
        await model.deleteSegment(m4aURL: m4a)

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.remove(day: "2026-07-05", basename: "09-15-00")])
    }

    @MainActor @Test func renameSegmentFansOutUpsert() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try! FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")
        try! Data([0x01]).write(to: m4a)
        // A valid transcript so ConversationMerger.applyTitle succeeds (else rename returns early).
        try! """
        ---
        date: 2026-07-05T09:15:00Z
        duration: 5.0
        ---

        **Speaker 0:** hi
        """.write(to: dayDir.appendingPathComponent("09-15-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(segmentRootOverride: root)
        await model.renameSegment(m4aURL: m4a, title: "New title",
                                  startTime: Date(timeIntervalSince1970: 1_783_667_700))

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.upsert(day: "2026-07-05", basename: "09-15-00")])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncFanOutTests 2>&1 | tail -5`
Expected: FAIL — the recorder gets **zero** calls (delete/rename still route through `SyncDestinationStore().resolve()`, which returns nil in the sim, so no fan-out reaches `testSinks`).

- [ ] **Step 3a: Rewire site 1 — the transition-done handler** (`AppModel.swift:737–743`)

Replace:

```swift
                    if transition.job.state == .done,
                       let syncDestination = SyncDestinationStore().resolve() {
                        let m4aURL = transition.job.m4aURL
                        Task.detached(priority: .utility) {
                            SegmentExporter.export(m4aURL: m4aURL, to: syncDestination)
                        }
                    }
```

with (uses the local `settings` already captured at line 585 — no `self` pulled into this @Sendable closure):

```swift
                    // Backup fan-out: after retention has decided what stays, mirror the
                    // finalized transcript to every active sink (design 2026-07-07). AFTER
                    // retention on purpose — the backup reflects what the app keeps (the
                    // transcript always ships; iCloud ignores audio anyway). Sinks resolved
                    // fresh so a toggle applies immediately; each op detached + failure-isolated
                    // inside the registry, so provider I/O never blocks this handler.
                    if transition.job.state == .done {
                        SyncSinkRegistry.upsert(m4aURL: transition.job.m4aURL, settings)
                    }
```

- [ ] **Step 3b: Rewire site 2 — `deleteSegment`** (`AppModel.swift:377–381`)

Replace:

```swift
        if let destination = SyncDestinationStore().resolve() {
            Task.detached(priority: .utility) {
                SegmentExporter.remove(m4aURL: m4aURL, from: destination)
            }
        }
```

with:

```swift
        // Delete-propagation: clean every backup sink's copy (design 2026-07-07 §3, delete verb).
        SyncSinkRegistry.remove(m4aURL: m4aURL, settings)
```

- [ ] **Step 3c: Rewire site 3 — `renameSegment`** (`AppModel.swift:396–400`)

Replace:

```swift
        if let destination = SyncDestinationStore().resolve() {
            Task.detached(priority: .utility) {
                SegmentExporter.export(m4aURL: m4aURL, to: destination)
            }
        }
```

with:

```swift
        // Rename rewrites the .md in place (filename unchanged) → a plain upsert (design §3).
        SyncSinkRegistry.upsert(m4aURL: m4aURL, settings)
```

- [ ] **Step 3d: Rewire site 4 — `mergeSegments`** (`AppModel.swift:437–448`)

Replace the whole `if let destination = SyncDestinationStore().resolve() { ... }` block:

```swift
        if let destination = SyncDestinationStore().resolve() {
            let mergedM4A = outcome.mergedM4AURL
            let mergedHasAudio = outcome.mergedEntry.hasAudio
            let removedURLs = outcome.removedIDs.map {
                dayDirectory.appendingPathComponent("\($0).m4a")
            }
            Task.detached(priority: .utility) {
                if !mergedHasAudio { SegmentExporter.remove(m4aURL: mergedM4A, from: destination) }
                SegmentExporter.export(m4aURL: mergedM4A, to: destination)
                for url in removedURLs { SegmentExporter.remove(m4aURL: url, from: destination) }
            }
        }
```

with (the canonical merge fan-out, design §3: `upsert(earliest) + remove(part) × N`. The old "remove the merged `.m4a` first" line was an artifact of the old exporter mirroring audio — iCloud never stored audio, so it's gone):

```swift
        // Merge = update the earliest part + drop the merged-away parts (design §3).
        SyncSinkRegistry.upsert(m4aURL: outcome.mergedM4AURL, settings)
        for id in outcome.removedIDs {
            SyncSinkRegistry.remove(m4aURL: dayDirectory.appendingPathComponent("\(id).m4a"), settings)
        }
```

- [ ] **Step 3e: Rewire site 5 — `regenerateNotes`** (`AppModel.swift:479–483`)

Replace:

```swift
        if let destination = SyncDestinationStore().resolve() {
            Task.detached(priority: .utility) {
                SegmentExporter.export(m4aURL: m4aURL, to: destination)
            }
        }
```

with:

```swift
        SyncSinkRegistry.upsert(m4aURL: m4aURL, settings)   // notes rewrite the .md → upsert
```

- [ ] **Step 3f: Replace `exportAllToSyncDestination()` with the iCloud entry points** (`AppModel.swift:509–520`)

Replace the whole doc-comment + method:

```swift
    /// M11 Settings "Export all now": mirrors every conversation under the local store into
    /// the sync destination. Returns nil when no destination is configured (or it stopped
    /// resolving — folder deleted, provider uninstalled), else the number of files copied.
    /// Detached for the same reason as the per-segment export: provider I/O must not ride
    /// the main actor.
    func exportAllToSyncDestination() async -> Int? {
        guard let destination = SyncDestinationStore().resolve() else { return nil }
        let root = segmentRoot
        return await Task.detached(priority: .utility) {
            SegmentExporter.exportAll(root: root, to: destination)
        }.value
    }
```

with:

```swift
    /// Settings "Back up now": sweeps every local transcript into the iCloud container.
    /// Detached — container I/O must not ride the main actor. Container unavailable → 0.
    func backupAllToICloud() async -> Int {
        let root = segmentRoot
        return await Task.detached(priority: .utility) {
            await ICloudSyncSink().backupAll(localRoot: root)
        }.value
    }

    /// Settings "Restore from iCloud" (manual): additively hydrate local from the container,
    /// then reload history (restore can add OLDER day directories that the incremental refresh
    /// can't surface). Returns the number restored.
    func restoreFromICloud() async -> Int {
        guard let dayIndex else { return 0 }
        let root = segmentRoot
        let restored = await Task.detached(priority: .utility) {
            await ICloudRestore.run(localRoot: root, dayIndex: dayIndex)
        }.value
        if restored > 0 { await loadInitialHistory() }
        return restored
    }

    /// Settings "Remove iCloud backup": purge the whole Transcripts/ prefix. Local is untouched.
    func removeICloudBackup() async {
        await Task.detached(priority: .utility) { await ICloudSyncSink().removeAllBackups() }.value
    }

    /// Whether the container currently holds any transcript — gates the "Remove iCloud backup"
    /// action + informs the status line.
    func iCloudHasBackups() async -> Bool {
        await Task.detached(priority: .utility) { await ICloudSyncSink().hasBackups() }.value
    }

    /// Whether the ubiquity container resolves (signed in + entitled). Detached: resolution is
    /// documented as potentially slow and must not ride the main actor.
    func iCloudAvailable() async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudSyncSink.containerIdentifier) != nil
        }.value
    }
```

- [ ] **Step 3g: Add the restore-status property + dismiss** (near `AppModel.swift:99`, after `hasLoadedHistoryOnce`)

```swift
    /// Set after a launch or manual iCloud restore actually added transcripts — surfaced as a
    /// small status line on the home screen and cleared when the user dismisses it. nil =
    /// nothing restored / not run yet.
    private(set) var restoreStatus: String?
```

And add a dismiss method next to `dismissRecoveryNotice()` (`AppModel.swift:326`):

```swift
    /// Lets the user clear the "Restored N transcripts from iCloud" line.
    func dismissRestoreStatus() {
        restoreStatus = nil
    }

    /// Applies a completed restore's result on the main actor: status line + full history
    /// reload (restore can add OLDER days the incremental refresh path won't surface).
    private func applyRestoreResult(_ count: Int) async {
        restoreStatus = "Restored \(count) transcript\(count == 1 ? "" : "s") from iCloud"
        await loadInitialHistory()
    }
```

- [ ] **Step 3h: Clear stale folder-picker keys + wire launch restore** (in `performSetUp`)

After `let settings = self.settings` (`AppModel.swift:585`), add the teardown migration:

```swift
        // Pre-release folder-picker teardown (design §8/§12): clear the dead M11 sync bookmark
        // keys so no dangling security-scoped bookmark lingers. Best-effort, no data migration
        // (there is no folder-picker install base).
        settings.defaults.removeObject(forKey: "syncDestinationBookmark")
        settings.defaults.removeObject(forKey: "syncDestinationDisplayName")
```

Then, immediately after the launch retention-sweep `Task.detached { ... }` block (which currently ends at `AppModel.swift:783`), still inside the `do`:

```swift
            // iCloud restore (additive, idempotent): hydrate transcripts backed up from a
            // previous device into the local store, then rebuild affected day indexes so they
            // surface in history. Detached — container download can block for seconds. Bootstrap
            // safety: outbound deletes are event-driven only, so an empty local store never wipes
            // the backup before this fills it (design §5).
            if settings.iCloudBackupEnabled {
                Task.detached { [weak self] in
                    let restored = await ICloudRestore.run(
                        localRoot: store.rootDirectory, dayIndex: dayIndexStore)
                    guard restored > 0 else { return }
                    await self?.applyRestoreResult(restored)
                }
            }
```

- [ ] **Step 4: Run the wiring tests + full suite to verify they pass**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncFanOutTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (delete → remove, rename → upsert both recorded).

Then confirm nothing else broke (AppModel still references `SyncDestinationStore`/`SegmentExporter`? It must NOT — grep to be sure):

Run: `grep -n "SyncDestinationStore\|SegmentExporter\|exportAllToSyncDestination" Sotto/App/AppModel.swift`
Expected: **no output** (all five sites + the method rewired).

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/AppModel.swift SottoTests/SyncFanOutTests.swift
git commit -m "refactor: AppModel fan-out to SyncSinkRegistry + iCloud backup/restore entry points"
```

---

## Task 8: SettingsView — remove folder picker, add Backup & Restore; delete `SyncDestination.swift`

Tear out the dead folder-picker UI and its `SyncDestinationStore` references, add the new **Backup & Restore** section (iCloud controls only this phase), and — with the last references gone — delete `SyncDestination.swift`.

**Files:**
- Modify: `Sotto/App/SettingsView.swift`
- Delete: `Sotto/Files/SyncDestination.swift`

**Interfaces:**
- Consumes: `AppModel.backupAllToICloud/restoreFromICloud/removeICloudBackup/iCloudHasBackups/iCloudAvailable` + `SettingsStore.iCloudBackupEnabled` (Task 7 / Task 1).

> **Note on testing:** this task is SwiftUI view code with no unit-test seam. Verification is (a) the build succeeds with zero warnings, (b) the full test suite still passes, and (c) the manual simulator checklist in Task 9. Do the edits, then run Steps 4–6.

- [ ] **Step 1: Remove the folder-picker plumbing**

In `Sotto/App/SettingsView.swift`:

1. Delete the import (line 4): `import UniformTypeIdentifiers`.
2. Delete the three folder-picker `@State` vars (lines 22–24):
   ```swift
   @State private var showSyncFolderPicker = false
   @State private var syncFolderName: String?
   @State private var exportAllResult: String?
   ```
   and add the new Backup & Restore state in their place:
   ```swift
   @State private var iCloudBackupEnabled = true
   @State private var iCloudStatus = "—"
   @State private var iCloudHasBackups = false
   @State private var backupResult: String?
   @State private var restoreResult: String?
   @State private var showRemoveBackupConfirm = false
   ```
3. Delete the entire `.fileImporter(isPresented: $showSyncFolderPicker, ...) { ... }` modifier (lines 39–47).
4. In `.task { ... }`, delete `syncFolderName = SyncDestinationStore().displayName` (line 59) and add, after `wifiOnly = settings.wifiOnlyUpload`:
   ```swift
   iCloudBackupEnabled = settings.iCloudBackupEnabled
   iCloudStatus = await model.iCloudAvailable()
       ? "Backed up to iCloud"
       : "iCloud unavailable — sign in to iCloud in Settings"
   iCloudHasBackups = await model.iCloudHasBackups()
   ```

- [ ] **Step 2: Remove the M11 cloud-sync block from `storageSection`**

In `storageSection` (lines 207–256), delete the entire `// M11 cloud sync:` block — everything from `if let syncFolderName {` through its matching `else { ... }` close (lines 225–254). Keep the retention picker, the usage `LabeledContent`s, and the "Your recordings live in Files…" caption above it. `storageSection` now ends right after that caption.

- [ ] **Step 3: Add the `backupSection` and slot it into the Form**

Add `backupSection` to the `Form` in `body`, between `storageSection` and `notificationsSection`:

```swift
        Form {
            listeningSection
            omiSection
            transcriptionSection
            storageSection
            backupSection
            notificationsSection
            aboutSection
        }
```

Add the new section builder (e.g. after `storageSection`):

```swift
    /// Backup & Restore (design 2026-07-07). iCloud controls only this phase; the "additional
    /// backup providers" dropdown lands with the WebDAV phase (YAGNI — no empty dropdown now).
    private var backupSection: some View {
        Section("Backup & Restore") {
            Toggle("Back up transcripts to iCloud", isOn: $iCloudBackupEnabled)
                .onChange(of: iCloudBackupEnabled) { _, value in
                    model.settings.iCloudBackupEnabled = value
                }
            Text("Transcripts (not audio) are backed up to your iCloud so you don't lose them if you get a new phone. Your recordings stay on this device.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Status", value: iCloudStatus)

            Button("Back up now") {
                backupResult = "Backing up…"
                Task {
                    let n = await model.backupAllToICloud()
                    backupResult = "Backed up \(n) transcript\(n == 1 ? "" : "s")."
                    iCloudHasBackups = await model.iCloudHasBackups()
                }
            }
            if let backupResult {
                Text(backupResult).font(.caption).foregroundStyle(.secondary)
            }

            Button("Restore from iCloud") {
                restoreResult = "Restoring…"
                Task {
                    let n = await model.restoreFromICloud()
                    restoreResult = n > 0
                        ? "Restored \(n) transcript\(n == 1 ? "" : "s")."
                        : "Nothing new to restore."
                }
            }
            if let restoreResult {
                Text(restoreResult).font(.caption).foregroundStyle(.secondary)
            }

            // Shown only when the container actually holds transcripts — so "stop backing up"
            // (the toggle, non-destructive) can never be confused with "delete my backup".
            if iCloudHasBackups {
                Button("Remove iCloud backup", role: .destructive) { showRemoveBackupConfirm = true }
                    .confirmationDialog("Remove all transcripts from iCloud?",
                                        isPresented: $showRemoveBackupConfirm) {
                        Button("Remove", role: .destructive) {
                            Task {
                                await model.removeICloudBackup()
                                iCloudHasBackups = false
                                backupResult = "Removed iCloud backup."
                            }
                        }
                    } message: {
                        Text("This deletes your backed-up transcripts from iCloud. Transcripts on this device are not affected.")
                    }
                Text("Turning off the toggle just stops backing up — your existing iCloud copies stay. Use this to remove them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
```

- [ ] **Step 4: Delete `SyncDestination.swift` and confirm no dangling references**

```bash
git rm Sotto/Files/SyncDestination.swift
grep -rn "SyncDestinationStore\|SegmentExporter" Sotto SottoTests
```
Expected: the `grep` prints **nothing** (every reference rewired/removed).

- [ ] **Step 5: Regenerate, build, and run the full suite**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, zero new warnings.

- [ ] **Step 6: Commit**

```bash
git add Sotto/App/SettingsView.swift
git rm Sotto/Files/SyncDestination.swift
git commit -m "feat: Settings Backup & Restore section; remove dead folder-picker sync"
```

---

## Task 9: Entitlements + provisioning round-trip + manual verification

The iCloud container is a capabilities change requiring a signing round-trip. **Steps 3–4 need the signing account (Connor) and CANNOT be done headless.** Everything shipped in Tasks 1–8 already degrades gracefully without the entitlement (the container resolver returns nil → all ops no-op, all unit tests inject roots), so the app builds and runs before this task — this task lights up the real backup.

**Files:**
- Create: `Sotto/Sotto.entitlements`
- Modify: `project.yml`

- [ ] **Step 1: Create `Sotto/Sotto.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.decanlys.Sotto</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.decanlys.Sotto</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudDocuments</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Wire `CODE_SIGN_ENTITLEMENTS` in `project.yml`**

Under `targets.Sotto:` (a sibling of `sources:`/`dependencies:`/`info:`), add:

```yaml
    entitlements:
      path: Sotto/Sotto.entitlements
```

Then regenerate: `xcodegen generate`

Confirm the build setting landed:
Run: `grep -n "CODE_SIGN_ENTITLEMENTS" Sotto.xcodeproj/project.pbxproj`
Expected: at least one line referencing `Sotto/Sotto.entitlements`.

Do **NOT** add `NSUbiquitousContainers` to `Sotto/Info.plist` — keeping the container out of document scope is deliberate (backup stays invisible in Files.app).

- [ ] **Step 3: Enable the iCloud capability (requires Connor + signing account — not headless)**

In Xcode, with the `Sotto` target's **Signing & Capabilities** tab, using the team that owns the `com.decanlys.Sotto` App ID:
1. **+ Capability → iCloud.**
2. Check **iCloud Documents.**
3. Under Containers, add/create **`iCloud.com.decanlys.Sotto`** (Xcode's automatic signing can create the container and enable the capability on the App ID).
4. Let the provisioning profile regenerate.

- [ ] **Step 4: Build to a real device and manually verify the round-trip**

`⚠️ Requires a signed-in iCloud account on the device.` On the simulator the container often does not resolve — do the real-backup checks on hardware.

- [ ] **Verify: outbound backup.** Enable "Back up transcripts to iCloud", record a segment, let it transcribe. Confirm the `.md` lands in the ubiquity container (`Console.app`/Files debugging or a second-device check below). No `.m4a` should ever appear.
- [ ] **Verify: backfill.** Tap "Back up now" → "Backed up N transcript(s)." with N matching the local transcript count.
- [ ] **Verify: restore on a second device / fresh install.** Sign into the same Apple ID on another device (or delete + reinstall). On launch, transcripts hydrate into history within a few seconds; the "Restored N transcripts from iCloud" status line shows; restored conversations show **no audio**. Tapping "Restore from iCloud" again → "Nothing new to restore."
- [ ] **Verify: disable is non-destructive.** Toggle off → new segments stop mirroring, existing iCloud copies remain (status still "Backed up to iCloud", "Remove iCloud backup" still offered).
- [ ] **Verify: explicit purge.** "Remove iCloud backup" → confirm → the `Transcripts/` prefix is gone; local `Documents/Sotto` is untouched; the action disappears (`iCloudHasBackups` false).
- [ ] **Verify: signed out.** With iCloud signed out, status reads "iCloud unavailable — sign in to iCloud in Settings" and no op errors.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Sotto.entitlements project.yml
git commit -m "feat: iCloud container entitlements + provisioning for transcript backup"
```

---

## Self-Review

**1. Spec coverage** (against `2026-07-07-backup-restore-icloud-design.md`):

| Design section | Covered by |
|---|---|
| §3 sink protocol + registry + fan-out (5 sites) | Tasks 3, 5, 7 |
| §3 no `move` verb (merge/rename are upsert/remove) | Task 3 doc + Task 7 site 4 |
| §4 `ICloudSyncSink` (container, Transcripts/ prefix, .md only, nil no-op, testable seam) | Task 4 |
| §4 `backupAll` backfill | Task 4 |
| §5 `ICloudRestore` (additive, evicted placeholders, never-overwrite, `_day.json` rebuild, hasAudio=false, bootstrap safety) | Task 6 |
| §5 launch-time restore + status line | Task 7 |
| §6 Backup & Restore Settings (toggle default-on, status, Back up now, Restore, Remove iCloud backup) | Task 8 |
| §6 `SettingsStore.iCloudBackupEnabled` | Task 1 |
| §7 entitlements + project.yml + provisioning; no `NSUbiquitousContainers` | Task 9 |
| §8 folder-picker teardown (SyncDestination.swift, SettingsView, AppModel, stale keys, rename as 5th site) | Tasks 7, 8 |
| §9 testing strategy (sink, restore, registry toggle, fan-out) | Tasks 4, 5, 6, 7 |
| §10 forward-compat seam (registry appends future sinks) | Task 5 comment |

The WebDAV phase (`2026-07-07-webdav-backup-requirements.md`) is explicitly out of scope — it is a pre-design requirements capture awaiting its own brainstorm.

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N"/"write tests for the above" — every code and test step carries complete content.

**3. Type consistency:** `TranscriptSyncSink.upsert(_:)`/`remove(day:basename:)`, `SyncSegment(day:basename:markdown:audio:)` + `init(m4aURL:)`, `SyncSinkRegistry.activeSinks/upsert/remove/testSinks`, `ICloudSyncSink.init(resolveContainer:)`/`containerIdentifier`/`backupAll(localRoot:)`/`removeAllBackups()`/`hasBackups()`, `ICloudRestore.run(localRoot:containerRoot:dayIndex:)`, `DayIndexStore.rebuildAndPersist(dayDirectory:)`/`index(forDay:)`, `AppModel.backupAllToICloud()`/`restoreFromICloud()`/`removeICloudBackup()`/`iCloudHasBackups()`/`iCloudAvailable()`/`restoreStatus`/`applyRestoreResult(_:)` — names match across every task that references them.
