# M12 — Omi Devkit 2 Hardware Verification (user-owned)

Run when the Devkit 2 arrives. Automated coverage ends at FakeOmiTransport; these
checks are the only proof the real radio path works. Log results per item.

## Spike S1 — background mic activation (do FIRST; iPhone only, no Omi needed)
- [ ] Simulate: app backgrounded + listening via a (fake or real) BLE source, then force
      a fallback: does `PhoneMicAudioSource.start()` succeed from the background with no
      user tap? (Instrument via the captureUnavailable notification: if fallback works
      you get the "Omi disconnected — continuing on iPhone mic" notification; if iOS
      refuses you get "Recording stopped".)
- [ ] If iOS refuses: file a follow-up to convert auto-fallback to the actionable
      notification path (spec's documented degradation) — the failover/notification
      plumbing already supports it.

## Basic path
- [ ] Pair via Settings → device appears by service UUID scan, name shown.
- [ ] Codec characteristic reads 20 (Opus/16 kHz) on current firmware; Settings shows
      no codec failure. (Older firmware: PCM16 also acceptable.)
- [ ] Live streaming: speak near the pendant → segment records, transcribes; audio
      sounds clean (no clicks — if clicky, revisit silence-fill vs PLC).
- [ ] Frontmatter shows `source: omi`; detail view shows "Omi".

## Failover
- [ ] Walk away with the pendant (phone stationary) → within ~6 s: fallback
      notification + home header shows "iPhone mic" + old segment closed.
- [ ] Walk back → within ~15 s of BLE reconnect: header shows "Omi", segment rolled.
- [ ] Radio-blip test (pendant in a metal box for 1–2 s) → NO segment split.
- [ ] Battery level shows in Settings; drain below 15% → one low-battery notification.

## All-day soak
- [ ] Overnight background session streaming from the pendant: no app kill, Live
      Activity stays truthful, day folder populated.
- [ ] Force-kill the app while streaming → does iOS relaunch on BLE data (state
      restoration, stretch S2)? Record behavior either way; if it relaunches but the
      pipeline doesn't resume, file the S2 follow-up task.

## Transport race regression confirmations (from code review)

These target specific concurrency assumptions baked into `CoreBluetoothOmiTransport` and
`FailoverAudioSource` that automated tests (with `FakeOmiTransport`) can exercise in
simulation but cannot confirm against the real CoreBluetooth stack and a real radio.

- [ ] Confirm `cancelPeripheralConnection` on a PENDING connect is silent (no
      `didFailToConnect`) on the target iOS version — the phantom-disconnect filter
      assumes it; if it fires, verify the effect is only a transient `.disconnected`
      flicker on fast same-device restart.
- [ ] Fast stop→restart to the same device: confirm no `.disconnected`/`.connecting`
      flicker reaches `connectionStates()` observers.
- [ ] Concurrent "add device" scan + rediscovery reconnect, BOTH orders: UI scan
      survives the target match; UI stopScan mid-rediscovery leaves the reconnect scan
      running.
- [ ] `stopEvents()` mid-rediscovery: confirm the radio actually stops (fixed battery
      leak regression check).
- [ ] State restoration round trip: background-kill while connected → BLE relaunch →
      does audio resume via the follow-up `events()` call, or does a restored
      already-`.connected` peripheral sit dead (`didConnect` never re-fires)? Also:
      `connect()` on an already-connected peripheral re-fires `didConnect` per docs —
      confirm.
- [ ] Old-firmware battery (no notify support): one `readValue` level arrives, no
      crash/log noise from unimplemented `didUpdateNotificationStateFor`.
- [ ] Simulator UI pass: double "Open Settings" banner stacking (micDenied + Bluetooth-off
      simultaneously) — acceptable or needs consolidation.
