# Sotto Backup & Restore Rework — iCloud Phase (Design)

> **Status:** design, awaiting review. **Date:** 2026-07-07.
> **Scope of this doc:** the iCloud backup + restore phase, the removal of the old
> folder-picker sync, and the extensible sink architecture that WebDAV (next phase) and
> Google Drive (future) will slot into. WebDAV and Google Drive get their own design docs.

## 1. Context & motivation

Sotto previously let the user pick any Files-app folder (iCloud Drive, Google Drive,
OneDrive, OpenCloud) as a sync destination via `.fileImporter(allowedContentTypes: [.folder])`.
That approach is **fully implemented today** (`Sotto/Files/SyncDestination.swift`:
`SyncDestinationStore` + `SegmentExporter`, wired through four `AppModel` choke points) — but it
is a dead end for our actual targets.

**Research finding (why the folder picker cannot work for us):** iOS only grants
*folder-destination* selection for providers whose File Provider extension opts into it. In
practice that's **iCloud Drive, on-device local storage, and a handful of apps that explicitly
support it** (e.g. Working Copy, Secure ShellFish). **Mainstream clouds (Google Drive, OneDrive,
Dropbox) and OpenCloud grey out** in the folder picker — it's their File Provider implementation
choice, and Apple's File Provider framework rewrite did **not** change it. So the picker can
never target the destinations we care about. This is settled; do not re-attempt the picker
approach.

We replace it with two paths that don't depend on the picker:

1. **iCloud transcript backup (this phase, default-on for all users)** — so a user with a new,
   lost, or wiped phone doesn't lose their transcripts. The app's sandbox `Documents/Sotto`
   does **not** migrate to a new device on its own (only via a full encrypted device backup);
   an app-owned iCloud **ubiquity container** survives independently, tied to the Apple ID.
2. **WebDAV connector (next phase, opt-in, self-hosters)** — a direct WebDAV client for a
   user-configured server (e.g. OpenCloud), with full create/modify/delete/rename-move. Designed
   for here but built later.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Source of truth | **Local `Documents/Sotto` stays canonical for everything** (transcripts, audio, `_day.json`) | Keeps each conversation a self-contained day-directory; keeps reads fast; keeps iCloud optional; keeps locked-while-recording audio writes on the local filesystem where file protection is known to work. |
| iCloud role | **Backup vault + restore**, not source of truth | The system-managed "container as truth" (iA Writer / Obsidian pattern) would split a conversation across two roots and break the iCloud-optional story. Rejected. |
| iCloud contents | **Transcripts (`.md`) only — never audio** | Quota + privacy. Audio backup, if ever, is a WebDAV-only opt-in. |
| Backup semantics | **Mirror exactly**, but **deletes are event-driven only** | Delete/merge propagate to the container so it matches the current library. Deletes are emitted only by explicit user actions, **never** by diffing local against the container — so an empty local store (fresh install) produces zero delete events and restore fills it safely. |
| Restore | **Additive, launch-time, single active device** | Copy container transcripts missing from local into `Documents/Sotto`, rebuild affected `_day.json`. No conflict resolution — this is device migration, one phone at a time, last-write-from-the-active-device wins. |
| WebDAV auth (next phase) | **Username + app password (Basic auth)**, Keychain-stored | Simplest, reliable, supports DELETE/MOVE; matches OpenCloud app-password model. |
| Settings shape | New **Backup & Restore** section: iCloud controls + a reserved dropdown for additional backup providers | WebDAV is the first "additional type"; Google Drive a future slot. |
| Sequencing | **iCloud first**, WebDAV later, Google Drive after | Each phase ships independently behind the same sink seam. |

## 3. Architecture — the sink seam + provider registry

The load-bearing realization: the four filesystem-affecting events already funnel through a
single abstraction today (`SegmentExporter`), pointed at a local folder URL. We generalize that
seam so multiple backup providers can consume the same events concurrently — because on the
user's own phone, a finalized transcript must fan out to **both** iCloud *and* (later) WebDAV.

### The protocol

```swift
/// A destination that mirrors finalized transcripts out of the canonical local store.
/// All methods are best-effort and must never throw into the caller: a slow/failed backup
/// can never fail a transcription job, block the queue, or ride the main actor.
protocol TranscriptSyncSink: Sendable {
    /// Mirror a finalized conversation. `markdown` is always present; `audio` is present only
    /// when retention kept it. Sinks that don't back up audio (iCloud) ignore it.
    func upsert(_ segment: SyncSegment) async
    /// Propagate a local deletion or a merge-consumed part.
    func remove(day: String, basename: String) async
}

struct SyncSegment: Sendable {
    let day: String        // "2026-07-07" (day-directory name)
    let basename: String   // "09-15-00"  (filename stem, shared by .md/.m4a)
    let markdown: URL      // local source .md
    let audio: URL?        // local source .m4a; nil when retention deleted it
}
```

