# WebDAV Backup — Design

> **Status:** design, awaiting review. **Date:** 2026-07-08.
> **Scope of this doc:** the WebDAV backup connector — the second `TranscriptSyncSink`, an
> opt-in outbound backup to a user-configured self-hosted server (primary target: OpenCloud).
> **Supersedes the open questions in** `specs/2026-07-07-webdav-backup-requirements.md` (the
> brainstorm seed); resolutions are in §2.
> **Depends on:** the iCloud phase (`specs/2026-07-07-backup-restore-icloud-design.md`) —
> shipped. This design plugs into the `TranscriptSyncSink` seam, `SyncSinkRegistry` fan-out,
> and the Backup & Restore Settings section that phase built.

## 1. Context & motivation

The iCloud phase established the load-bearing seam: every finalized transcript fans out through
`SyncSinkRegistry` to a list of `TranscriptSyncSink`s, each best-effort, detached, and
failure-isolated. iCloud is the first sink; **WebDAV is the second.**

Why a direct client at all (settled — do not re-litigate): iOS grants *folder-destination*
selection only to File Provider extensions that opt in, which OpenCloud / Google Drive / OneDrive
/ Dropbox do **not**. Targeting a self-hosted server therefore requires a direct WebDAV client,
not the Files-app picker. WebDAV is that client: an opt-in backup destination for self-hosters.

**What WebDAV is NOT (decided in brainstorm — see §2):** it is *not* the primary backup and *not*
a restore path. iCloud remains the default-on, everyone-gets-it backup **and** the restore path
for device migration. WebDAV is an additional, opt-in, outbound-only mirror to a server the user
already trusts and runs. A self-hoster who wants their transcripts on their own box turns it on;
everyone else never sees it.

## 2. Decided in brainstorm

The requirements doc left seven open questions. Resolutions:

| Question | Decision | Rationale |
|---|---|---|
| **Restore parity?** | **Backup-only. No inbound pull.** | iCloud is the real backup + restore (default-on, additive, idempotent). WebDAV and iCloud are not mutually exclusive — a WebDAV user still has iCloud restore. Adding a WebDAV pull would reopen "which source wins" for no gain. Outbound-only keeps the sink a pure mirror. |
| **Audio backup?** | **Out of scope entirely — transcripts (`.md`) only, no toggle.** | Overrides the requirements doc's "optional audio toggle." WebDAV matches iCloud exactly: `.md` only; `_day.json`, `.caf`, `.m4a` never leave the device via this sink. Removes a whole config axis and keeps both sinks identical in what they mirror. |
| **Server URL model** | **User supplies the full base collection URL.** | e.g. `https://cloud.example.com/remote.php/dav/files/alice/Sotto`. Sotto mirrors `<day>/<basename>.md` **under** it. No baked-in `remote.php/dav/files/<user>` assumption → works across WebDAV servers, not just OpenCloud. "Test connection" validates the URL before it's saved. |
| **TLS / cert handling** | **System trust only. No in-app trust bypass.** | Accept only certs the OS already trusts (public CAs + user-installed CA configuration profiles). Self-hosters install their CA via a profile — standard iOS practice. A user-confirmed-self-signed path is a security-sensitive trust override we deliberately do **not** build; zero bypass surface. |
| **Directory creation** | **`MKCOL` the `<day>` collection lazily on first write.** | The base collection is the user's responsibility (validated at "Test connection"). We create only the per-day child, lazily, ignoring "already exists" (405). No upfront ensure-tree. |
| **Concurrency / ordering** | **Last-write-wins, no locking.** | Single active device (same assumption as iCloud restore). Rapid `upsert`/`remove` on one path resolve to the final state; no `If-Match`/lock coordination needed. |
| **Multi-provider fan-out** | **Acceptable, no coupling.** | Each sink is dispatched in its own `Task.detached`; iCloud and WebDAV never await each other. This is already how the fan-out works — WebDAV just appends to `activeSinks`. |

