# Omi Failover Redesign — Mic-First Capture, Honest Waiting, Loud Alerts — Design

**Date:** 2026-07-23
**Status:** Approved design (all decisions user-approved interactively, 2026-07-21 → 2026-07-23)

## Summary

Root-cause-driven rework of the audio-source failover process and its UX. A device log
archive (2026-07-23) proved the failure the user reported: the 3-second startup race
converts a guaranteed-legal *foreground* phone-mic start at the moment of the Start tap
into a *background* one three seconds later, which iOS refuses. The session then becomes a
zombie — green "Listening", Settings pinned at "Connecting…", capturing nothing, with no
recovery path short of a manual Stop → Start.

The redesign: invert the race (mic starts instantly, the Omi upgrades when it streams),
make capture loss a recoverable **waiting** state with an honest UI, make the existing
"Recording stopped" notification loud and truthful (tapping it *is* the fix), and stop
the transport/Settings from misreporting device state. Everything downstream of the
`AudioSource` seam (VAD, recorder, writer, transcription, files) is unchanged.

## Root cause (verified on-device, 2026-07-23)

From the `Failover` os_log trail (diagnostics added 2026-07-21):

- 4/4 sessions where the app stayed foreground through the 3-second race fell back to the
  iPhone mic correctly. The foreground path has no defect.
- The failing session: Omi unreachable (state `connecting`), startup race expired at
  t+3 s **with the app already backgrounded** → `PhoneMicAudioSource.start()` threw
  `NSOSStatusErrorDomain Code=561015905` (`'!pla'`, "Session activation failed" — iOS
  refuses to activate a record session from the background) → `.captureUnavailable` →
  status stayed `.listening` for 24 minutes, capturing nothing, until a manual Stop.
- Trigger recipe: Omi unreachable + tap Start + lock/pocket the phone within the 3-second
  window. Cold Live-Activity starts from the lock screen hit the same wall at t+0.

Contributing defects confirmed by review (multi-agent, adversarially verified):

1. `.captureUnavailable` is a dead-end: the failover never retries the mic (only a
   wearable `.streaming` event recovers), and the `AudioSessionObserver` guards
   (`activeSourceType != .phoneMic → return`) also suppress recovery when
   `activeSourceType` is nil — exactly the nothing-capturing state.
2. The pipeline leaves `status == .listening` (or a pulsing "Recording…" over an open
   segment) after capture dies; no UI surface exists for the state.
3. Device status is session-scoped by design (SPEC "Omi Device" section) but Settings
   renders it as absolute truth — idle, paused, and freshly-paired all read "Not
   connected".
4. Transport silent stalls: service-discovery / characteristic-discovery / codec-read
   errors are swallowed, pinning a genuinely connected device at "Connecting…" forever;
   `didFailToConnect` re-issues a pending connect without yielding `.connecting`.
5. `activatePhoneMic` race: resuming from the awaited `phoneMic.start()` it re-checks
   only `generation`/`started`, so a wearable that activated during the suspension gets
   clobbered by the mic with no return hysteresis armed.

## User decisions (2026-07-21 → 2026-07-23)

1. **Contract — standing intent.** Start means "capture whenever you can until I say
   stop." The session survives capture gaps; recovery is automatic (Omi returning, or
   the mic retried at the next foreground), never dependent on the user noticing.
2. **Invert the startup race.** The phone mic starts *instantly* in the foreground moment
   of the Start tap; the Omi connects in parallel and takes over when it streams. The
   3-second startup race timer is deleted.
3. **Upgrade timing.** The *first* `.streaming` of a session switches to the Omi
   immediately (nothing to distrust yet; usually lands before a segment opens). The 10 s
   return hysteresis applies only after the Omi has failed once this session — react
   instantly to first evidence, demand sustained evidence only from a source that has
   already failed.
4. **Waiting notification timing.** Fires after 30 s in the waiting state; cancelled if
   capture recovers first — only persistent gaps alert.
5. **Notification loudness.** The "Recording stopped" alert must always be a full, loud
   prompt. Since iOS cannot deliver one notification loudly under provisional-only
   authorization, the app requests **full** notification authorization (alert + sound),
   replacing today's silent provisional grant.
6. **Process discipline.** Spec precedes patches; the Failover diagnostics stay.

## Design

### 1. Source selection — `FailoverAudioSource`

