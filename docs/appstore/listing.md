# App Store listing copy — v1.0 draft

> **Gate:** D13 (name knock-out: App Store search + USPTO on "Sotto") is still open.
> All copy below is name-portable — the name appears only where marked, so a rename
> is a find-and-replace, not a rewrite.
>
> Positioning per `docs/SPEC.md` (adopted 2026-07-04): meeting-notetaker frame,
> user-initiated session with background continuation. Never "records everything
> all day." No battery claims until profiling (flight-check C10) is done.

## Name (30 chars max) — DECIDED 2026-07-30

**Sotto — Offline Auto Notetaker** (30/30)

Backups if D13 or App Store Connect rejects it: "Sotto — Offline Meeting Notes"
(29), "Sotto — One Note per Meeting" (28).

## Subtitle (30 chars max) — DECIDED 2026-07-30

**Notes that start themselves** (27/30)

## Promotional text (170 chars max)

> Start Sotto before your meetings. It waits in silence, notices when the
> conversation begins, and writes private on-device transcripts and notes —
> hands-free.

(159 chars)

## Description (4000 chars max)

Sotto is the notetaker that starts itself.

Tap Start before a meeting — or a morning full of them — and put your phone away. Sotto keeps listening in the background, notices when people actually start talking, and records only those moments. Every conversation becomes a clean transcript with meeting notes, written entirely on your iPhone.

To be clear about how it works: after you tap Start, Sotto records audio in the background until you stop it. While it listens, iOS shows the orange microphone indicator and Sotto keeps a Live Activity on your lock screen — so recording is always visible, to you and to the people around you. A phone call or Siri automatically pauses listening; resuming takes one tap.

WHY SOTTO
• Starts itself — on-device voice detection opens each recording the moment speech begins (with a one-second pre-roll so first words aren't lost) and closes it when the conversation ends.
• Private by default — audio and transcripts never leave your iPhone unless you choose otherwise. Transcription and notes are generated on-device.
• Plain files, no lock-in — every conversation is a Markdown file you can open in the Files app. No account. No subscription.
• Tidy by default — once a transcript is safely written, the audio is deleted. Prefer to keep recordings? Choose 7 days or forever.

WEAR IT (OPTIONAL)
Pair an Omi wearable and Sotto records from its microphone over Bluetooth instead of the phone's. If the wearable disconnects or runs down, your iPhone microphone takes over automatically — and Sotto tells you it happened.

NOTES, YOUR WAY
Summaries are generated on-device by default. Want a bigger model? Bring your own API key for OpenAI, Anthropic, or OpenRouter — or point Sotto at a server you run yourself (Ollama works). Only transcript text is ever sent, never audio, and only under your own account.

SYNC & BACK UP (OPTIONAL)
• iCloud Drive — transcripts mirror automatically to iCloud. Audio stays on the phone.
• WebDAV — back up transcripts (and, if you choose, audio) to your own server, such as Nextcloud.
• Deepgram — optional speaker-separated transcription under your own API key, with model-improvement data sharing opted out.

RECORDING RESPONSIBLY
Recording conversations is a legal responsibility that varies by place — some regions require everyone's consent. Sotto explains this before your first session and asks you to accept that responsibility, and its always-visible indicators help you stay honest with the people around you.

REQUIRES
iOS 26 or later. Transcription works fully offline after a one-time speech-model download. On-device transcription and notes need an iPhone that supports Apple Intelligence; on other devices Sotto still records and saves conversations for you. Omi wearable optional.

(~2,550 chars)

## Keywords (100 chars max)

```
recorder,voice,meeting,memo,ai,transcribe,private,summary,omi,wearable,minutes,markdown
```

(87 chars. Name and subtitle words are already indexed — the chosen name covers
offline/auto/notetaker and the subtitle covers notes, so those are deliberately
absent here.)

## What's New — 1.0

> First release. Start a session, put your phone away: on-device voice detection
> records each conversation, transcribes it, and writes meeting notes — private
> by default, saved as plain Markdown files.

## Category / age rating

- Primary: Productivity. Secondary: Business.
- Age rating questionnaire: expect 4+ (no objectionable content categories apply).

## Screenshot shot-list (D15 — 6.9″ iPhone + 13″ iPad)

1. Home with an active listening session — Live Activity/hero card visible, "starts itself" caption.
2. A finished conversation: transcript + notes detail view.
3. Lock screen with the Live Activity (visibility/honesty story).
4. Settings summary section — on-device default, BYOK providers (privacy story).
5. Files.app showing the day folder of Markdown files (no lock-in story).
6. Omi pairing / wearable card (optional-hardware story).