## 3. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Direction | **Outbound backup only** (`PUT`/`DELETE`/`MKCOL`); never pull | iCloud owns restore (§2). |
| Contents | **`.md` transcripts only** — never audio, `_day.json`, `.caf` | Matches iCloud; audio out of scope (§2). |
| Enablement | **Opt-in, off by default** | iCloud is the default path; WebDAV is deliberate self-hoster config. |
| Auth | **Username + app password, HTTP Basic**; password in Keychain | Simplest reliable auth; matches OpenCloud's app-password model. URL + username in `UserDefaults`, password in Keychain (secret/non-secret split, mirroring the Deepgram key). |
| Server target | **User-supplied full base collection URL** | Server-agnostic (§2). |
| Layout | **`<baseURL>/<yyyy-MM-dd>/<basename>.md`** | Mirrors the local day-directory structure under the user's collection. |
| TLS | **System trust only** | No bypass (§2). |
| Contract | **Best-effort, non-blocking, detached, failure-isolated** | Identical to iCloud/the `TranscriptSyncSink` contract: a slow/failed request never fails a job, blocks the queue, delays a transition handler, or rides the main actor. |
| Reachability | **Honor `wifiOnlyUpload`; gate the sink at assembly** | Reuses the existing `NetworkMonitoring`/`WiFiMonitor` seam. Off Wi-Fi with the toggle on → the WebDAV sink is not assembled for that event (no partial work). |
| Verb surface | **`upsert`/`remove` only** — same no-`move` proof as iCloud §3 | No Sotto feature renames/moves a file; a server-side `MOVE` is never required. |

## 4. Architecture

WebDAV slots into the existing seam. The only genuinely new machinery is an HTTP client and a
config value; the sink itself is thin.

### 4.1 `WebDAVConfig` — the resolved, valid configuration

```swift
/// A complete, validated WebDAV target. Constructed only when all of enabled + base URL +
/// username + app password are present; a nil `load` means "WebDAV not configured" → the sink
/// is simply not assembled. Sendable value; carries the secret so the sink needs no Keychain
/// access on the hot path.
struct WebDAVConfig: Sendable {
    let baseURL: URL       // the user's full base collection URL
    let username: String
    let appPassword: String

    /// Resolves from settings (URL + username in UserDefaults) + Keychain (app password).
    /// Returns nil unless backup is enabled AND all three fields are present AND the URL parses
    /// as an https(s) URL. Keychain read is fast/sync — safe from `activeSinks`.
    static func load(_ settings: SettingsStore, keychain: KeychainStore = KeychainStore()) -> WebDAVConfig?
}
```

**Persistence.** New `SettingsStore` accessors (in `RetentionPolicy.swift`, matching the existing
style): `webDAVBackupEnabled: Bool` (default **false**), `webDAVServerURL: String?`,
`webDAVUsername: String?`. App password in Keychain under key `webDAVAppPassword` (service
`com.decanlys.Sotto`, via the existing `KeychainStore`). The URL/username are not secret →
`UserDefaults`; only the password is Keychain-held — the exact split the Deepgram key uses.

### 4.2 `WebDAVClient` — the HTTP verbs

Precedent: `DeepgramService` (`URLSession`, injected, best-effort). A protocol so the sink is
unit-testable without a network; the real impl is tested against a `URLProtocol` stub.

```swift
enum WebDAVResult: Sendable { case ok, unauthorized, insufficientStorage, unreachable, failed(Int) }

protocol WebDAVClienting: Sendable {
    /// Create a collection. `already-exists` (405) counts as success.
    func mkcol(_ relativePath: String) async -> WebDAVResult
    func put(_ data: Data, to relativePath: String) async -> WebDAVResult
    func delete(_ relativePath: String) async -> WebDAVResult
    /// "Test connection": a PROPFIND (Depth: 0) on the base collection.
    func check() async -> WebDAVResult
}

/// Real client: builds requests against `config.baseURL`, HTTP Basic auth from
/// `config.username`/`config.appPassword`, using an injected `URLSession` (default `.shared`).
/// System-trust TLS only — no delegate cert override. All ops best-effort: any transport error
/// maps to `.unreachable`, never throws.
struct WebDAVClient: WebDAVClienting {
    let config: WebDAVConfig
    let session: URLSession
    init(config: WebDAVConfig, session: URLSession = .shared)
}
```

Status mapping (both the sink and "Test connection" read it): `2xx` → `.ok`; `405` on `mkcol`
→ `.ok` (collection already there); `401`/`403` → `.unauthorized`; `507` → `.insufficientStorage`;
transport failure → `.unreachable`; other non-2xx → `.failed(code)`.