The failover's model becomes: **the iPhone mic is the floor; the wearable is an upgrade
whenever it is streaming.** Rules (replacing the startup race):

- `start()`: start the wearable (as today) and immediately attempt `phoneMic.start()` —
  no timer between the tap and the mic. `FailoverConfig.startupRace` is deleted;
  `reconnectGrace` (3 s) and `returnHysteresis` (10 s) are unchanged.
- Mic start succeeds → activate `.phoneMic` (unless the wearable activated during the
  awaited start — see hardening below).
- Wearable `.streaming` arrives and the wearable has **never been active this session**
  → switch immediately (segment rollover as usual; with a healthy Omi this lands in
  ~1–2 s, before a segment typically opens).
- Wearable `.streaming` arrives while the mic is capturing, after the wearable **was
  previously active** (failed and returned) → existing 10 s return hysteresis. This
  distinction needs one new piece of **in-memory, per-session** actor state (e.g.
  `wearableWasActiveThisSession`, set when the wearable activates, reset in `start()`) —
  nothing persisted. The existing `hasEmittedInitial` cannot serve: it records *any*
  first activation, and under mic-first the mic sets it almost immediately every session.
- **Waiting is always rescued immediately.** While `activeSourceType == nil`, any
  wearable `.streaming` activates the wearable at once — the return hysteresis exists
  only to protect an actively-capturing mic from a flapping wearable; it never delays
  recovery from zero capture. No grace or hysteresis timer runs while in waiting;
  entering waiting cancels any in-flight reconnect-grace timer, and a wearable drop
  after a rescue re-arms the 3 s grace afresh.
- Wearable drops while active → existing 3 s reconnect grace, then activate the mic.
- Mic start **fails** (background `'!pla'`, permission, route, engine — any reason) →
  enter **waiting**: `activeSourceType = nil`, emit `.captureUnavailable`; the wearable
  side stays started with its pending connect armed (existing behavior — the Omi can
  still rescue the session at any time).
- **`start()` never throws on mic-start failure.** The session is always established; a
  failed initial mic start is simply the first waiting entry (emit `.captureUnavailable`,
  schedule the notification). `start()` throws only on the existing programmer-error
  `alreadyStarted` (or a wearable-side `start()` throw, unchanged).
- **New entry point `retryPhoneMic()`**: attempts mic activation; a no-op unless
  `started && activeSourceType == nil`. Invoked at most **once per scenePhase transition
  to `.active`** — no retry loop; a foreground mic failure (e.g. permission denied)
  waits for the next transition. Implemented as a call into the **hardened
  `activatePhoneMic` path** (below), so a wearable that activates during the awaited mic
  start wins and the orphaned mic start is undone — the same clobber-race protection
  applies. A successful retry flows through the existing activation path (UI recovery,
  notification cancel). A **failed** retry is *not* a new waiting entry: it neither
  reschedules nor replaces the pending notification.
- **Hardening (in scope — the function is being rewritten anyway):** `activatePhoneMic`
  re-checks `activeSourceType` after resuming from the awaited `phoneMic.start()`; if
  the wearable won activation during the suspension, undo the orphaned mic start instead
  of clobbering the streaming wearable.

Cold background starts (Live Activity toggle from the lock screen): the mic start fails
immediately, which is the same **waiting** state — honest UI, armed Omi, loud
notification, foreground retry. Strictly better than today's 3-seconds-then-zombie.

### 2. Capture loss is a state, not a dead-end — `ListeningPipeline` + UI

- `handleSourceChange(.captureUnavailable)`: finalize any open segment via the recorder
  (no eternal pulsing "Recording…" over dead capture); the session itself stays alive.
- `HeaderState` derives a **waiting** case, with explicit precedence: waiting derives
  **only** when status ∈ {listening, recording, silence} AND the session was started
  with the failover (switching) audio source — i.e. a wearable is paired — AND
  `activeSourceType == nil`. Paused/interrupted keep their existing header states even
  with a nil active source (the user or the system already knows capture stopped;
  waiting is reserved for states that would otherwise falsely claim capture). Plain
  phone-mic-only sessions never derive waiting — a dead mic there parks the session via
  existing paths. Rendering: amber dot, "Waiting" label, cause-neutral subtitle
  (provisional copy: "Can't record right now — waiting for Omi or the iPhone mic.").
  The mic-permission-denied case keeps its existing dedicated HeroCard footnote; the
  waiting subtitle must not promise that opening the app fixes it. Derived state only —
  no new persisted status.
