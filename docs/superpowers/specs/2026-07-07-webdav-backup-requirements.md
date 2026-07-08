# WebDAV Backup — Requirements (pre-design)

> **Status:** Requirements capture. **NOT yet designed** — this is the seed for a future
> brainstorm, not an approved design. Decisions marked "open" belong to that brainstorm.
> **Date:** 2026-07-07.
> **Depends on:** the iCloud phase shipping first — see
> `specs/2026-07-07-backup-restore-icloud-design.md` (the `TranscriptSyncSink` seam and the
> Backup & Restore Settings section this feature plugs into).
> **Also gated by:** the in-flight rename feature (`specs/2026-07-07-rename-conversation-design.md`)
> landing, so the mutation-event set is stable before we build the second sink.

## Why this exists

Sotto's original folder-picker sync (`plans/2026-07-05-m11-cloud-sync-folder.md`) is a dead end for
self-hosted / mainstream-cloud targets. **Research finding, do not re-litigate:** iOS grants
*folder-destination* selection (`.fileImporter(allowedContentTypes: [.folder])`) only for providers
whose File Provider extension opts into it — in practice iCloud Drive, on-device local storage, and
a few apps that explicitly support it (Working Copy, Secure ShellFish). **Google Drive, OneDrive,
Dropbox, and OpenCloud grey out** in that picker; it's their File Provider implementation choice, and
Apple's File Provider framework rewrite did not change it. Targeting a self-hosted server therefore
requires a **direct client**, not the picker.

WebDAV is that direct client: an opt-in backup destination for self-hosters (the primary user runs
OpenCloud). It is the **first "additional backup type"** in the Backup & Restore section's provider
dropdown; Google Drive is a later slot behind the same seam.

## What we already know (firm requirements)

- **Opt-in**, off by default. iCloud backup remains the default-on path for everyone; WebDAV is for
  users who deliberately configure a server.
- **Conforms to `TranscriptSyncSink`** (`upsert`/`remove`). No `move` verb is needed — no Sotto
  feature performs a filesystem rename/move (merge reuses the earliest basename; rename rewrites
  `.md` content in place). Same proof as the iCloud spec §3. A server-side `MOVE` may be used as an
  efficiency optimization but is never required.
- **Auth: username + app password (HTTP Basic)**, stored in Keychain via the existing `KeychainStore`
  pattern (service `com.decanlys.Sotto`, new keys). The user generates an app password in OpenCloud.
- **Settings form**: server URL + username + app password, with a "Test connection" affordance
  before saving. Lives as the first entry in the Backup & Restore "additional providers" dropdown.
- **Optional audio backup** — a per-WebDAV toggle. Unlike iCloud (transcripts only, for quota +
  privacy), a WebDAV target is the user's *own* server, so audio (`.m4a`) may be included at the
  user's choice. `_day.json` and `.caf` still never leave the device.
- **Layout**: mirror the local `<yyyy-MM-dd>/<basename>.md` (+ optional `.m4a`) day structure under a
  base collection on the server.
- **Verbs**: `PUT` for `upsert`, `DELETE` for `remove`, `MKCOL` to create day collections.
- **Best-effort, non-blocking** — identical contract to the iCloud sink: a slow/failed request must
  never fail a transcription job, block the queue, delay the transition handler, or ride the main
  actor. Detached, failure-isolated.
- **Reachability**: reuse the existing `NetworkMonitoring` / `WiFiMonitor` / `WiFiGatedService`
  seam (`Sotto/Transcription/NetworkMonitoring.swift`) and honor the existing `wifiOnlyUpload`
  setting. The HTTP-client precedent to follow is `DeepgramService` (`URLSession`, injected).

## Known constraint (drives a follow-up, not launch scope)

iOS background execution carries file **`PUT`** uploads reliably, but **`DELETE`/`MOVE` effectively
run foreground-only** — so deletes/renames may lag until the app's next foreground. Plan for a
**reconcile / catch-up pass** eventually (on foreground, diff local against server and apply pending
removals). This is explicitly a **follow-up, not initial WebDAV scope**.

## Open questions for the brainstorm

- **Restore parity?** iCloud has inbound restore. Should WebDAV also support *pull* (restore
  transcripts from the server to a new device), or is it backup-only at first? A self-hoster likely
  wants restore too — but it reopens the "which source wins" question. Decide in the brainstorm.
- **Base path**: fixed convention (e.g. `/Sotto/`) vs user-chosen remote folder. OpenCloud WebDAV
  endpoints look like `https://<host>/remote.php/dav/files/<user>/…` — confirm the exact base and
  whether the user supplies the full collection URL or just host + path.
- **Self-signed / custom-CA servers**: many self-hosters run their own TLS. How much cert handling
  do we support (system trust only vs pinning vs allow-user-trust)? Security-sensitive — treat
  carefully.
- **Connection/auth failure UX**: how are 401s, unreachable hosts, and full-disk (507) surfaced in
  Settings without being noisy during normal best-effort operation?
- **Directory creation strategy**: `MKCOL` per day lazily on first write vs ensure-tree upfront.
- **Concurrency/ordering**: multiple rapid `upsert`/`remove` for the same path — last-write-wins is
  probably fine given single-active-device, but confirm.
- **Multi-provider fan-out cost**: with both iCloud and WebDAV active, each finalized transcript
  fans out to both. Confirm that's acceptable and there's no ordering coupling between sinks.

## References

- iCloud phase design (the seam + Settings section): `specs/2026-07-07-backup-restore-icloud-design.md`
- Dead-end folder picker (removed): `plans/2026-07-05-m11-cloud-sync-folder.md`
- Rename feature (mutation-event stability): `specs/2026-07-07-rename-conversation-design.md`
- HTTP client precedent: `Sotto/Transcription/DeepgramService.swift`
- Reachability seam: `Sotto/Transcription/NetworkMonitoring.swift`
- Keychain pattern: `Sotto/Transcription/KeychainStore.swift`
