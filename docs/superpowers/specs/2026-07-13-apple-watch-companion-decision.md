# Apple Watch Companion — Decision

Date: 2026-07-13
Status: **Rejected — not pursuing at this time**

## Summary

We evaluated adding an Apple Watch companion app so Sotto could record on the watch instead of the
iPhone mic or an Omi wearable. **The mechanism is feasible, but we are not building it now.** The
watch does not clearly beat what we already ship (phone mic) or already support (Omi) on the axes
that matter — capture quality and battery — and it would add a whole new app target, battery risk,
and sync latency for a narrow, conditional benefit.

This doc records the reasoning so the idea isn't silently re-opened. Full technical/strategy analysis:
the feasibility memo produced during the 2026-07-13 evaluation (chat), condensed below.

## What we confirmed is *feasible* (not the blocker)

- **Background recording on watchOS is a solved, approved pattern.** `WKBackgroundModes: audio` +
  `AVAudioSession`/recorder runs indefinitely while actively recording (not the time-capped Extended
  Runtime Session). Just Press Record is a live App-Store example of exactly this.
- **The phone-side ingestion seam already exists.** A "watch records locally, transfers finished
  segments" design (the only architecture worth building — see below) would inject via the existing
  salvaged-audio path: `TranscriptionQueue.enqueueSalvaged(m4aURL:)` feeding the day index +
  transcription queue, mirroring the `segmentHandler` wiring in `AppModel`. It would **not** need the
  live `WearableAudioSource`/`FailoverAudioSource` seam that Omi uses.
- Transcription (SpeechAnalyzer / Apple Intelligence) must stay on the phone regardless — it does not
  exist on watchOS — which cleanly forces the split (watch = capture+VAD+segments, phone =
  transcribe+store).

Two architectures were considered; only **B** (record-on-watch + `WCSession.transferFile` of finalized
segments) fits the goal. **A** (live-stream `AudioChunk`s to the phone as a new `DeviceKind.watch`
`WearableAudioSource`) was rejected earlier: WatchConnectivity has no dependable continuous audio
channel over multi-hour sessions, it requires the phone present and awake, and it lights both radios
continuously — defeating "record instead of the phone."

## Why we are NOT pursuing it

1. **The wrist mic is not a reliable upgrade over a pocketed phone.** For ASR, fabric is the killer —
   it low-passes away the consonant energy transcription needs; distance mostly just lowers level
   (gain-recoverable). The wrist wins only in its best case (short sleeve, hand still on a surface,
   quiet room) and ties or loses under a sleeve, hand-in-lap, or in noise. The phone in a pocket is
   *reliably mediocre*; the wrist is *unpredictable* — and inconsistency is itself bad for an
   unbabysat notetaker. Neither approaches a chest-worn Omi's placement.
2. **Battery: the watch, not the phone, is the binding constraint — ~1/10 the phone's energy.** A
   standard Apple Watch (~1.2 Wh vs the iPhone's ~12 Wh) realistically sustains only a few hours of
   continuous mic+VAD capture, and a dead watch by mid-afternoon is a *worse* failure than a dead
   Omi (the watch is a device the user depends on). All-day ambient on the wrist is not viable on a
   standard model; only an Ultra gets close.
3. **VAD does not rescue the battery ceiling.** Mic + audio session + continuous VAD inference is an
   irreducible floor; VAD saves the *downstream* cost (encode/store/transfer/transcribe of silence),
   not the watch's hours-per-charge. So recording longer than Just Press Record is a strictly harder
   battery problem, and JPR proves the *mechanism*, not the *endurance* we'd need.
4. **Thin marginal value for a large build.** The watch only beats Sotto's existing phone-mic mode in
   a narrow scenario — phone deliberately away, watch on the wrist, bounded session — while adding a
   new app target, battery risk, and sync latency the phone-mic path doesn't have. It is also not a
   clean Omi replacement (Omi wins on all-day battery and mic placement).

## What would reopen this

Revisit if any of these change:

- Sotto's target shifts decisively to **bounded meeting/conversation capture** (not all-day), where
  the watch's battery limit stops mattering and "notetaker on your wrist, no hardware to buy" becomes
  a real wedge for Apple Watch owners.
- A concrete, common user scenario emerges where the **phone is reliably away from the conversation**
  but the watch is on the wrist.
- Wrist capture quality is shown to be good enough in realistic (not best-case) conditions — see the
  test below.

## Cheap test to run *first* if revisited (no code, ~1 afternoon)

Before any build, settle the one thing that actually decides it — **wrist capture quality** — with a
no-code probe: record 3–4 real conversations using built-in **Voice Memos on an Apple Watch** with the
phone in another room, run them through the same on-device SpeechAnalyzer path Sotto uses, and judge
transcript usability against SPEC open-question #1's pocket-audio bar. **Design it around the failure
cases** — long sleeve over the watch, hand in the lap, and a noisy room — not a quiet desk with the
watch exposed. A best-case-only win is a demo, not a product. If wrist transcripts aren't clearly and
*reliably* better than phone-in-pocket, don't build it.

## Impact on the codebase

None. No watch target, `DeviceKind`, or `AudioSourceType` case is added. `SPEC.md`'s
`[future: WatchSource]` note remains accurate as an unbuilt idea; this doc is the authoritative record
of why it is not being pursued now.
