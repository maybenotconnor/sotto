---
title: Sotto Privacy Policy
permalink: /privacy/
---

# Sotto Privacy Policy

**Effective July 30, 2026**

Sotto is developed by Decanlys.

## The short version

Sotto collects no data. There are no accounts, no analytics, no ads, no
tracking, and no Decanlys servers. Your audio and transcripts stay on your
device unless you connect an outside service yourself — and nothing below
changes that default.

## What Sotto does with your audio

Everything in Sotto's core loop happens on your device: voice detection,
recording, transcription (Apple's on-device speech models), and note
generation (Apple's on-device foundation models).

Recordings and transcripts are stored in Sotto's Documents folder on your
device, where you can see and manage them in the Files app. By default, a
conversation's audio file is deleted as soon as its transcript is safely
written; you can instead choose to keep audio for 7 days or forever. You can
delete any conversation from within the app at any time, and deleting it also
removes it from any backups you've enabled below.

## Optional services you can connect

Each of the following is off by default, is enabled only by you, and uses your
own account or API key. When enabled, data goes directly from your device to
that provider and is handled under that provider's privacy policy — Decanlys
is never in the middle and never sees it.

- **iCloud Drive (Apple)** — transcript files (never audio) sync to your
  private iCloud container.
- **Deepgram** — if you choose Deepgram transcription, conversation audio is
  sent to Deepgram under your API key. Sotto sends Deepgram's
  model-improvement opt-out flag with every request, so your audio is not
  used for training.
- **OpenAI, Anthropic, OpenRouter, or your own server** — if you choose a
  cloud notes provider, transcript text (never audio) is sent to the provider
  you selected under your API key.
- **WebDAV backup** — transcripts (and audio, only if you turn that on) are
  uploaded to a server you specify, over HTTPS, using credentials you provide.

API keys and passwords you enter are stored in the iOS Keychain on your
device and are sent only to the provider they belong to.

## Apple system services

The one-time speech model download comes from Apple and sends no personal
data. Notifications are generated locally on your device. If you have opted
in to sharing analytics with developers in iOS Settings, Apple may provide
Decanlys with aggregated crash reports as described in Apple's privacy
policy.

## Your responsibilities

Sotto records conversations. Laws about recording vary by region — some
require the consent of everyone involved. You are responsible for using
Sotto lawfully; the app explains this before your first session and keeps
recording visibly indicated while it listens.

## Children

Sotto is not directed at children under 13.

## Changes

If this policy changes, the updated version will be posted at this address
with a new effective date.

## Contact

Questions or requests: [connor@decanlys.com](mailto:connor@decanlys.com), or
open an issue at
[github.com/maybenotconnor/sotto](https://github.com/maybenotconnor/sotto/issues).
