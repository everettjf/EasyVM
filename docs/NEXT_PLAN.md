# EZVM post-5.0 execution plan

_Baseline: EZVM 5.0.0 — August 27, 2026_

This document turns the broader [capability roadmap](ROADMAP.md) into an
ordered engineering plan. It covers only work that remains after 5.0.0 and
uses evidence-based promotion rules: compiling against an API is not enough;
a feature becomes stable only after the final signed Homebrew artifact passes
the relevant real-VM scenario.

## 5.0.0 baseline

The next cycle starts with these foundations already delivered:

- transactional, commit-bound release artifacts; Developer ID signing,
  notarization, Gatekeeper, GUI readiness, GitHub, and Homebrew gates;
- cross-process single-owner leases, atomic runtime metadata, multi-VM resource
  admission, and two-VM headless CLI coverage;
- native clone and `.ezvmexport` import/export with explicit copy-versus-
  restore identity semantics, checksums, rollback, and sparse allocation
  estimates;
- APFS snapshots, saved state, raw and ASIF disks, and interrupted-restore
  recovery;
- mutually authenticated Linux Guest Agent, IP discovery, heartbeat, SSH URL,
  shutdown/restart, and atomic chunked file transfer;
- real Alpine release fixtures that verify Agent authentication, byte-exact
  upload/download, clean shutdown, and guest `/dev/kvm` API version 12;
- production NAT networking only; restricted bridged, host-only, custom vmnet,
  and physical USB code is absent from the shipping target.

## Prioritization rules

1. P0 work may block the next release.
2. P1 completes existing user workflows before adding new platform surface.
3. P2 adds useful native capabilities with bounded scope.
4. P3 remains experimental or research until its promotion checklist passes.
5. Restricted entitlements are not implementation backlog. They have a
   separate re-entry gate and do not consume normal milestone capacity.

## P0 — Reliability and release reproducibility

**Target:** 3.3.x. No new product surface.

| Workstream | Deliverable | Acceptance criteria |
| --- | --- | --- |
| Headless failure cleanup | Make start timeout/cancellation terminate a VM that is stuck in `starting`, even if its bundle disappears; reap stale state files and release resource leases. | Fault-injection tests cover pre-start, start-callback-never-arrives, deleted bundle, SIGTERM, and forced-stop fallback; no EZVM process or lease remains. |
| Release fixture ownership | Add a documented builder for the Alpine Agent fixture, including EFI variable store, disk provenance, Agent version, enrollment generation, and checksum manifest. Keep secrets and the mutable disk outside Git. | A new fixture can be reproduced from documented inputs; CI/release rejects a fixture whose manifest, machine identity, Agent version, permissions, or checksum is wrong. |
| Release diagnostic bundle | Preserve logs, state JSON, candidate checksum, host/SDK build, VM config, and failure stage automatically when any release gate fails; redact enrollment tokens. | A failed gate produces one timestamped archive that explains whether failure occurred at launch, VM start, Agent auth, transfer, KVM, stop, or Homebrew install. |
| Candidate identity chain | Extend the existing source-commit marker to record toolchain version, signing identity fingerprint, Agent source commit, and fixture manifest digest. | Every published checksum can be traced to one commit and build context; resume refuses any mismatch. |
| Compatibility matrix | Run the signed Homebrew artifact on the minimum supported macOS, current stable macOS, and macOS 27 preview/stable as applicable. | Each row records install, Gatekeeper, GUI ready, NAT boot, clean stop, and feature availability; unsupported rows fail before publication. |
| Data-operation fault injection | Kill clone, export, import, snapshot, restore, and raw-to-ASIF conversion at defined commit points. | Source remains intact; destination is either complete or absent; recovery is idempotent; temporary artifacts are discoverable and safely removable. |

P0 is complete when a full release can be rerun on a clean machine without
manual fixture repair, Keychain prompts, orphaned processes, or ambiguous
failure messages.

## P1 — Finish current workflows

**Target:** 5.1.0.

| Feature | Scope | Acceptance criteria |
| --- | --- | --- |
| Long-running Guest Agent soak | Reconnect after Agent restart, guest reboot, host sleep/wake, VM pause/resume, saved-state restore, and transient vsock failure. | A 24-hour scenario has bounded reconnect backoff, no duplicate session, no stuck transfer, and no main-thread blocking. |
| Transfer job model | Persistent per-VM queue, explicit destination, retry/cancel, history, and drag-and-drop integration; never persist authentication tokens in job metadata. | Multiple files survive UI navigation; partial destinations remain invisible; cancellation and reconnect are deterministic. |
| Guest operation results | Return and display accepted/completed/failed results for shutdown and restart with timestamps. | UI never reports success merely because a command was sent; Agent restart/disconnect paths are covered. |
| Clipboard completion | Detect `spice-vdagent`, display readiness and remediation, and verify text copy in both directions on selected distros. | Absence does not affect boot; bidirectional Unicode and large-text tests pass; capability is no longer labelled Partial. |
| Runtime VirtioFS updates | Distinguish live-applicable share changes from restart-required changes, validate tag collisions, and expose guest mount instructions. | Editing shares cannot silently diverge from the running hardware configuration; reconnect and saved-state behavior is specified. |
| Clone/export/import UX | Progress, cancellation, required/available space, APFS clone/fallback explanation, and recovery action for interrupted jobs. | Multi-hundred-GB sparse test images do not require memory-sized buffers; UI and CLI report the same transaction state. |
| Snapshot maintenance | Dry-run orphan cleanup, storage forecast, protected-branch rules, and saved-state/disk/config divergence explanation. | Cleanup never removes a referenced layer; audit can account for every snapshot and disk object. |
| CLI mutation parity | Add `clone` and `export`; add `import` only with an explicit destination and identity mode. Defer `delete` until a recoverable trash design exists. | Versioned JSON, exact targets, shared leases, progress, cancellation, and the same validation engine as GUI. |
| Linux presets | Publish tested Alpine, Ubuntu, Debian, and Fedora ARM64 profiles with entropy, balloon, vsock, Agent installation, and optional Rosetta guidance. | Each preset boots in a release fixture and documents kernel/guest package requirements. |

