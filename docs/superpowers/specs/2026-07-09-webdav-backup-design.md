# Sotto WebDAV Backup — Design

> **Status:** design, approved in brainstorm 2026-07-09. **Date:** 2026-07-09.
> **Supersedes** the open questions in `specs/2026-07-07-webdav-backup-requirements.md`
> (requirements there remain firm; every "decide in the brainstorm" item is decided here).
> **Prerequisites shipped:** iCloud phase (PR #2) — `TranscriptSyncSink` seam, `SyncSinkRegistry`
> fan-out, Backup & Restore Settings section; rename feature (PR #1) — mutation-event set stable.

## 1. Context

WebDAV is the first "additional backup provider" behind the sink seam: an opt-in, direct client
for a user-configured server (primary target: OpenCloud; works unchanged against Nextcloud or any
RFC 4918 server). The folder-picker approach is a settled dead end (see requirements doc — do not
re-litigate). Local `Documents/Sotto` stays canonical for everything; the server is a mirror.

### Corrections to the requirements doc (stress-test findings)

- **Endpoint example was wrong for OpenCloud.** `remote.php/dav/files/<user>/` is classic
  ownCloud/Nextcloud style; OpenCloud (oCIS fork) is spaces-based with legacy-compat routes we
  shouldn't guess at. Resolution: the user pastes the exact WebDAV collection URL — Sotto never
  derives any server's path scheme.
- **"Last-write-wins is probably fine" was a hand-wave.** The registry fires each event as an
  independent `Task.detached` and sinks are constructed fresh per event; for a network sink, a
  `DELETE` racing a slow `PUT` can resurrect a deleted file on the server. Fixed structurally by
  a shared FIFO executor (§3).
- **"Background PUT is reliable" needed nuance.** True only for background-configured
  `URLSession` upload tasks. Not needed: Sotto's audio background mode keeps the app alive while
  listening, and `DeepgramService` already uploads whole audio files via plain `URLSession` from
  the same lifecycle. Plain session matches precedent; the reconcile follow-up catches stragglers.
- **Test connection needs a verb the doc didn't list:** `PROPFIND` (Depth 0).

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Restore | **Backup + manual "Restore from server" button** — no automatic launch-time restore | Restore requires a configured server anyway, so the new-phone flow is configure → tap Restore. Additive/idempotent like iCloud restore, so the two compose in any order. |
| TLS | **HTTPS-only, system trust** | No challenge-delegate code, no ATS exceptions, no way to weaken transport by mistyping a URL. Self-signed/plain-HTTP fail "Test connection" with a clear message. |
| Base path | **User pastes the exact target collection URL; day folders created directly inside it** | No endpoint guessing, server-agnostic. Consequence: anything reading the server (restore, future reconcile) must treat only Sotto-shaped paths (`<yyyy-MM-dd>/<HH-mm-ss>.md\|.m4a`) as its domain and ignore foreign files. |
| Failure UX | **Status line in Settings** (executor's last outcome, in-memory) | Best-effort stays silent day-to-day; a rotated app password is diagnosable at a glance instead of failing invisibly for weeks. |
| Audio backup | **Per-server toggle, off by default; "Back up now" backfills when on** | Privacy-first default, no surprise multi-MB uploads; the sweep is the universal catch-up. |
| Execution model | **Fresh-per-event sink struct + one shared serial (FIFO) executor actor, no retry** | Fixes the ordering race with one mechanism; identical best-effort contract to iCloud; the sweep is the recovery path; durability is the reconcile follow-up's job. |
| Credentials | **URL + username + toggles in `SettingsStore` (UserDefaults); app password in Keychain** | Only the secret is secret — matches the Deepgram pattern (key in Keychain, settings in defaults). |
| Destructive remote wipe | **None** ("Forget this server" clears local config only) | iCloud's "Remove backup" exists because the ubiquity container is invisible to the user; WebDAV files sit on a server the user fully controls. |
| Reachability | **Event-driven ops honor `wifiOnlyUpload`** (checked at execution, fail-open like `WiFiMonitor`); **manual sweep/restore bypass it** | Manual actions are explicit user intent, "do it now". |
| Never synced | `_day.json`, `.caf` | Unchanged from requirements. |

## 3. Architecture

Four new components, all in `Sotto/Files/` (sync is a Files-layer concern):

### `WebDAVConfig` (in `WebDAVSyncSink.swift`)

```swift
/// Resolved FRESH per event like every registry input. nil unless the URL parses as https,
/// username is non-empty, and the Keychain holds the app password — so "configured" has
/// exactly one definition.
struct WebDAVConfig: Sendable {
    let baseURL: URL          // the exact collection backups land in
    let username: String
    let password: String      // app password, from Keychain key "webdavAppPassword"
    let audioEnabled: Bool

    static func load(settings: SettingsStore, keychain: KeychainStore = KeychainStore()) -> WebDAVConfig?
}
```

`SettingsStore` additions (in `Sotto/Files/RetentionPolicy.swift`, existing accessor style):
`webdavServerURL: String?`, `webdavUsername: String?`, `webdavEnabled: Bool` (default true once
configured), `webdavAudioBackup: Bool` (default false).

### `WebDAVTransport` + `WebDAVClient` (`WebDAVClient.swift`)

```swift
/// One-method transport seam (mirrors how NetworkMonitoring abstracts NWPathMonitor).
/// URLSession satisfies it; tests script it.
protocol WebDAVTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile url: URL) async throws -> (Data, URLResponse)
}
```

`WebDAVClient` builds requests — `put(fromFile:to:)` (upload-from-file so multi-MB `.m4a`
streams instead of loading into memory; used uniformly for `.md` too so there is one code
path), `delete(url:)`, `mkcol(url:)`, `propfind(url:depth:)`, `get(url:)` — each with a
preemptive `Authorization: Basic …` header (no challenge round-trips; HTTPS enforced at config
save, and `load` re-checks).

Error taxonomy, mapped to status copy by the executor:

```swift
enum WebDAVError: Error {
    case unauthorized          // 401 — "authentication failed"
    case notFound              // 404 — "folder not found"
    case insufficientStorage   // 507 — "server is full"
    case transport(URLError)   // unreachable / DNS / TLS
    case server(Int)           // anything else
}
```

### `WebDAVSyncSink` (`WebDAVSyncSink.swift`)

The `TranscriptSyncSink` conformer. Its `upsert`/`remove` do nothing but enqueue the op (with
the per-event config) onto the shared executor — so a settings change applies on the very next
event, unchanged from today's pattern. Registry grows one line:

```swift
if settings.webdavEnabled, let config = WebDAVConfig.load(settings: settings) {
    sinks.append(WebDAVSyncSink(config: config))
}
```

AppModel learns nothing new about WebDAV beyond thin entry points for the Settings screen
(`backupAllToWebDAV()`, `restoreFromWebDAV()`, `testWebDAVConnection()` — same shape as the
iCloud entry points).

### `WebDAVExecutor` (`WebDAVExecutor.swift`)

A single long-lived actor (`static let shared`; tests construct their own with an injected
transport and `NetworkMonitoring`). Responsibilities:

- **Strict FIFO:** one op completes before the next starts. This is the entire fix for the
  PUT-vs-DELETE resurrection race. (Enqueue order matches event order for human-separated
  events; the only same-instant multi-op event is merge, whose ops target *different* paths —
  `upsert(earliest)` + `remove(parts)` — so their relative order is inconsequential.)
- **Wi-Fi gate at execution time:** `wifiOnlyUpload && !isOnWiFi` → skip the op and record
  "Skipped — waiting for Wi-Fi". Never queue-forever; the sweep recovers.
- **`lastOutcome` status** the Settings line reads (in-memory, resets per launch — a
  diagnostic, not a ledger; success clears failure).
- **Sweep and restore** (§5, §6), serialized with outbound ops on the same actor so restore
  can never interleave with event-driven writes.

## 4. Operation semantics

- **`upsert`:** try `PUT <base>/<day>/<basename>.md` directly; on **409** (RFC 4918: parent
  collection missing) issue `MKCOL` for the day collection and retry the `PUT` once. No
  proactive `MKCOL`, no day-collection cache — the 409 path self-heals every time, including
  when the server folder is deleted externally mid-run. When `audioEnabled` and the segment
  carries audio, `PUT` the `.m4a` the same way. Success: 200/201/204.
- **`remove`:** `DELETE` both `<basename>.md` and `<basename>.m4a`, tolerating 404 on each
  (audio may never have been mirrored; file may already be gone — local is truth).
- **Empty day collections are left behind.** Cleaning them requires listing; that's
  reconcile-phase work.
- **Missing base** (`MKCOL` for the day also 409s): give up, record the failure (as built:
  the 409 surfaces as `conflict` → "folder could not be created" — folded from the final
  review; same give-up behavior, clearer copy than the originally-drafted `notFound`). We
  deliberately never auto-create the base collection — a typo'd URL should fail loudly in
  "Test connection", not silently create a junk folder.
- **No retries, URLSession default timeouts.** A failure records the outcome and drops the op
  (best-effort, same contract as iCloud). Implicit retry = next event touching the same file,
  or the sweep.

## 5. Settings UX

The Backup & Restore section gains a **"WebDAV server" `NavigationLink`** row below the iCloud
controls, showing `Not configured` / the host name. (This is the honest version of the reserved
"providers dropdown": with one provider a picker is ceremony; Google Drive later adds a second
row.) The detail screen — new file `Sotto/App/WebDAVSettingsView.swift`, since `SettingsView`
is 343 lines and a whole screen deserves its own file:

- **Fields:** Server URL (`https://…`, the exact collection backups land in), Username, App
  password (`SecureField`). Save persists URL + username to `SettingsStore`, password to
  Keychain — on submit, not per keystroke (the `persistKey()` lesson).
- **Validation at save:** URL must parse and be `https`; plain `http` is rejected there with
  copy explaining why (ATS would block it at request time anyway).
- **"Test connection":** `PROPFIND` Depth 0 against the saved URL. 207 → "Connected." 401 →
  "Server reached, but username or app password was rejected." 404 → "Folder not found — check
  the URL or create the folder on your server." Other → status code / transport error. Testing
  never gates saving — it's an affordance.
- **Toggles:** "Back up to this server" (`webdavEnabled` — pausing is non-destructive, like the
  iCloud toggle) and "Also back up audio" (`webdavAudioBackup`, default off).
- **Status line:** the executor's `lastOutcome` — "Last backup 14:32" / "Failed —
  authentication" / "Skipped — waiting for Wi-Fi".
- **"Back up now":** runs the sweep; reports counts.
- **"Restore from server":** §6; reports "Restored N transcript(s)." / "Nothing new to
  restore." / "Couldn't reach the server — check the connection settings." (folded from the
  final review: an unreachable/unauthorized server must be distinguishable from an empty one,
  the same honest-copy rule the iCloud phase applied to "Back up now").
- **"Forget this server":** clears the defaults keys + Keychain entry; removes nothing from the
  server, and says so.
- Copy keeps the privacy framing: transcripts (and audio, if enabled) go to *your own server*;
  `_day.json` and `.caf` never leave the device.

## 6. Sweep and restore

**Sweep (`backupAll`)** — first-configure backfill, audio-toggle backfill, and the universal
recovery path after any outage: walk every `<localRoot>/<day>/*.md` (skip `_day.json`/`.caf`),
`PUT` each; include `*.m4a` when the audio toggle is on. Returns transcript and audio counts
for the Settings report. Bypasses the Wi-Fi gate (explicit user intent).

**Restore ("Restore from server")** — additive, idempotent, transcripts only. Returns `nil`
when the base listing itself fails (unreachable/401/404 — surfaced as "couldn't reach"), `0`
when the server was reached and nothing was missing; per-day listing/GET failures
skip-and-continue, so a partial restore still returns its count:

1. `PROPFIND` Depth 1 on the base → collections matching the day shape `\d{4}-\d{2}-\d{2}`.
   Foreign files/folders are ignored — this is what makes "exact URL, no subfolder" safe.
   (Depth-infinity is avoided on purpose: servers commonly disable it.)
2. `PROPFIND` Depth 1 per day → `*.md` entries whose basename matches `HH-mm-ss`.
3. For each remote `.md` with no local counterpart: `GET` → write to
   `Documents/Sotto/<day>/<basename>.md`. **Never overwrite an existing local file** — local is
   canonical, same hard rule as iCloud restore.
4. `DayIndexRebuilder.rebuild` per day that received files; restored conversations get
   `hasAudio = false`.

Audio is not restored even when audio backup is on — same asymmetry as iCloud (restore is about
not losing transcripts; pulling audio libraries is a follow-up).

**Multistatus parsing** (`WebDAVMultistatus.swift`): a minimal `XMLParser`-based reader
extracting `href` + collection-flag per `<response>`, tolerant of namespace-prefix differences
(OpenCloud, Nextcloud, Apache mod_dav all prefix differently).

## 7. Testing strategy

Test command unchanged: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination
'platform=iOS Simulator,name=iPhone Air'` → `** TEST SUCCEEDED **`. New files → `xcodegen
generate`. Zero new warnings; Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.

Everything through a scripted `WebDAVTransport` fake that records requests (method, URL,
headers, body file) and returns canned responses — no network, no `URLProtocol` global state.

- **Client/executor:** upsert PUTs `.md` only by default, `.md` + `.m4a` with audio on;
  409 → MKCOL → retried PUT sequence; remove DELETEs both extensions tolerating 404; FIFO —
  enqueue upsert-then-remove for one path, assert request-log order; Wi-Fi gate skips and
  records without executing.
- **Config/registry:** missing any of URL/username/password → sink absent; non-https rejected;
  `webdavEnabled` off → sink absent (mirrors the `iCloudBackupEnabled` registry test).
- **Test connection:** 207 / 401 / 404 / transport error → the four distinct messages.
- **Restore:** multistatus fixtures shaped like real OpenCloud and Nextcloud responses → only
  missing files fetched; existing local files untouched; foreign entries ignored; `_day.json`
  rebuilt; second run is a no-op.
- **Sweep:** covers every day, skips `_day.json`/`.caf`, includes `.m4a` only when enabled.
- **Manual:** against the real OpenCloud server — configure, record, verify the file lands;
  rotate the app password and watch the status line report it; restore onto a wiped simulator.

No provisioning round-trip this phase: WebDAV is plain HTTPS networking — no entitlements, no
capabilities, no signing changes.

## 8. Out of scope / follow-ups

- **Reconcile / catch-up pass** (foreground diff local↔server, apply pending removals, prune
  empty day collections). This design leaves it a clean opening: it reuses the §6 PROPFIND
  walker, and the day/basename shape filter already answers "which remote files are Sotto's".
- **Audio restore** (pull `.m4a` back).
- **Self-signed cert trust** (per-server fingerprint pinning) — only if a real need appears.
- **Notification on persistent auth failure** — status line first; escalate only if silent rot
  proves to be a real problem.
- **Google Drive** — next provider row behind the same seam.