### The registry

```swift
enum SyncSinkRegistry {
    /// Assembles the active sinks from current settings. Resolved FRESH per event
    /// (mirrors the existing per-job serviceProvider pattern), so toggling a provider
    /// applies immediately with nothing to reconstruct.
    static func activeSinks(_ settings: SettingsStore) -> [TranscriptSyncSink] {
        var sinks: [TranscriptSyncSink] = []
        if settings.iCloudBackupEnabled { sinks.append(ICloudSyncSink()) }
        // Later phases append here: WebDAVSyncSink(config:), GoogleDriveSyncSink(...)
        return sinks
    }
}
```

### The fan-out at the four choke points

Each existing `SegmentExporter` call site in `AppModel` becomes a fan-out. Illustrative
(transcription-done handler, after retention has decided what stays):

```swift
let segment = SyncSegment(day: day, basename: basename, markdown: mdURL, audio: keptAudioURL)
for sink in SyncSinkRegistry.activeSinks(settings) {
    Task.detached(priority: .utility) { await sink.upsert(segment) }
}
```

The four sites and their event:

| AppModel site | Event | Sink call |
|---|---|---|
| transcription-done handler (after retention) | create/update | `upsert` |
| `regenerateNotes` | update | `upsert` |
| `mergeSegments` | merge = update earliest + remove parts | `upsert(earliest)` + `remove(part)` × N |
| `deleteSegment` | delete | `remove` |

**Why the protocol needs no `move` — permanently, not just this phase.** No Sotto feature performs
a filesystem-level rename/move:
- **Merge** writes into the earliest part's *existing* basename and deletes the others →
  `upsert(earliest) + remove(others)`.
- **Rename** (in-flight WIP, `specs/2026-07-07-rename-conversation-design.md`) rewrites the `title:`
  frontmatter and H1 *inside* the existing `.md`; the **filename never changes** → a plain `upsert`,
  exactly like `regenerateNotes`.

So the `upsert`/`remove` surface is complete. A `move` verb would be dead weight. (A future WebDAV
sink may still *choose* a server-side `MOVE` as an efficiency optimization, but it's never required
for correctness — a rename there is equally expressible as re-`PUT` same path.)

## 4. `ICloudSyncSink` — outbound backup

**File:** `Sotto/Files/ICloudSyncSink.swift` (new).

- **Container:** `FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.decanlys.Sotto")`.
  Transcripts are written under a private prefix — `<container>/Transcripts/<day>/<basename>.md` —
  and the container is **not** made document-scope-public, so the backup never appears in Files.app
  and can't be confused with the canonical store.
- **Signed out / iCloud unavailable:** the container URL is `nil` → every op is a silent no-op.
  This is the exact "sync off for now, never an error" degrade the old `resolve() == nil` used.
- **`upsert`:** coordinated (`NSFileCoordinator`) copy of the local `.md` into the container day
  directory, replacing any existing copy. **Audio is ignored.**
- **`remove`:** coordinated removal of `<container>/Transcripts/<day>/<basename>.md`.
- **Best-effort:** all failures degrade to "didn't back up"; nothing throws. Retried implicitly by
  the next event or by the manual "Back up now" backfill.
- **Testability:** `init(containerRoot: URL? = nil)` — `nil` resolves the real ubiquity container;
  tests inject a temp directory. This is the seam that makes the sink unit-testable without iCloud.

**Backfill ("Back up now" / first-enable):** `backupAll(localRoot:) -> Int` sweeps every
`<localRoot>/<day>/*.md` into the container (skipping `_day.json`, `.caf`, `.m4a`), returning the
count copied. Replaces the old `exportAllToSyncDestination()`.

## 5. `ICloudRestore` — inbound hydration

**File:** `Sotto/Files/ICloudRestore.swift` (new).

Backup is only half the job; restore is the half that saves the user on a new phone.

- **Trigger:** on launch (detached, after store setup) when iCloud backup is enabled, and on demand
  via a Settings "Restore from iCloud" button.
- **Operation (additive, idempotent):**
  1. Enumerate `<container>/Transcripts/<day>/<basename>.md`.
  2. For evicted placeholders (not-yet-downloaded on a fresh device), trigger download —
     coordinated read via `NSFileCoordinator` (which blocks until materialized) and/or
     `startDownloadingUbiquitousItem`. **Eviction handling is a required part of restore**, not an
     afterthought: on a brand-new phone every transcript starts as a placeholder.
  3. For each container `.md` whose local counterpart `<Documents/Sotto>/<day>/<basename>.md` is
     **missing**, coordinated-copy container → local. Never overwrite an existing local file
     (local is canonical).
  4. For each day directory that received files, call `DayIndexRebuilder.rebuild(dayDirectory:)`
     to regenerate `_day.json` from the restored `.md` frontmatter, so restored transcripts appear
     in history. Restored conversations have `hasAudio = false` (audio was never backed up).
