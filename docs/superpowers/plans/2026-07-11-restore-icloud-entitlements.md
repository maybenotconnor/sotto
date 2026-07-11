# Restore iCloud Entitlements + Paid Team Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the iCloud entitlements removed for free-provisioning (issue #5) and bake the paid team ID into `project.yml` so signing survives xcodegen regeneration.

**Architecture:** `project.yml` is the xcodegen source of truth — `Sotto/Sotto.entitlements` and `Sotto.xcodeproj` are generated artifacts. All edits happen in `project.yml`; `xcodegen generate` propagates them. No Swift changes: `ICloudSyncSink` activates on its own once the ubiquity container resolves.

**Tech Stack:** XcodeGen 2.45.4, xcodebuild, gh CLI.

## Global Constraints

- Paid Apple Developer team ID: `XV3864F3BP` (spec: "add `DEVELOPMENT_TEAM: XV3864F3BP` to top-level `settings.base`").
- iCloud container identifier: `iCloud.com.decanlys.Sotto`; service: `CloudDocuments`.
- Commit messages: plain, no Co-Authored-By / attribution trailers (user preference).
- Device-side signing verification (Xcode account sign-in, on-device run) is a manual user step — out of scope for this plan.

---

### Task 1: Restore entitlements + DEVELOPMENT_TEAM in project.yml and regenerate

**Files:**
- Modify: `project.yml:7-10` (top-level `settings.base`) and `project.yml:56-69` (`targets.Sotto.entitlements`)
- Generated (do not hand-edit): `Sotto/Sotto.entitlements`, `Sotto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a commit on `main` restoring the iCloud capability; Task 2 references its SHA when closing issue #5.

- [x] **Step 1: Add DEVELOPMENT_TEAM to top-level settings**

In `project.yml`, change the top-level `settings` block (currently lines 7–10) to:

```yaml
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated
    DEVELOPMENT_TEAM: XV3864F3BP
```

- [x] **Step 2: Restore the iCloud entitlement properties**

In `project.yml`, replace the `entitlements` block under `targets.Sotto` (currently lines 56–69, the block with the `# TEMPORARY — free-provisioning workaround` comment and `properties: {}`) with:

```yaml
    entitlements:
      path: Sotto/Sotto.entitlements
      # xcodegen REGENERATES this file on every `xcodegen generate`; without these
      # properties it writes an empty <dict/>, silently stripping the iCloud capability
      # (discovered when the signing round-trip's entitlements kept reverting).
      properties:
        com.apple.developer.icloud-container-identifiers:
          - iCloud.com.decanlys.Sotto
        com.apple.developer.icloud-services:
          - CloudDocuments
        com.apple.developer.ubiquity-container-identifiers:
          - iCloud.com.decanlys.Sotto
```

- [x] **Step 3: Regenerate the project**

Run: `xcodegen generate`
Expected: `Created project at /Users/connor/OpenCloud/Personal/GithubProjects/sotto/Sotto.xcodeproj`

- [x] **Step 4: Verify the entitlements file matches the pre-workaround version**

Run: `git show 5162b92^:Sotto/Sotto.entitlements | diff - Sotto/Sotto.entitlements && echo IDENTICAL`
Expected: `IDENTICAL` (no diff lines — byte-identical to the version before commit 5162b92 removed it)

- [x] **Step 5: Verify DEVELOPMENT_TEAM landed in the pbxproj**

Run: `grep -c "DEVELOPMENT_TEAM = XV3864F3BP;" Sotto.xcodeproj/project.pbxproj`
Expected: `2` or more (project-level Debug + Release configurations; targets inherit project settings)

- [x] **Step 6: Verify a simulator build still compiles**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (simulator builds don't require the paid team; this checks the regenerated project is structurally sound)

- [x] **Step 7: Commit**

```bash
git add project.yml Sotto/Sotto.entitlements Sotto.xcodeproj/project.pbxproj
git commit -m "build: restore iCloud entitlements, sign with paid developer team

The paid Apple Developer Program membership is approved, so the
free-provisioning workaround from #5 is no longer needed. Restore the
CloudDocuments/ubiquity-container entitlements in project.yml (the
xcodegen source of truth) and bake DEVELOPMENT_TEAM into settings.base
so the team selection survives xcodegen regeneration.

Closes #5"
```

### Task 2: Push and close issue #5

**Files:**
- None (git remote + GitHub state only)

**Interfaces:**
- Consumes: Task 1's commit SHA on `main`.
- Produces: issue #5 closed with a pointer to the restoring commit.

- [x] **Step 1: Push main**

Run: `git push origin main`
Expected: `main -> main` in output; the `Closes #5` trailer auto-closes the issue on push.

- [x] **Step 2: Confirm issue state, close manually if the trailer didn't fire**

Run: `gh issue view 5 --repo maybenotconnor/sotto --json state,stateReason -q .state`
Expected: `CLOSED`. If it prints `OPEN`, run:

```bash
gh issue close 5 --repo maybenotconnor/sotto --comment "Restored by <SHA of Task 1 commit>: iCloud entitlements are back in project.yml and DEVELOPMENT_TEAM XV3864F3BP is baked into settings.base. Remaining manual steps (Xcode account sign-in, on-device verification) are listed in docs/superpowers/specs/2026-07-11-restore-icloud-entitlements-design.md."
```

- [x] **Step 3: Commit plan checkbox updates**

```bash
git add docs/superpowers/plans/2026-07-11-restore-icloud-entitlements.md
git commit -m "docs: mark restore-icloud-entitlements plan complete" && git push origin main
```
