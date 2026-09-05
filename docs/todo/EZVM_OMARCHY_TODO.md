# EZVM Omarchy follow-up TODO

Last updated: 2026-09-04

This file records work intentionally deferred after the first signed EZVM
Omarchy Alpha. It is not a list of regressions hidden from the release: the
Alpha is a preview, and stable/Daily Driver promotion remains gated by the
items identified below.

## Alpha checkpoint

The signed `1.0.0-alpha.44` candidate is built from Host revision
`2867664db8921d4b72c7e9e493bddffb694fb9b4`. It completed a public multipart
Factory cold install and real-Guest validation for:

- first-owner provisioning and authenticated Integration readiness;
- focused Command-to-Super, including `Command-Space`;
- text and PNG clipboard in both directions;
- shared-folder and file-import byte round trips;
- dynamic Retina display resizing and full-screen enter/exit;
- secure lock/unlock, pause/resume, Agent restart, and Guest restart recovery;
- Guest-to-macOS notification delivery;
- protected snapshot creation, mutation, rollback, and byte verification;
- Developer ID signing, strict code-sign verification, Gatekeeper assessment,
  release-archive round trip, and the pixel-rally application icon.

The post-candidate monitoring fix is revision
`2d72c78cff192efc15960e7d5d1fc06ba4cdee70`. It prevents a soak run from using
a heartbeat left by the preceding Guest boot as its new identity baseline.

## Required before stable / Daily Driver promotion

- [ ] Complete an uninterrupted 24-hour authenticated Guest soak. Preserve the
  generated `soak-observation.json` and bind it to the exact signed candidate.
  The Alpha 44 run was deliberately stopped before 24 hours when this work was
  moved to the follow-up backlog; it must not be described as passed.
- [ ] Repeat a controlled real macOS sleep/wake cycle against the exact release
  candidate. Verify display, network, audio, clipboard, Command/Super, Agent,
  Session Agent, and interactive desktop recovery. The exploratory sleep run on
  an earlier candidate is useful evidence but does not close this gate.
- [ ] Run multi-day daily-driver workloads: browser, terminal, editor, Git,
  SSH, media playback, large clipboard payloads, shared-folder churn, host
  network changes, and repeated lock/unlock cycles.
- [ ] Exercise memory pressure and low-disk conditions without corrupting the
  workspace, recovery points, downloads, or acceptance evidence.
- [ ] Validate update and rollback across at least two successive Omarchy
  Factory/App versions, including interruption during every mutation phase.
- [ ] Complete branding and Omarchy trademark/asset redistribution review
  before using language stronger than “independent community preview.”

## Integration follow-ups

- [ ] Add explicit diagnostics for event-tap disablement and automatic
  re-enablement after timeout, Fast User Switching, and permission changes.
- [ ] Test Command/Super with non-US layouts, multiple input methods, both
  Command keys, modifier rollover, long key repeats, and focus changes while a
  chord is held.
- [ ] Add richer clipboard MIME support beyond UTF-8 text and PNG, with bounded
  payload sizes and clear failure reporting.
- [ ] Add Finder “Open in Omarchy” and Guest “Reveal on macOS” workflows using
  capability-scoped requests rather than arbitrary Host command execution.
- [ ] Improve notification activation so clicking a macOS notification focuses
  the originating Guest application when the Guest can provide that identity.
- [ ] Finish microphone, camera, selectable USB passthrough, host audio-device
  switching, and external-display/scale acceptance before advertising them.
- [ ] Split desktop operations into a clearly versioned unprivileged Session
  Agent boundary if future Omarchy integrations require privileges beyond the
  current capability set.

## Distribution and maintenance

- [ ] Create a dedicated update channel and optional Homebrew cask for EZVM
  Omarchy without changing the regular EZVM release channel.
- [ ] Automate notarized Alpha/Beta/RC publication while keeping stable
  promotion blocked on real sleep/wake and 24-hour evidence.
- [ ] Define and publish the Host, Guest Agent, Factory image, and Omarchy
  compatibility matrix, including rollback rules and minimum supported builds.
- [ ] Add a privacy-reviewed diagnostics export and a user-facing “Integration
  health” screen with actionable recovery instructions.
- [ ] Decide retention rules for downloaded multipart Factory assets, protected
  snapshots, old release candidates, and acceptance workspaces.
- [ ] Repeat accessibility, localization, VoiceOver, reduced-motion, and
  keyboard-only product review before stable release.

## Temporary acceptance data

The current local acceptance workspace under `/private/tmp` is approximately
16 GiB because it contains the active Guest and protected rollback state. It
may be deleted when no further Alpha 44 evidence is needed. Test-created
`/tmp/ezvm-*` directories must continue to be removed by their owning scripts
or manually after confirming that no running VM or acceptance process uses
them.
