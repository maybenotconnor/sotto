# Restore iCloud Entitlements + Paid Team Signing — Design

**Date:** 2026-07-11
**Closes:** GitHub issue #5 (Restore iCloud backup entitlement before release)
**Reverts the effect of:** commit `5162b92` (build: drop iCloud entitlement for free-provisioning device testing)

## Context

To sign Sotto with a free "Personal Team" for on-device testing, the iCloud
entitlements were emptied out of `project.yml` (commit `5162b92`, issue #5). A
Personal Team cannot grant the CloudDocuments/ubiquity-container capability.
The paid Apple Developer Program membership is now approved (team ID
`XV3864F3BP`), so the entitlements can be restored.

A second gap surfaced while planning the restore: the project declares no
`DEVELOPMENT_TEAM` anywhere, so any team selected in Xcode's Signing &
Capabilities pane is wiped every `xcodegen generate`. That was tolerable with
free provisioning; with the iCloud capability the paid team must be selected
for signing to succeed at all, so the team ID gets baked into `project.yml`.

## Changes

### 1. `project.yml`

- `targets.Sotto.entitlements`: delete the TEMPORARY workaround comment block
  and empty `properties: {}`; restore the original three keys:
  - `com.apple.developer.icloud-container-identifiers: [iCloud.com.decanlys.Sotto]`
  - `com.apple.developer.icloud-services: [CloudDocuments]`
  - `com.apple.developer.ubiquity-container-identifiers: [iCloud.com.decanlys.Sotto]`
  - Restore the original warning comment: xcodegen regenerates
    `Sotto.entitlements` on every `xcodegen generate` and silently strips any
    capability not declared in these properties.
- Top-level `settings.base`: add `DEVELOPMENT_TEAM: XV3864F3BP` so the app,
  the SottoWidgets extension, and the test bundle all sign with the paid team,
  and the selection survives regeneration. (Team IDs are public-ish metadata —
  they appear in every signed app's entitlements — so committing one is safe.)

### 2. Regenerate

Run `xcodegen generate`. This rewrites `Sotto/Sotto.entitlements` back to the
three-key dict and stamps `DEVELOPMENT_TEAM` into all pbxproj configurations.

### 3. No Swift changes

`ICloudSyncSink` no-ops when the ubiquity container resolves to `nil` and
activates on its own once it resolves; the Settings screen's "iCloud
unavailable" state clears the same way.

## Verification

- Regenerated `Sotto/Sotto.entitlements` is byte-identical to the
  pre-workaround version (`git show 5162b92^:Sotto/Sotto.entitlements`).
- `project.pbxproj` contains `DEVELOPMENT_TEAM = XV3864F3BP` in Sotto,
  SottoWidgets, and SottoTests configurations.
- A simulator build compiles (simulator builds don't need the paid team; this
  checks nothing broke structurally).

## Manual steps (user, in Xcode — outside this change)

1. Xcode ▸ Settings ▸ Accounts: sign in with the paid-membership Apple ID.
   Automatic signing then registers the `com.decanlys.Sotto` /
   `com.decanlys.Sotto.SottoWidgets` App IDs, creates the
   `iCloud.com.decanlys.Sotto` container under team `XV3864F3BP`, and issues a
   development certificate.
2. Run on device; confirm Settings no longer shows "iCloud unavailable".
3. Paid-team profiles last a year — the 7-day free-provisioning refresh cycle
   ends.

**If signing fails with "cannot create iCloud container":** Xcode hasn't
finished registering it — use Signing & Capabilities ▸ "Try Again", or
register the container manually at developer.apple.com ▸ Identifiers. Runtime
code degrades gracefully either way.

## Close-out

Single commit for the config change; comment on and close issue #5 pointing
at it.
