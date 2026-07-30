# App Review information — v1.0 draft

For the "Notes" box in App Store Connect (4000-char limit; the block below is
~3,100). Attach the demo video (placeholder below) as an attachment or link.
No demo account is needed — the app has no accounts.

---

Sotto is a meeting notetaker. The user taps Start before a meeting; the app then
listens in the background, uses on-device voice activity detection to record
only while people are speaking, transcribes each conversation on-device, and
saves it as a Markdown file with generated notes. This is a user-initiated
recording session with background continuation — the same pattern as existing
approved recorders — not an always-on service. The session runs until the user
stops it.

BACKGROUND MODES (guideline 2.5.4)
- "audio": captures microphone audio only during the session the user explicitly
  started, for the app's core recording purpose. Nothing plays or records
  outside a user-started session.
- "bluetooth-central": streams audio from an optional paired Omi wearable
  microphone and restores the connection if the app is relaunched.

RECORDING VISIBILITY AND CONSENT (guideline 2.5.14)
- While listening, the iOS orange microphone indicator is always on and a
  persistent Live Activity on the lock screen shows recording state with a
  pause/resume button.
- Onboarding requires the user to accept responsibility for recording laws
  (one-party vs. all-party consent) before the first session; the page cannot
  be skipped. A fuller legal summary is available in Settings.
- Phone calls, FaceTime, and Siri automatically interrupt the microphone;
  the user must manually resume.

PRIVACY
- Default configuration: everything on-device. Voice detection (bundled CoreML
  model), transcription (Apple SpeechAnalyzer), and notes (Apple Foundation
  Models) all run locally. The developer operates no servers and collects no
  data; there are no accounts, no analytics, and no tracking.
- Recordings and transcripts are stored in the app's Documents folder, visible
  to the user in the Files app. By default audio is deleted once its transcript
  is written. Users can delete any conversation in-app.
- Optional, off-by-default integrations, each using the user's own API key or
  server and disclosed in Settings: Deepgram (audio, for speaker-separated
  transcription), OpenAI / Anthropic / OpenRouter / self-hosted server
  (transcript text only, for notes), WebDAV backup and iCloud Drive sync
  (user's own storage).

OPTIONAL HARDWARE (guideline 2.1)
The Omi wearable is an optional Bluetooth microphone accessory. No feature
requires it: the app is fully reviewable with the iPhone microphone alone. A
demo video showing pairing, wearable capture, and automatic failover to the
phone microphone is attached: [DEMO VIDEO LINK — record during C8 hardware pass]

HOW TO TEST
1. Launch, swipe through onboarding, accept the recording-responsibility page,
   allow microphone (and optionally notification) access.
2. Download the speech model when offered (one-time download).
3. Tap Start. Note the orange indicator and the lock-screen Live Activity.
4. Talk for 20–30 seconds, then stay silent for about a minute (the default
   45-second silence timeout closes the conversation).
5. The conversation appears on the home screen with its transcript and notes.
   Tap it to view; share or delete from the detail view.
6. Optional: lock the phone during step 4 — recording continues and the Live
   Activity reflects it.

---

## Also required on the app record (D14)

- **Privacy policy URL** — not yet written; must cover: no developer data
  collection; on-device processing default; the BYOK integrations above
  (including Deepgram model-improvement opt-out); iCloud sync; user deletion.
- **Support URL** — decide: GitHub issues page vs. a decanlys.com page.
- **Nutrition labels** — "Data Not Collected" (consistent with the privacy
  manifest merged in PR #22: no tracking, empty collected-data types).