- **Bootstrap safety (hard rule):** restore is purely additive and outbound deletes are
  event-driven only. An empty local store therefore produces **zero** delete events, so a fresh
  install can never wipe the backup before restoring from it.
- **UX:** silent on launch with a small status line ("Restored N transcripts from iCloud" when
  non-zero); explicit and reported when the user taps "Restore from iCloud".

## 6. Settings — Backup & Restore section

**File:** `Sotto/App/SettingsView.swift` (modify) — remove the folder-picker block (§8), add a new
**Backup & Restore** section.

**This phase ships iCloud controls only.** The "additional backup providers" dropdown is the
*target shape* the section is designed around, but it lands with the WebDAV phase — we don't ship
an empty dropdown (YAGNI). The section is structured so adding it is additive.

**Why a toggle at all (and default-on):** Sotto is an ambient conversation recorder — its
transcripts routinely capture other people who never consented to being uploaded anywhere. "Do
my transcripts leave this device?" is a genuine privacy decision, and the OS-level iCloud switch
is too coarse (it's all-or-nothing across every app). An in-app toggle is the fine-grained,
recorder-appropriate control. Default-on preserves the "don't lose your data on a new phone"
safety net for the majority who never open Settings. Cost is near-zero — one `Bool` + one
`SyncSinkRegistry` conditional, both already in the architecture.

iCloud subsection:
- **Toggle** "Back up transcripts to iCloud" — bound to `SettingsStore.iCloudBackupEnabled`,
  **default on**. Off is **non-destructive**: it stops the outbound sink and launch restore, but
  leaves existing iCloud copies in place (they're still the user's backup).
- **"Remove iCloud backup"** (destructive, confirmation-guarded, shown only when the container has
  transcripts) — for the user who wants their transcripts *gone* from iCloud, not just paused.
  Separate from the toggle so "stop backing up" can never silently delete a backup. Deletes the
  `Transcripts/` prefix from the container; does not touch local `Documents/Sotto`.
- **Status line** — "Backed up to iCloud" / "iCloud unavailable — sign in to iCloud in Settings"
  (derived from whether the ubiquity container resolves).
- **"Back up now"** — runs `backupAll`, reports "Backed up N transcript(s)."
- **"Restore from iCloud"** — runs `ICloudRestore`, reports "Restored N transcript(s)." / "Nothing
  new to restore."
- Copy: "Transcripts (not audio) are backed up to your iCloud so you don't lose them if you get a
  new phone. Your recordings stay on this device."

`SettingsStore` addition (in `RetentionPolicy.swift`, matching the existing accessor style):
```swift
var iCloudBackupEnabled: Bool {
    get { defaults.object(forKey: "iCloudBackupEnabled") == nil ? true : defaults.bool(forKey: "iCloudBackupEnabled") }
    nonmutating set { defaults.set(newValue, forKey: "iCloudBackupEnabled") }
}
```

## 7. Provisioning / entitlements round-trip

The iCloud container is a capabilities change requiring a signing round-trip — budget for it as a
human-in-the-loop step, not just code. There is **no entitlements file today**.

1. **Create `Sotto/Sotto.entitlements`:**
   ```xml
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.com.decanlys.Sotto</string></array>
   <key>com.apple.developer.ubiquity-container-identifiers</key>
   <array><string>iCloud.com.decanlys.Sotto</string></array>
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudDocuments</string></array>
   ```
2. **`project.yml`:** add to the `Sotto` target so xcodegen wires `CODE_SIGN_ENTITLEMENTS`:
   ```yaml
   entitlements:
     path: Sotto/Sotto.entitlements
   ```
3. **Apple Developer portal / Xcode signing:** enable the iCloud capability on the `com.decanlys.Sotto`
   App ID and create the `iCloud.com.decanlys.Sotto` container (Xcode's automatic signing can do
   both when the capability is added), then let the provisioning profile regenerate. **This step
   needs the signing account and cannot be done headless.**
4. **`xcodegen generate`**, then build to confirm the profile picks up the container.

Do **not** add `NSUbiquitousContainers` to Info.plist — keeping the container out of document
scope is deliberate (backup stays invisible in Files.app).

## 8. Removal scope — folder-picker teardown

- **`Sotto/Files/SyncDestination.swift`:** delete `SyncDestinationStore` (bookmark persistence)
  entirely. `SegmentExporter`'s coordinated copy/remove helpers are the reusable core — extract the
  generic "coordinated mirror into a destination root" logic for `ICloudSyncSink` to reuse, and
  delete the security-scoped-bookmark and folder-URL specifics. Net: this file is replaced by the
  sink files.
- **`SottoTests/SyncDestinationTests.swift`:** drop the bookmark round-trip tests; repurpose the
  layout/overwrite/skip-internal-files tests as `ICloudSyncSink` tests (same assertions, container
  root instead of a picked folder).
- **`Sotto/App/SettingsView.swift`:** remove the `.fileImporter` modifier, the three sync `@State`
  vars, the "Cloud sync folder" block, and the now-unused `import UniformTypeIdentifiers`.
- **`Sotto/App/AppModel.swift`:** rewire the four call sites from direct `SegmentExporter`/
  `SyncDestinationStore` calls to the `SyncSinkRegistry` fan-out; replace `exportAllToSyncDestination()`
  with iCloud backfill/restore entry points.
- Clear any stale `syncDestinationBookmark` / `syncDestinationDisplayName` UserDefaults keys on
  upgrade (best-effort, one line) so no dangling bookmark lingers.
- **Coordinate with the in-flight rename WIP:** `AppModel.renameSegment` (on the rename branch)
  adds a *fifth* mutation site whose step-3 mirror currently calls `SegmentExporter.export` — which
  this branch deletes. When both land, rewire that step to the `SyncSinkRegistry` fan-out exactly
  like the other four sites (it's an `upsert`). Whichever branch merges second owns this one-line
  reconciliation; flag it in that branch's plan.

## 9. Testing strategy

Test command:
`xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. New files → `xcodegen generate`. Zero
new warnings; Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.

- **`ICloudSyncSink`** (inject a temp `containerRoot`): `upsert` copies `.md` into
  `Transcripts/<day>/`, ignores audio; re-`upsert` overwrites; `remove` deletes; `backupAll` sweeps
  every day and skips `_day.json`/`.caf`/`.m4a`; nil container → all ops no-op.
- **`ICloudRestore`** (temp container + temp local root): restores `.md` missing locally and
  rebuilds `_day.json`; never overwrites an existing local `.md`; idempotent across two runs;
  empty local + populated container → full hydrate with correct history.
- **`SyncSinkRegistry`:** `iCloudBackupEnabled` toggles the iCloud sink in/out of the array.
- **Fan-out:** a fake `TranscriptSyncSink` records calls; assert each of the four AppModel events
  drives the expected `upsert`/`remove` on all active sinks.
- **Manual (simulator/device):** enable iCloud backup, record a segment, confirm the `.md` appears
  in the ubiquity container; "Back up now" backfills; on a second device / fresh install signed
  into the same Apple ID, launch restores transcripts into history with no audio.

## 10. Forward compatibility — what the seam reserves

- **WebDAV (next phase):** a `WebDAVSyncSink` conforms to `TranscriptSyncSink`; `activeSinks`
  appends it when configured. It adds true `MOVE`/`DELETE` HTTP verbs and an **optional audio**
  backup (its own server, so quota/privacy don't bind). Credentials (server URL + username + app
  password) in Keychain via the existing `KeychainStore` pattern. Its config form is the first
  entry in the Settings "additional backup providers" dropdown. Reconcile/catch-up for
  foreground-only `DELETE`/`MOVE` lag is a WebDAV follow-up, not launch scope.
- **Google Drive (future):** another sink conformer + dropdown entry; no core changes.

## 11. Out of scope / follow-ups

- WebDAV connector and its Settings UI (next design doc).
- Google Drive (future design doc).
- Multi-device *live* sync / conflict resolution — explicitly not a goal; this is device migration.
- A background reconcile pass to catch foreground-only WebDAV `DELETE`/`MOVE` lag (WebDAV follow-up).
- Backing up audio to iCloud (never — quota/privacy).

## 12. Decided in review

- **Pre-release confirmed:** no folder-picker install base. Teardown just clears the stale
  `syncDestinationBookmark` / `syncDestinationDisplayName` UserDefaults keys — **no data migration**.
- **iCloud backup is toggled, default on** (opt-out). Rationale in §6: it's an ambient recorder;
  transcripts leaving the device is a privacy decision deserving a finer control than the OS-wide
  iCloud switch.
- **Disable is non-destructive**; a separate confirmation-guarded "Remove iCloud backup" action
  handles explicit purge (§6).
- Restore runs **silently on launch** (additive/idempotent) in addition to the manual button.
- Container layout prefix `Transcripts/<day>/<basename>.md`; container **not** document-scope-public.
- Protocol surface is `upsert`/`remove` only — **and stays that way**. No feature does a filesystem
  rename/move: merge reuses the earliest basename, and the in-flight rename feature rewrites `.md`
  content in place without changing the filename (verified against its design), so rename is a plain
  `upsert`. No `move` verb is needed now or after rename lands. The rename branch's mirror step must
  be rewired to the sink fan-out on merge (see §8).
