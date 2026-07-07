# M11 — Cloud Sync Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick any Files-app folder (iCloud Drive, Google Drive, OpenCloud, …) as a sync destination; Sotto clones each finalized conversation (transcript `.md`, plus audio `.m4a` when retention keeps it) into that folder, mirroring the local `<yyyy-MM-dd>/` layout, with an "Export all now" backfill.

**Architecture (user-decided 2026-07-05):** the local `Documents/Sotto` store stays canonical — the recording pipeline is NEVER pointed at a file-provider URL (streaming CAF writes while locked + file protection don't survive provider-backed filesystems). Instead: SwiftUI `.fileImporter(allowedContentTypes: [.folder])` yields a security-scoped folder URL; `SyncDestinationStore` persists it as a bookmark in UserDefaults and re-resolves it per use; `SegmentExporter` copies files under `NSFileCoordinator` (required for file-provider correctness); AppModel's existing queue transition handler (`AppModel.swift:533`, the single choke point every finalized job passes through) triggers a best-effort export after retention has run, so what lands in the cloud mirrors what the app actually keeps — plus the transcript, always.

**Tech Stack:** SwiftUI `.fileImporter`, security-scoped URL bookmarks, `NSFileCoordinator`, Swift Testing.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. New files → `xcodegen generate`. Zero Swift warnings (appintents exempt). Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Export is BEST-EFFORT: a failed/slow copy must never fail a transcription job, block the queue's drain, delay the transition handler's index/retention work, or run on the main actor (use `Task.detached`).
- Local-store rules unchanged: exporter reads the local store, never writes into it; `_day.json` and `.caf` files are internal and never exported.
- The destination is resolved FRESH per export (mirrors the queue's per-job `serviceProvider` pattern) so changing/clearing the folder applies immediately without reconstructing anything.
- Security-scope discipline: every use of a resolved destination URL is wrapped in `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`; a `false` return from start is tolerated (plain URLs in tests aren't scoped), never treated as failure.
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Files/SyncDestination.swift      ← SyncDestinationStore (bookmark persistence) + SegmentExporter (coordinated copies) (new)
Sotto/App/AppModel.swift               ← export hook in transition handler + exportAllToSyncDestination() (modify)
Sotto/App/SettingsView.swift           ← Storage section: folder picker row, export-all, stop-syncing (modify)
SottoTests/SyncDestinationTests.swift  ← bookmark round-trip + exporter layout/overwrite/skip tests (new)
```

---

### Task 1: `SyncDestinationStore` — bookmark persistence

**Files:**
- Create: `Sotto/Files/SyncDestination.swift`
- Test: `SottoTests/SyncDestinationTests.swift` (new)

**Interfaces:**
- Consumes: nothing app-specific (Foundation only).
- Produces (Tasks 2–4 consume exactly these):

```swift
struct SyncDestinationStore: Sendable {
    init(defaults: UserDefaults = .standard)
    var isConfigured: Bool { get }
    var displayName: String? { get }          // folder's lastPathComponent, for Settings UI
    func save(url: URL) throws               // bookmark the picked folder
    func clear()
    func resolve() -> URL?                    // nil when unset or unresolvable
}
```

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/SyncDestinationTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct SyncDestinationTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDestinationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sync-destination-tests-\(UUID().uuidString)")!
    }

    @Test func storeRoundTripsAFolderBookmark() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        #expect(store.isConfigured == false)
        #expect(store.resolve() == nil)
        #expect(store.displayName == nil)

        let folder = tempDir()
        try store.save(url: folder)
        #expect(store.isConfigured == true)
        #expect(store.displayName == folder.lastPathComponent)
        #expect(store.resolve()?.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func clearRemovesTheDestination() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        try store.save(url: tempDir())
        store.clear()
        #expect(store.isConfigured == false)
        #expect(store.resolve() == nil)
        #expect(store.displayName == nil)
    }

    @Test func resolveReturnsNilWhenTheFolderIsGone() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        let folder = tempDir()
        try store.save(url: folder)
        try FileManager.default.removeItem(at: folder)
        #expect(store.resolve() == nil)   // deleted folder → unresolvable, not a crash
    }
}
```

- [ ] **Step 2: Register the new test file and run to verify failure**

Run: `xcodegen generate` then
`xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncDestinationTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'SyncDestinationStore' in scope`.

- [ ] **Step 3: Implement the store**

Create `Sotto/Files/SyncDestination.swift`:

```swift
import Foundation

/// M11 cloud sync: persists the user-picked export folder as a security-scoped bookmark.
/// Bookmarks — not raw paths — because iOS file-provider URLs (iCloud Drive, Google Drive,
/// OpenCloud, …) are only re-openable across launches via bookmark resolution.
struct SyncDestinationStore: Sendable {
    // UserDefaults isn't marked Sendable on this SDK, but it is documented as internally
    // thread-safe — nonisolated(unsafe) matches the SettingsStore precedent.
    nonisolated(unsafe) let defaults: UserDefaults
    static let bookmarkKey = "syncDestinationBookmark"
    static let displayNameKey = "syncDestinationDisplayName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isConfigured: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    var displayName: String? { defaults.string(forKey: Self.displayNameKey) }

    /// `url` comes from `.fileImporter` (already security-scope-granted). The access
    /// start/stop pair is required for bookmark creation on provider-backed URLs; a `false`
    /// start (plain file URLs, e.g. in tests) is fine — creation still works for those.
    func save(url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData()
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(url.lastPathComponent, forKey: Self.displayNameKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.displayNameKey)
    }

    /// Resolves the stored bookmark. Stale bookmarks (provider moved the folder) are
    /// refreshed in place per Apple's documented contract. Returns nil when unset or the
    /// folder is gone/unreachable — callers treat that as "sync off for now", never an error.
    func resolve() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let refreshed = try? url.bookmarkData() {
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncDestinationTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/SyncDestination.swift SottoTests/SyncDestinationTests.swift Sotto.xcodeproj
git commit -m "feat: sync destination bookmark store

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `SegmentExporter` — coordinated copies mirroring the store layout

**Files:**
- Modify: `Sotto/Files/SyncDestination.swift` (append below `SyncDestinationStore`)
- Test: `SottoTests/SyncDestinationTests.swift` (append tests)

**Interfaces:**
- Consumes: local store layout `<root>/<yyyy-MM-dd>/<HH-mm-ss>.m4a` with sibling `.md` (see `SegmentStore.pathsForSegment` / `TranscriptMarkdownWriter.write`).
- Produces (Task 3 consumes exactly these):

```swift
enum SegmentExporter {
    struct Exported: Equatable { let markdown: Bool; let audio: Bool }
    @discardableResult
    static func export(m4aURL: URL, to destination: URL) -> Exported
    @discardableResult
    static func exportAll(root: URL, to destination: URL) -> Int   // files copied
}
```

- [ ] **Step 1: Write the failing tests**

Append to `SyncDestinationTests` in `SottoTests/SyncDestinationTests.swift`:

```swift
    /// Builds `<root>/<day>/<name>.md [+ .m4a]` and returns the m4a URL (even if not created).
    private func makeSegment(
        root: URL, day: String, name: String, md: String? = "transcript", m4a: Bool = true
    ) throws -> URL {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4aURL = dayDir.appendingPathComponent("\(name).m4a")
        if m4a { try Data([0x01]).write(to: m4aURL) }
        if let md {
            try md.write(
                to: dayDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        return m4aURL
    }

    @Test func exportMirrorsTheDayLayout() throws {
        let root = tempDir(), dest = tempDir()
        let m4a = try makeSegment(root: root, day: "2026-07-05", name: "09-15-00")

        let exported = SegmentExporter.export(m4aURL: m4a, to: dest)

        #expect(exported == SegmentExporter.Exported(markdown: true, audio: true))
        let day = dest.appendingPathComponent("2026-07-05")
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("09-15-00.md").path))
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("09-15-00.m4a").path))
    }

    @Test func exportCopiesTranscriptOnlyWhenAudioWasDeleted() throws {
        // deleteAfterTranscription retention removes the m4a before export runs — the
        // transcript must still make it to the cloud, reported honestly.
        let root = tempDir(), dest = tempDir()
        let m4a = try makeSegment(root: root, day: "2026-07-05", name: "10-00-00", m4a: false)

        let exported = SegmentExporter.export(m4aURL: m4a, to: dest)

        #expect(exported == SegmentExporter.Exported(markdown: true, audio: false))
        let day = dest.appendingPathComponent("2026-07-05")
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("10-00-00.md").path))
        #expect(!FileManager.default.fileExists(atPath: day.appendingPathComponent("10-00-00.m4a").path))
    }

    @Test func reExportOverwritesTheOldTranscript() throws {
        // Re-transcription rewrites the local .md; a second export must replace, not fail on,
        // the existing destination copy.
        let root = tempDir(), dest = tempDir()
        let m4a = try makeSegment(root: root, day: "2026-07-05", name: "11-00-00", md: "v1")
        SegmentExporter.export(m4aURL: m4a, to: dest)
        try "v2".write(
            to: m4a.deletingPathExtension().appendingPathExtension("md"),
            atomically: true, encoding: .utf8)

        let exported = SegmentExporter.export(m4aURL: m4a, to: dest)

        #expect(exported.markdown == true)
        let copied = dest.appendingPathComponent("2026-07-05/11-00-00.md")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "v2")
    }

    @Test func exportAllSweepsEveryDayAndSkipsInternalFiles() throws {
        let root = tempDir(), dest = tempDir()
        _ = try makeSegment(root: root, day: "2026-07-04", name: "08-00-00")               // md + m4a
        _ = try makeSegment(root: root, day: "2026-07-05", name: "09-00-00", m4a: false)   // md only
        // Internal files that must NOT be exported:
        try Data([1]).write(to: root.appendingPathComponent("2026-07-04/_day.json"))
        try Data([1]).write(to: root.appendingPathComponent("2026-07-04/08-30-00.caf"))

        let copied = SegmentExporter.exportAll(root: root, to: dest)

        #expect(copied == 3)   // 2×md + 1×m4a
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-04/08-00-00.m4a").path))
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-05/09-00-00.md").path))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-04/_day.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-04/08-30-00.caf").path))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncDestinationTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'SegmentExporter' in scope`.

- [ ] **Step 3: Implement the exporter**

Append to `Sotto/Files/SyncDestination.swift`:

```swift
/// M11 cloud sync: best-effort mirror of finalized conversations into the sync destination,
/// preserving the local store layout — `<destination>/<yyyy-MM-dd>/<HH-mm-ss>.md` plus the
/// `.m4a` when it still exists (export runs AFTER retention, so the cloud mirrors what the
/// app actually keeps; the transcript always ships). Every write goes through
/// NSFileCoordinator — file-provider backends require coordinated access for correctness.
/// All failures degrade to "didn't copy" (reflected in the return value + best-effort
/// retry via the next export/exportAll); nothing here ever throws into a caller.
enum SegmentExporter {
    struct Exported: Equatable {
        let markdown: Bool
        let audio: Bool
    }