**Path construction.** `relativePath` (e.g. `2026-07-05/09-15-00.md`) is percent-encoded per
component and appended to `config.baseURL`. The base collection is assumed to exist (the user
created it and "Test connection" confirmed it); only day collections are `MKCOL`'d.

### 4.3 `WebDAVSyncSink` — the sink

```swift
/// Second TranscriptSyncSink (design 2026-07-08): opt-in outbound mirror of finalized `.md`
/// transcripts to a user-configured WebDAV server. Transcripts only — never audio. Best-effort
/// and failure-isolated: every op degrades to "didn't back up"; nothing throws into the caller.
struct WebDAVSyncSink: TranscriptSyncSink {
    let client: WebDAVClienting

    func upsert(_ segment: SyncSegment) async {
        guard let data = try? Data(contentsOf: segment.markdown) else { return }  // .md gone → skip
        _ = await client.mkcol(segment.day)                    // lazy day collection; 405 = ok
        _ = await client.put(data, to: "\(segment.day)/\(segment.basename).md")   // audio ignored
    }

    func remove(day: String, basename: String) async {
        _ = await client.delete("\(day)/\(basename).md")       // 404 tolerated (already gone)
    }
}
```

The sink reads the `.md` bytes off the injected local URL and `PUT`s them — it never touches
`segment.audio`. `remove` is a single `DELETE`; a `404` is fine (local is truth).

### 4.4 Registry integration + Wi-Fi gate

`SyncSinkRegistry.activeSinks` appends the WebDAV sink when configured **and** reachable under the
Wi-Fi-only policy. Gating at assembly (not inside the sink) means an off-Wi-Fi event produces no
WebDAV sink at all — no partial upload, consistent with how `WiFiGatedService` decides whether to
even use Deepgram.

```swift
static func activeSinks(_ settings: SettingsStore) -> [any TranscriptSyncSink] {
    #if DEBUG
    if let testSinks { return testSinks }
    #endif
    var sinks: [any TranscriptSyncSink] = []
    if settings.iCloudBackupEnabled { sinks.append(ICloudSyncSink()) }
    if let config = WebDAVConfig.load(settings),
       !settings.wifiOnlyUpload || sharedMonitor.isOnWiFi {          // honor Wi-Fi-only
        sinks.append(WebDAVSyncSink(client: WebDAVClient(config: config)))
    }
    return sinks
}

/// Lazily-created shared reachability monitor — constructed only once WebDAV is first
/// enabled (referenced solely inside the WebDAV branch), so users who never configure WebDAV
/// pay nothing. Avoids starting a fresh NWPathMonitor per fan-out event.
private static let sharedMonitor: NetworkMonitoring = WiFiMonitor()
```

The five AppModel choke points are **unchanged** — they already call
`SyncSinkRegistry.upsert/remove(m4aURL:, settings)`; WebDAV rides the same fan-out with no new
call sites.

## 5. Settings — WebDAV subsection in Backup & Restore

Added to the existing `backupSection` (`SettingsView.swift`), below the iCloud controls. The
iCloud design reserved an "additional backup providers" area for exactly this; with a single
additional provider a full dropdown is YAGNI, so this ships as a **WebDAV disclosure group**,
structured so a future Google Drive provider generalizes it into a picker.

Fields (mirroring the Deepgram-key form's shape — `SecureField`, "Test connection" button with a
✓/✗ result, `persist` on submit/disappear):

- **Toggle** "Back up to WebDAV server" — bound to `webDAVBackupEnabled` (default off).
- **Server URL** (`TextField`, `.URL` keyboard, no autocap) — the full base collection URL.
- **Username** (`TextField`, no autocap).
- **App password** (`SecureField`) — persisted to Keychain; cleared from Keychain when emptied,
  exactly like the Deepgram key's `persistKey()`.
- **"Test connection"** button → `model.testWebDAVConnection(url:username:password:) async -> String`,
  a user-initiated real network call (never from setup/tests). Returns a human string mapped from
  `WebDAVResult`: `"Connected."` / `"Authentication failed — check username and app password."` /
  `"Server unreachable — check the URL and your network."` / `"Server is out of space."` /
  `"Unexpected server response (<code>)."`
- Copy: "Transcripts (not audio) are also mirrored to your own WebDAV server. This is in addition
  to iCloud, not a replacement." + a note that removing a transcript on this device removes it
  from the server on the next foreground (see §6).