## P2 — New bounded capabilities

**Target:** 3.5+ after P0 and the relevant P1 dependency are complete.

| Feature | Dependency | Promotion gate |
| --- | --- | --- |
| Serial terminal | Shared runtime service and logging policy. | Reconnect, UTF-8, copy, bounded scrollback, and saved-state tests on Linux; no terminal data is collected automatically. |
| User-space TCP forwarding | Authenticated guest discovery and lifecycle ownership. | Loopback-by-default bind, explicit ports, collision handling, TCP half-close/backpressure, teardown on VM stop, and threat-model review. UDP is a separate project. |
| Guided Rosetta setup | Linux presets and Agent command-result support. | Supported host/guest matrix, `binfmt_misc` verification, cache visibility, uninstall guidance, and real x86_64 executable smoke test. |
| Docker/KVM guest profile | Stable nested virtualization plus distro presets. | Inside-guest container smoke test, `/dev/kvm` diagnostics, CPU/memory guidance, suspend/restore statement, and unsupported-host fallback. |
| Recovery boot automation | Fixture-safe macOS test environment. | Signed artifact enters recovery, reports a deterministic state, and exits without modifying the source fixture. |
| OVF/OVA import research | Stable native import transaction and format mapping document. | Written compatibility matrix and loss report precede implementation; unsupported devices fail explicitly rather than being dropped. |
| Local Shortcuts actions | Idempotent CLI/service operations. | Explicit VM identity, bounded waits, structured result, and no destructive action without confirmation. |

## P3 — Experimental platform work

P3 code stays disabled by default and is not part of the normal reliability
promise. Each item needs an owner, a real fixture, migration/rollback behavior,
and two supported host OS releases before promotion.

| Experiment | Remaining proof |
| --- | --- |
| DiskImageKit layered ASIF snapshots | Crash recovery at every layer mutation, compaction, long branch chains, base-image loss, low-space behavior, performance comparison, and export/import flattening policy. |
| macOS 27 guest provisioning | Account creation and retry semantics, secret lifetime, cancellation, partially provisioned guest recovery, final-system inspection, and Developer ID/Homebrew validation. |
| EFI Secure Boot management | Enrollment/disable/reenable lifecycle, corrupted variable store recovery, saved-state compatibility, distro matrix, and clear ownership of keys. |
| Custom Virtio device | No work until a concrete product use case and maintained guest driver exist; there is intentionally no generic toggle. |
| OCI/image distribution | Decide whether a local cache/import adapter solves a real workflow without turning EZVM into a registry or CI platform. |
| Local API or MCP | Threat model, per-operation authorization, local peer identity, audit log, cancellation, and stable CLI schemas first. Start read-only. |
| macOS guest iCloud workflow | Legal/product/security review of Apple account behavior before any UI or automation work. |

## Restricted and out-of-scope work

These items are not scheduled in P0–P3:

- bridged networking, host-only networking, custom vmnet topologies, and vmnet
  port forwarding require Apple approval for `com.apple.vm.networking` plus a
  matching Developer ID provisioning profile;
- physical USB passthrough and hot-plug require the applicable Accessory Access
  entitlement and a proven Homebrew distribution path;
- x86 guests, general GPU passthrough, and general PCIe passthrough are not
  provided by Virtualization.framework and remain out of scope.

Restricted work can re-enter only through the checklist in
[ROADMAP.md](ROADMAP.md#restricted-feature-re-entry-checklist). No UI placeholder,
dead implementation, or entitlement may ship before that checklist passes.

## Cross-cutting definition of done

Every promoted capability must have:

1. one shared implementation for GUI and automation where applicable;
2. availability and compatibility checks before mutation starts;
3. bounded cancellation and rollback semantics;
4. unit tests plus a signed-artifact real-VM scenario;
5. diagnostics that identify the failed stage without exposing tokens or guest
   file contents;
6. documentation for normal use, unsupported configurations, and recovery;
7. verification from the Homebrew-installed artifact, not only an Xcode build.

## Suggested release sequence

1. **3.3.x:** P0 only—headless cleanup, fixture builder, diagnostics, provenance,
   compatibility matrix, and transaction fault injection.
2. **5.1.0:** Guest Agent soak, transfer jobs/drag-and-drop, clipboard, runtime
   shares, portability UX, snapshot maintenance, CLI clone/export, and distro
   presets.
3. **5.2.0:** serial terminal, carefully scoped TCP forwarding, guided Rosetta,
   Docker/KVM profile, recovery automation, and selected Shortcuts actions.
4. **Later:** promote individual P3 experiments only when their evidence is
   complete; do not bundle experimental graduation into a deadline-driven
   release.

The plan should be reviewed after every minor release. Completed rows move to
the baseline, failed assumptions are recorded, and priorities are recalculated
from user impact and reliability evidence rather than API novelty.