    @discardableResult
    static func export(m4aURL: URL, to destination: URL) -> Exported {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        let dayName = m4aURL.deletingLastPathComponent().lastPathComponent
        let dayDir = destination.appendingPathComponent(dayName, isDirectory: true)
        let mdURL = m4aURL.deletingPathExtension().appendingPathExtension("md")

        var markdown = false
        var audio = false
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            markdown = copyReplacing(from: mdURL, into: dir)
            audio = copyReplacing(from: m4aURL, into: dir)
        }
        return Exported(markdown: markdown, audio: audio)
    }

    /// Settings "Export all now" backfill: mirrors every `.md`/`.m4a` under `root`'s day
    /// directories. `_day.json` (internal index) and `.caf` (pre-transcode scratch) never
    /// leave the device. Returns the number of files copied.
    @discardableResult
    static func exportAll(root: URL, to destination: URL) -> Int {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        guard let days = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }

        var copied = 0
        let coordinator = NSFileCoordinator()
        for day in days {
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: day, includingPropertiesForKeys: nil) else { continue }
            let exportable = files.filter { ["md", "m4a"].contains($0.pathExtension) }
            guard !exportable.isEmpty else { continue }
            let targetDay = destination.appendingPathComponent(day.lastPathComponent, isDirectory: true)
            var coordinationError: NSError?
            coordinator.coordinate(writingItemAt: targetDay, options: [], error: &coordinationError) { dir in
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for file in exportable where copyReplacing(from: file, into: dir) {
                    copied += 1
                }
            }
        }
        return copied
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

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncDestinationTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/SyncDestination.swift SottoTests/SyncDestinationTests.swift
git commit -m "feat: segment exporter with coordinated copies and export-all backfill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: AppModel wiring — export on completion + backfill API