- The Live Activity mirrors the same phase (amber "Waiting", not green "Listening").
- **Foreground retry hook:** on scenePhase `.active`, if a session is running (same
  status set as above — the hook skips paused/interrupted, whose recovery is the
  existing resume path) with `activeSourceType == nil`, call the pipeline's retry,
  which calls `FailoverAudioSource.retryPhoneMic()`. The `AudioSessionObserver` guards
  are unchanged — the nil case is now owned by this hook instead.

### 3. Notifications

- **Authorization:** `requestAuthorizationIfNeeded` requests full `[.alert, .sound]`
  (drops `.provisional`). The prompt appears at the existing call site (first session
  start), and is only made from the foreground — a cold background session start defers
  the request to the next foreground session start; its waiting notification delivers
  under whatever authorization currently holds. Existing provisional users see the full
  prompt at their next foreground session start; declining downgrades them to denied
  (accepted — the Settings notifications row surfaces it).
- **Waiting notification:** on entering waiting, schedule the existing
  capture-unavailable notification with a `UNTimeIntervalNotificationTrigger` of
  **exactly 30 s** (one named constant, tunable in one place) and default sound. Cancel
  **pending and delivered** on any successful activation (mic retry or Omi rescue) AND
  on session stop or park — a deliberate Stop must never be followed by a loud
  "Recording stopped" alert. Re-arm only on a genuine new waiting entry (transition
  from an active source, or session start, into waiting); a failed retry while already
  waiting neither reschedules nor replaces it. This changes the dedup *mechanism* from
  the existing per-gap `hasNotifiedCaptureUnavailable` flag to identifier-replace
  semantics (per-gap behavior itself already exists), and adds the 30 s delay +
  cancel-on-heal. The copy already says "Open Sotto to resume"; under the
  foreground-retry hook, tapping it genuinely is the fix.
- Other notifications (paused, source fallback, low battery) are unchanged in logic and
  now also deliver loudly under full authorization — acceptable; they are equally
  operational.

### 4. Device status honesty — Settings + transport