`AppModel.testWebDAVConnection` builds an ephemeral `WebDAVConfig` from the typed-in values (not
yet persisted) and runs `WebDAVClient(config:).check()` on a detached task — the same
user-initiated-only, off-main pattern as `testDeepgramKey`.

## 6. Failure UX & known limitations

- **During normal best-effort operation:** silent. A failed `PUT`/`DELETE` is not surfaced
  per-event (that would be noisy for a background mirror) — it degrades to "didn't back up",
  retried implicitly by the next event on that path, or by a future reconcile pass.
- **In Settings:** "Test connection" is the explicit, user-initiated surface for 401 / unreachable
  / 507. That's where auth and connectivity problems get reported, not mid-recording.
- **Foreground-only `DELETE` (known iOS constraint):** background execution carries `PUT`
  reliably but `DELETE` effectively runs foreground-only, so a delete of a transcript may lag on
  the server until the app's next foreground. Combined with off-Wi-Fi gating (§4.4), a `remove`
  can be dropped for that event. **A reconcile / catch-up pass** (on foreground: diff local
  against server, apply pending removals) is the fix — explicitly a **follow-up, not this scope**,
  same as the requirements doc called out.
- **Background upload session:** v1 uses a standard injected `URLSession` (the Deepgram
  precedent), which is correct because the fan-out fires as a recording finalizes (app active).
  A `URLSessionConfiguration.background` transfer session for uploads that outlive foreground is a
  possible later enhancement, not launch scope.

## 7. Testing strategy

Test command (unchanged): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination
'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. New files →
`xcodegen generate`. Zero new warnings; Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.

- **`WebDAVConfig.load`:** nil when disabled / URL missing / username missing / password missing /
  URL unparseable; non-nil with all present; reads the password from Keychain.
- **`WebDAVClient`** (against a `URLProtocol` stub): `put`/`delete`/`mkcol`/`check` issue the right
  HTTP method to the right percent-encoded URL with an `Authorization: Basic …` header; status
  mapping (`2xx`→ok, `405`→ok for mkcol, `401`→unauthorized, `507`→insufficientStorage, transport
  error → unreachable, other → failed(code)).
- **`WebDAVSyncSink`** (against a `RecordingWebDAVClient` fake): `upsert` issues `mkcol(day)` then
  `put(<day>/<base>.md)` and never `put`s audio; a missing local `.md` skips silently; `remove`
  issues `delete(<day>/<base>.md)`.
- **`SyncSinkRegistry.activeSinks`:** WebDAV sink present when enabled + config valid (Wi-Fi
  allowed via an injected monitor in tests); absent when disabled, config incomplete, or off-Wi-Fi
  with `wifiOnlyUpload` on; iCloud + WebDAV both present when both enabled.
- **`AppModel.testWebDAVConnection`** (against a stub client / `URLProtocol`): maps each
  `WebDAVResult` to the correct human string.
- **Manual (device):** configure an OpenCloud app password + collection URL, "Test connection"
  → Connected; record a segment → the `.md` appears under `<collection>/<day>/`; delete it locally
  → gone from the server on next foreground; disable the toggle → uploads stop.

## 8. Forward compatibility & out of scope

- **Reconcile / catch-up pass** for foreground-only `DELETE` lag and off-Wi-Fi dropped events —
  the first WebDAV follow-up.
- **Background upload session** (`URLSessionConfiguration.background`) — later enhancement.
- **WebDAV restore / pull** — explicitly not built; iCloud is the restore path.
- **Audio backup** — explicitly not built (§2).
- **Google Drive** — a future sink + the generalization of §5's WebDAV group into a provider
  picker; no core changes.
- **Self-signed / user-trusted certs** — not built; system trust only (§2).

## 9. References

- iCloud phase design (the seam + Settings section): `specs/2026-07-07-backup-restore-icloud-design.md`
- WebDAV requirements (brainstorm seed): `specs/2026-07-07-webdav-backup-requirements.md`
- HTTP client precedent: `Sotto/Transcription/DeepgramService.swift`
- Reachability seam: `Sotto/Transcription/NetworkMonitoring.swift`
- Keychain pattern: `Sotto/Transcription/KeychainStore.swift`
- Sink seam + fan-out: `Sotto/Files/TranscriptSyncSink.swift`
- iCloud sink (structural twin): `Sotto/Files/ICloudSyncSink.swift`