**Files:**
- Modify: `Sotto/App/AppModel.swift` (transition handler at ~line 533; new `exportAllToSyncDestination()` near `storageUsage()`)

**Interfaces:**
- Consumes: `SyncDestinationStore().resolve() -> URL?` (Task 1); `SegmentExporter.export(m4aURL:to:)`, `SegmentExporter.exportAll(root:to:)` (Task 2); existing `JobTransition` (`job.state`, `job.m4aURL`) and `segmentRoot`.
- Produces (Task 4 consumes): `AppModel.exportAllToSyncDestination() async -> Int?` — nil when no destination is configured/resolvable, else the number of files copied.

- [ ] **Step 1: Hook export into the transition handler**

In `Sotto/App/AppModel.swift`, inside `setTransitionHandler`'s `Task { ... }` (~line 533), the block currently ends with:

```swift
                    if transition.job.state == .done,
                       RetentionEnforcer.applyAfterTranscription(
                           m4aURL: transition.job.m4aURL, retention: settings.audioRetention) {
                        await dayIndexStore.setAudioRemoved(m4aURL: transition.job.m4aURL)
                    }
```

Directly AFTER that `if` block (still inside the same `Task`), add:

```swift
                    // M11 cloud sync: after retention has decided what stays, mirror the
                    // finalized conversation into the sync folder. AFTER retention on
                    // purpose — the cloud copy reflects what the app keeps (the transcript
                    // always ships; the audio only when retained). Destination resolved
                    // fresh per transition (same pattern as the per-job serviceProvider) so
                    // changing/clearing the folder applies immediately. Detached: provider
                    // I/O (iCloud/Drive/OpenCloud) can stall for seconds and must never
                    // block this handler's index work or ride the main actor.
                    if transition.job.state == .done,
                       let syncDestination = SyncDestinationStore().resolve() {
                        let m4aURL = transition.job.m4aURL
                        Task.detached(priority: .utility) {
                            SegmentExporter.export(m4aURL: m4aURL, to: syncDestination)
                        }
                    }
```