- `SettingsView.deviceStatusLabel` distinguishes `nil` (no session — "Connects when
  listening", provisional copy) from in-session `.disconnected` ("Not connected"), and
  the device section gains a one-line caption noting that live status appears while
  Sotto is listening.
- `CoreBluetoothOmiTransport` stops stalling silently:
  - `didFailToConnect` yields `.connecting` after `.disconnected` (parity with
    `didDisconnectPeripheral`, which already does).
  - Error or empty-result paths in `didDiscoverServices`,
    `didDiscoverCharacteristicsFor`, and the codec read completion yield
    `.disconnected` then `.connecting` and re-issue `central.connect` (the existing
    pending-retry pattern) instead of leaving the state pinned at "Connecting…" with a
    connected but unusable peripheral. No explicit backoff — retry cadence is gated by
    the BLE stack's own connect latency, matching the existing pending-retry pattern —
    and each failed negotiation cycle is logged at error level so a loop is visible in
    diagnostics; Settings shows "Connecting…" throughout (no label flicker).
  - An empty (0-byte) codec value keeps the documented Opus default but is logged —
    no known firmware produces it; surfacing beats silence, failing would be
    speculative.
- The unbounded "Connecting…" for a genuinely absent device remains — a pending connect
  *is* connecting; refining "Searching…" vs "Connecting…" is out of scope.

### 5. Diagnostics become permanent

The `Failover` os_log category (subsystem `app.decanlys.sotto`, added 2026-07-21) stays:
decision trail at notice level, failures at error level, app-state stamp on every
pipeline source change. `retryPhoneMic()` logs its trigger and outcome. This subsystem
has earned standing observability — the bug was found in one natural occurrence only
because the trail existed.

## Behavior, before → after

| Scenario | Today | After |
|---|---|---|
| Start, foreground, Omi absent | Mic from t+3 s | Mic from t+0 |
| Start, pocket phone within 3 s, Omi absent | Zombie session (the reported bug) | Mic already recording from t+0 |
| Live Activity start from lock screen, Omi absent | Zombie session | Waiting + loud notification at 30 s; **opening Sotto** (notification tap, app icon) → mic starts. Unlocking alone does not foreground a cold-started app |
| Omi drops mid-session, phone pocketed | Zombie session | Waiting; Omi return rescues **immediately**; else mic starts when the app next foregrounds (unlock, if it was foreground when locked); loud notification at 30 s if unhealed |
| Start with healthy Omi nearby | Silence 0–~2 s, then Omi | Mic from t+0, Omi takes over at first stream (~1–2 s), rollover usually before a segment opens |
| Omi flapping at range edge | 3 s grace + 10 s hysteresis | Unchanged |
| Settings while idle/paused | "Not connected" | "Connects when listening" + caption |
| Omi connected but negotiation errors | "Connecting…" forever, silent | `.disconnected` + automatic retry, visible |

Trade-off accepted: with a healthy Omi, every session start briefly runs the phone mic
(orange indicator flickers for a second or two until the Omi takes over) — more honest
for an ambient recorder, and the cost of making the failure class unrepresentable.

## Testing

- `FailoverAudioSourceTests`: startup-race tests are rewritten for mic-first — mic
  activates immediately; `start()` with a throwing mic yields a started source in
  waiting (never throws); first `.streaming` upgrades immediately; post-failure return
  while the mic captures waits out the hysteresis; rescue from waiting is **immediate**
  (the carried-over Omi-rescue test asserts no hysteresis delay); `retryPhoneMic()`
  no-ops when idle or a source is active and activates from waiting; a retry racing a
  concurrent `.streaming` leaves the wearable active (clobber-race regression, both for
  retry and for grace-expiry activation).
- `ListeningPipelineTests` / `ListeningPipelineSourceTests`: `.captureUnavailable`
  finalizes an open segment; retry path restores activation and UI state.
- `HeaderStateTests`: waiting derivation (running status + switching source + nil
  active source; paused/interrupted take precedence; phone-mic-only never waits).
- `LiveActivityWiringTests`: waiting phase pushed to the Live Activity (or, if the seam
  does not allow it, explicitly assigned to on-device verification).
- Notification tests (fake scheduler): 30 s trigger on waiting entry; cancel of **both
  pending and delivered** on recovery; cancel on stop/park (waiting entered, session
  stopped at t+10 s → nothing fires); re-arm on a second gap but not on a failed retry;
  full-authorization request options.
- `SettingsView` status label: unit coverage for the `nil` ("Connects when listening")
  vs in-session `.disconnected` ("Not connected") branch.
- Transport error paths: `didFailToConnect` yields `.disconnected` then `.connecting`;
  discovery/characteristic/codec-read error paths yield `.disconnected` → `.connecting`
  with a re-issued connect — via fake-transport tests where the seam allows; real-BLE
  error injection is documented as manual verification.
- On-device verification, two distinct recipes: (a) mid-session — session foreground,
  lock the phone, kill the Omi → waiting state, loud notification at 30 s, automatic
  mic recovery on unlock (scenePhase fires); (b) cold start — Live Activity Start from
  the lock screen with Omi off → waiting, notification at 30 s, recovery via the
  notification tap specifically. Plus: Start + immediate lock with Omi off → recording
  exists from t+0; healthy-Omi start → upgrade before the first segment opens.

## Implementation phasing

Two largely independent workstreams; plan and land them as two phases (or PRs):

- **Phase B (small, low-risk, can land first or in parallel):** device-status honesty —
  transport error-path yields + Settings idle label/caption (§4), with its tests and
  SPEC.md amendment.
- **Phase A (the core):** mic-first failover, waiting state, foreground retry,
  notification lifecycle + full authorization (§§1–3, §5), with its tests and SPEC.md
  amendments.

## Out of scope (deferred, tracked)

- Connect timeout and a "Searching…" vs "Connecting…" state distinction.
- Stream-stall watchdog for a BLE-connected but silent wearable.
- The ~100 ms AppModel status re-subscribe gap between sessions.
- Shared CBCentralManager restoration identifier across transport instances.
- Keeping an audio session active during Omi capture to legalize background mic starts
  (spike only; privacy-indicator and battery questions unanswered).

## SPEC.md amendments (to land with implementation)

- §"Omi Devkit 2 source (M12)" failover policy: replace "3 s startup race" with
  mic-first + immediate first upgrade + post-failure-only return hysteresis + waiting
  state semantics.
- §Settings "Omi Device": idle status copy ("Connects when listening" + caption)
  replacing the bare session-scoped labels.
- Notification/authorization notes: full authorization replaces provisional; waiting
  notification (30 s, cancel-on-heal, loud).
