# EasyVM refresh roadmap

_Proposed: August 5, 2026_

The roadmap is ordered by risk reduction. Dates should be assigned only after the baseline builds on current Xcode and the open issues are triaged.

## Phase 0 — Re-establish the baseline

**Outcome:** contributors can reproduce the current behavior and failures.

- Build with the current stable Xcode and document warnings, runtime failures and supported host/guest combinations.
- Add a macOS CI build with signing disabled.
- Add issue templates for VM creation, boot, networking and file sharing failures.
- Define a compact manual smoke test: create, install, boot, stop, reopen, recovery boot and delete for macOS and one ARM64 Linux distribution.
- Publish an explicit compatibility matrix for the macOS 26 baseline and gated macOS 27 capabilities.

**Exit gate:** clean CI build plus a recorded smoke-test result on at least one supported macOS version.

## Phase 1 — Make the VM lifecycle dependable

**Outcome:** the core create/run/stop path fails safely and explains what happened.

- Separate VM domain/configuration code from SwiftUI views and window controllers.
- Replace stringly typed errors and silent `try?` paths with typed, user-actionable errors.
- Version `config.json` and `state.json`; add decoding fixtures, validation, migrations and atomic writes.
- Make long operations cancellable and recover interrupted downloads/installations.
- Validate CPU, memory, disk space, image architecture, permissions and configuration before starting work.
- Define ownership and cleanup rules for partial VM bundles; never delete user-selected data implicitly.
- Add structured, privacy-reviewed local diagnostics with an export action.

**Exit gate:** automated configuration tests and repeatable recovery from each intentionally interrupted lifecycle step.

## Phase 2 — Ship like a maintained macOS app

**Outcome:** users can install and update a trusted build.

- Add unit tests around configuration, paths, migrations and device validation.
- Add UI smoke coverage only for the highest-value create/start flows.
- Create versioned, signed and notarized GitHub Releases with checksums and release notes.
- Publish a Homebrew Cask after the first stable signed release, targeting `brew install --cask easyvm`.
- Add Sparkle only if sustainable update signing and hosting are available; otherwise keep manual updates honest and simple.
- Improve accessibility labels, keyboard navigation, empty states and destructive-action confirmation.
- Replace stale community/status text and publish a security policy.

**Exit gate:** a release candidate can be installed on a clean supported Mac from both GitHub Releases and Homebrew, then complete the smoke test without Xcode.

## Phase 3 — Improve daily usefulness

**Outcome:** EasyVM is pleasant for repeated local use without expanding its mission.

- Reliable duplicate/clone using APFS copy-on-write when available.
- Clear disk usage, guest image source, last run, runtime state and failure state.
- Presets for a few tested macOS and ARM64 Linux configurations.
- Better VirtioFS guidance and clipboard behavior where supported by the guest.
- Suspend/save-state only after compatibility and data-integrity behavior are well tested.
- Import/export configuration metadata separately from large VM disks.

**Exit gate:** common repeat workflows need no manual bundle/file manipulation.

## Phase 4 — Add a small automation surface

**Outcome:** humans and agents can use the stable core through bounded, inspectable operations.

- Introduce an `easyvm` CLI backed by the same VM service as the app.
- Start read-only with `list`, `inspect`, `validate` and `doctor`; return versioned JSON.
- Add `start`, `stop`, `clone` and `delete` with deterministic exit codes, timeouts and explicit destructive confirmation.
- Support disposable clones and per-VM shared-directory allowlists.
- Consider a local-only MCP server after the CLI contract proves stable; map tools directly to the same commands.
- Log who requested each mutation and make all agent-facing operations visible in the app.

**Exit gate:** an automated client can clone a known VM, start it, observe state, stop it and delete the clone without broad filesystem permission.

## Backlog only after evidence

- Headless operation
- URL Scheme and Shortcuts actions
- Serial console and SSH discovery
- Snapshot management beyond APFS cloning
- Remote display/control for computer-use agents
- OCI image import/export

Each item needs a real user workflow and a maintenance-cost review before promotion.

## First seven implementation issues

1. Current-Xcode build audit and compatibility matrix.
2. CI build with code signing disabled.
3. Versioned configuration schema plus fixtures.
4. Typed VM validation and error model.
5. Atomic bundle creation and interrupted-install recovery.
6. Local diagnostic bundle with secret redaction.
7. Signed/notarized release automation and Homebrew Cask publication.

This ordering deliberately keeps AI/agent work behind the reliability boundary. The same engineering that makes the GUI safe is what makes automation safe.