- [ ] **Step 2: Add the backfill API**

Still in `Sotto/App/AppModel.swift`, directly after the `storageUsage()` function (~line 315), add:

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

- [ ] **Step 3: Build + full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, zero new warnings (watch for Swift 6 sendability warnings on the detached closures — `URL` and the enum's static funcs are Sendable, so there should be none).

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/AppModel.swift
git commit -m "feat: export finalized conversations to the sync destination

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Settings UI — pick, show, backfill, stop

**Files:**
- Modify: `Sotto/App/SettingsView.swift` (imports, state, `.task` load, `storageSection`)

**Interfaces:**
- Consumes: `SyncDestinationStore` (`isConfigured`, `displayName`, `save(url:)`, `clear()`) from Task 1; `AppModel.exportAllToSyncDestination() async -> Int?` from Task 3.
- Produces: UI only.

- [ ] **Step 1: Add import, state, and load**

In `Sotto/App/SettingsView.swift`:

Add to the imports (`UTType.folder` lives there):

```swift
import UniformTypeIdentifiers
```

Add to the `@State` block (below `notificationStatus`):

```swift
    @State private var showSyncFolderPicker = false
    @State private var syncFolderName: String?
    @State private var exportAllResult: String?
```

Add inside the `.task` block (after `usage = model.storageUsage()`):

```swift
            syncFolderName = SyncDestinationStore().displayName
```

- [ ] **Step 2: Extend `storageSection`**

Replace the `storageSection` computed property (currently lines 119–137) with:

```swift
    private var storageSection: some View {
        Section("Storage") {
            Picker("Keep audio", selection: $retention) {
                Text("Delete after transcription").tag(AudioRetention.deleteAfterTranscription)
                Text("Keep 7 days").tag(AudioRetention.keepSevenDays)
                Text("Keep forever").tag(AudioRetention.keepForever)
            }
            .onChange(of: retention) { _, value in model.settings.audioRetention = value }
            if let usage {
                // LabeledContent's `value:` is a plain String (not a LocalizedStringKey), so
                // the `Text`-style "\(_, format:)" interpolation doesn't resolve here
                // ("extra argument 'format' in call") — format via `.formatted(_:)` instead.
                LabeledContent("Audio", value: usage.audioMB.formatted(.number.precision(.fractionLength(1))) + " MB")
                LabeledContent("Transcripts", value: usage.transcriptKB.formatted(.number.precision(.fractionLength(0))) + " KB")
            }
            Text("Your recordings live in Files ▸ On My iPhone ▸ Sotto.")
                .font(.caption).foregroundStyle(.secondary)

            // M11 cloud sync: clone finalized conversations into any Files-provider folder.
            if let syncFolderName {
                LabeledContent("Cloud sync folder", value: syncFolderName)
                Button("Export all now") {
                    exportAllResult = "Exporting…"
                    Task {
                        let copied = await model.exportAllToSyncDestination()
                        exportAllResult = copied.map { "Copied \($0) file(s)." }
                            ?? "Folder unavailable — pick it again."
                    }
                }
                if let exportAllResult {
                    Text(exportAllResult).font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop syncing", role: .destructive) {
                    SyncDestinationStore().clear()
                    self.syncFolderName = nil
                    exportAllResult = nil
                }
            } else {
                Button("Set cloud sync folder…") { showSyncFolderPicker = true }
                Text("New conversations are copied there after transcription — works with iCloud Drive, Google Drive, OpenCloud, and any Files provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
```

Then attach the picker to the `Form` in `body` (NOT to the `Section` — view modifiers on `Section` inside a `Form` don't reliably apply). In `body`, after the existing `.navigationTitle("Settings")` line, add:

```swift
        .fileImporter(isPresented: $showSyncFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try SyncDestinationStore().save(url: url)
                syncFolderName = SyncDestinationStore().displayName
            } catch {
                exportAllResult = "Couldn't save that folder — try picking it again."
            }
        }
```

Notes for the implementer:
- The retention Picker / usage rows / Files caption are the existing code verbatim — only the cloud-sync block and the `.fileImporter` modifier are new.
- `.fileImporter` with `[.folder]` grants a security-scoped folder URL; `SyncDestinationStore.save` handles the access-scope dance internally.

- [ ] **Step 3: Build + full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, zero new warnings.

- [ ] **Step 4: Manual verification in the simulator**

1. Settings → Storage → "Set cloud sync folder…" opens the Files picker; pick a folder in On My iPhone (the simulator has no cloud providers — the mechanism is identical).
2. The row now shows the folder name; "Export all now" reports `Copied N file(s).` and the files appear in the Files app under that folder, mirroring `<yyyy-MM-dd>/` day directories, with no `_day.json`.
3. Record a short segment, let it transcribe: its `.md` (and `.m4a` under keep retention) appears in the sync folder without further interaction.
4. "Stop syncing" reverts the section to the picker button; new segments no longer export.
5. Kill + relaunch: the folder name persists (bookmark round-trip through a real launch).

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/SettingsView.swift
git commit -m "feat: cloud sync folder picker with export-all in Settings storage section

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
