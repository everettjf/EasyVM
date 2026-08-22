# EasyVM capability map and roadmap

_Updated: August 21, 2026_

EasyVM is a native macOS application built on Apple's
[`Virtualization.framework`](https://developer.apple.com/documentation/virtualization).
Its product boundary is macOS and ARM64 Linux virtualization on Apple silicon.
It is not intended to become a general CPU emulator or a replacement for QEMU.

This document is both a capability inventory and an implementation plan. It
separates features that are ready for users from experimental APIs, restricted
entitlements, and capabilities that the framework does not provide.

## Status definitions

| Status | Meaning |
| --- | --- |
| **Stable** | Implemented, exposed to users, and suitable for the normal release path. |
| **Partial** | A useful implementation exists, but compatibility, UX, or recovery work remains. |
| **Planned** | Fits the product and can be implemented without a restricted entitlement. |
| **Experimental** | Implemented or prototyped against beta/new system APIs; disabled by default. |
| **Restricted** | Requires an Apple-approved entitlement or another distribution approval. |
| **Out of scope** | Unsupported by Virtualization.framework or inconsistent with EasyVM's native focus. |

## Distribution rule

The Homebrew release must contain only entitlements that work with a normal
Developer ID distribution. The current production entitlement set is:

```xml
<key>com.apple.security.virtualization</key>
<true/>
```

Restricted capabilities must remain out of the production target until Apple
has approved the entitlement and a matching provisioning profile has been
validated in a Homebrew-installed build. A notarization success alone is not
evidence that a restricted entitlement is distributable.

## Capability matrix

### Platforms, installation, and lifecycle

| Capability | Status | Current behavior | Next work / constraint |
| --- | --- | --- | --- |
| Apple silicon host support | Stable | Production builds target arm64 Macs. | Maintain a tested host/build matrix. |
| macOS guests | Stable | Creates, installs, and runs macOS from compatible IPSW restore images. | Add more installation interruption and recovery tests. |
| ARM64 Linux guests | Stable | Creates and runs Linux VMs using supported ARM64 boot media. | Publish tested distro presets. |
| macOS restore-image catalog | Stable | Presents signed Apple restore images plus local/custom sources. | Improve cache visibility and retry behavior. |
| Local macOS IPSW installation | Stable | Validates and installs compatible local restore images. | Explain incompatibility before starting a long install. |
| CPU and memory configuration | Stable | User-configurable with framework validation. | Add recommended values and host-pressure warnings. |
| Start, pause, resume, request stop | Stable | Uses `VZVirtualMachine` lifecycle APIs with explicit state transitions. | Expand transition and stale-callback regression tests. |
| Force stop | Stable | Available with destructive-action handling. | Keep data-loss warning visible. |
| Saved machine state | Stable | Saves and restores runtime state on macOS 14 and later. | Detect disk/config divergence before restore. |
| Recovery boot for macOS | Stable | Opens a macOS VM using recovery start options. | Add an automated smoke scenario. |
| Single-owner VM lease | Stable | Prevents the same VM bundle from running twice. | Extend to future CLI/service processes. |
| Headless execution | Planned | The engine is currently window-oriented. | Separate display ownership from VM lifetime. |
| Multi-VM resource policy | Planned | Multiple machines can exist, but there is no scheduler. | Add CPU/memory pressure limits and launch warnings. |

### Virtual devices and interaction

| Capability | Status | Current behavior | Next work / constraint |
| --- | --- | --- | --- |
| macOS graphics/display | Stable | Configures native Mac graphics displays and a `VZVirtualMachineView`. | Add display-profile presets. |
| Linux Virtio graphics | Stable | Configures Virtio graphics and scanout. | Test more desktop distributions. |
| Automatic display resizing | Stable | Uses supported automatic reconfiguration APIs. | Verify save/restore and full-screen transitions. |
| Keyboard | Stable | Provides a virtual USB keyboard. | Add keyboard-layout troubleshooting. |
| Pointer and absolute pointing | Stable | Supports the configured pointing-device types. | Improve device descriptions in settings. |
| Mac trackpad | Stable | Uses the native virtual Mac trackpad where supported. | Keep availability-gated. |
| Audio output | Stable | Provides Virtio/native guest output through host audio. | Add device and permission diagnostics. |
| Audio input | Stable | Provides host microphone input when authorized. | Explain and test macOS privacy permission denial. |
| Entropy device | Stable | Linux can opt into a Virtio entropy source. | Enable in tested presets. |
| Memory balloon | Stable | Linux can use a Virtio memory-balloon device; runtime target is adjustable. | Add host-pressure-driven recommendations, not automatic mutation yet. |
| Virtio socket device | Stable | Linux configurations can expose a Virtio socket device. | Build a versioned guest-agent protocol on it. |
| Serial port terminal | Planned | Framework support exists; EasyVM lacks a dedicated terminal UX. | Add logging, reconnect, encoding, and copy support. |
| Virtio console | Partial | A console and Spice agent port are configured for Linux workflows. | Surface connection and guest-agent health. |
| Host/guest clipboard | Partial | Spice attachment exists; success depends on a guest agent. | Detect `spice-vdagent`, expose status, and test both directions. |
| Physical USB passthrough | Restricted | Removed from the production code in 3.2.14. | Requires macOS 27 Accessory Access and an approved entitlement. |
| USB hot-plug management | Restricted | Not present after USB passthrough removal. | Revisit only with the same approved distribution path. |
| Custom Virtio devices | Planned | No production device implementation exists. | Require a concrete guest-driver use case before building one. |

### Storage, snapshots, and portability

| Capability | Status | Current behavior | Next work / constraint |
| --- | --- | --- | --- |
| Raw disk images | Stable | Creates exact-size raw images without overwriting existing data. | Keep as the compatibility format. |
| ASIF disk images | Stable | Creates and attaches Apple Sparse Image Format disks on supported systems. | Make ASIF the recommended default after broader soak testing. |
| Raw-to-ASIF conversion | Stable | Converts while retaining the original raw disk as a backup. | Add progress and free-space estimates. |
| Virtio block devices | Stable | Attaches Linux block storage through Virtio. | Expose safe caching/synchronization presets. |
| Virtual USB mass storage | Stable | Supports virtual storage-device configuration; this is not physical USB passthrough. | Clarify terminology in the UI. |
| APFS clone snapshots | Stable | Creates stopped-VM snapshots using APFS clone behavior where available. | Report fallback cost when copy-on-write is unavailable. |
| Snapshot tree and branches | Stable | Tracks parent/child history, current branch, rename, protection, restore, and manifest-backed integrity audits. | Add orphan cleanup preview. |
| Restore safety snapshot | Stable | Can preserve the current state before restoring another snapshot. | Add storage estimate before the operation. |
| ASIF layered snapshots | Experimental | DiskImageKit-backed overlay stacks exist behind an experimental setting. | Validate crash recovery, compaction, and long branch chains. |
| VM clone | Stable | Stopped VMs clone transactionally with a new hardware identity and name; incompatible saved state and source snapshot history are intentionally reset. | Add progress and cancellation UI. |
| VM export/import | Stable | Native `.easyvmexport` packages use a versioned manifest, streaming SHA-256 checksums, architecture/OS compatibility checks, free-space forecasts, and transactional import. | Add progress and cancellation UI. |
| OVF/OVA import | Planned | Not implemented. | Treat as a converter project after native bundle import is stable. |
| OCI/image workflows | Backlog | Not implemented. | Require a concrete developer workflow before promotion. |

### Networking

| Capability | Status | Current behavior | Next work / constraint |
| --- | --- | --- | --- |
| Standard NAT | Stable | Production builds use `VZNATNetworkDeviceAttachment`. | Add connectivity diagnostics and tested DNS behavior. |
| Bridged networking | Restricted | Removed in 3.2.14. | Requires `com.apple.vm.networking` approval and profile validation. |
| Host-only networking | Restricted | Removed in 3.2.14; previous implementation used vmnet logical networks. | Restore only after entitlement approval. |
| Custom network topology | Restricted | Removed in 3.2.14. | Depends on vmnet and should remain an experimental branch. |
| Shared logical network across processes | Restricted | Not in production. | Requires vmnet serialization/XPC design and entitlement approval. |
| vmnet port forwarding | Restricted | Removed in 3.2.14. | Same entitlement constraint as custom networking. |
| User-space port forwarding | Planned research | Could avoid vmnet by proxying host sockets to a known guest service. | First solve guest discovery, security, lifecycle, and UDP semantics. |
| Guest IP discovery | Planned | NAT does not currently expose a reliable product-level discovery workflow. | Prefer an authenticated guest agent over log scraping. |
| One-click SSH | Planned | No automatic address/credential integration exists. | Build after guest-agent identity and IP discovery. |

### Sharing, guest integration, and automation

| Capability | Status | Current behavior | Next work / constraint |
| --- | --- | --- | --- |
| Single-directory VirtioFS | Stable | Shares selected host directories using a guest mount tag. | Improve guest-specific setup instructions. |
| Multiple-directory VirtioFS | Stable | Supports named directory collections. | Improve collision validation and editing. |
| Runtime share updates | Partial | Core framework permits share changes; UX is still restart-oriented in places. | Add explicit live/restart-required state. |
| Linux Rosetta | Stable | Configures a Rosetta directory share when available. | Add guided guest-side `binfmt_misc` setup. |
| Rosetta translation cache | Stable | Supports caching options on compatible hosts. | Measure impact and document guest requirements. |
| macOS guest provisioning | Experimental | Uses macOS 27 guest-provisioning APIs behind an opt-in setting. | Test account creation, secrets, retries, and final-system changes. |
| Linux guest agent | Planned | No EasyVM-managed agent is shipped. | Define a small authenticated protocol over Virtio Socket. |
| Guest heartbeat and readiness | Planned | Runtime state currently reflects the VM process, not guest readiness. | First guest-agent milestone. |
| Graceful guest operations | Planned | Framework request-stop exists; no richer agent command set. | Add restart, shutdown, and status after authentication. |
| Host/guest file transfer | Planned | Shared folders work, but there is no explicit transfer queue. | Build on VirtioFS or the guest agent. |
| Drag and drop | Planned | Not implemented. | Map drops to an explicit transfer destination through the agent. |
| CLI (`easyvm`) | Planned | No stable command contract exists. | Start read-only, then add bounded mutations. |
| Local API/MCP surface | Backlog | Not implemented. | Only after CLI schemas and authorization are stable. |
| Shortcuts and URL actions | Backlog | Not implemented. | Add after lifecycle commands are safe and idempotent. |

### Host hardware and framework boundaries

| Capability | Status | Current behavior | Next work / constraint |
| --- | --- | --- | --- |
| Nested virtualization | Planned | Not exposed. Apple reports support on M3 and later Macs. | Add a Linux-only availability-gated option and compatibility tests. |
| Docker/KVM inside a Linux guest | Planned research | Depends on nested virtualization and guest configuration. | Validate only after the base nested-virtualization option is stable. |
| macOS guest iCloud workflows | Planned research | Not exposed. | Review Apple account, entitlement, and distribution requirements first. |
| x86 guest execution on Apple silicon | Out of scope | Virtualization.framework virtualizes the host architecture. | Use a separate emulator such as QEMU; do not mix it into the native core. |
| General GPU passthrough | Out of scope | No general PCIe/GPU passthrough API is exposed. | Do not promise it. |
| General PCIe passthrough | Out of scope | No general device-passthrough API is exposed. | Do not promise it. |

## Delivery plan

### Milestone A — Production baseline and release confidence

**Goal:** every published build is installable through Homebrew and can launch
and start a basic NAT VM without Xcode.

Work:

1. Add a release smoke script that installs the exact Homebrew artifact.
2. Verify Developer ID signature, notarization, and the exact entitlement set.
3. Assert the app reaches SwiftUI rather than remaining in `_dyld_start`.
4. Start one prepared ARM64 Linux smoke VM and wait for a deterministic signal.
5. Validate a saved-state close/reopen cycle.
6. Export diagnostics automatically on failure.
7. Record host OS build, Xcode build, app version, and artifact SHA-256.

Exit criteria:

- All unit tests and the unsigned Release build pass.
- A quarantined Homebrew install passes Gatekeeper.
- The installed app launches on each supported host in the compatibility matrix.
- A prepared NAT VM reaches the expected boot/readiness signal.
- The production entitlement allowlist contains only approved entries.

### Milestone B — Storage confidence and portability

**Goal:** users can copy, protect, recover, and move VM data without manual
bundle surgery.

Work:

1. Add first-class clone with new machine identifiers and atomic destination creation.
2. Add native EasyVM export/import manifests with checksums and schema versions.
3. Add disk-space forecasts to creation, conversion, snapshot, clone, and export.
4. Add snapshot integrity audit and dry-run orphan cleanup.
5. Stress-test APFS and ASIF snapshot branches, interrupted restore, and rollback.
6. Promote ASIF layered snapshots only after recovery and compaction are proven.

Exit criteria:

- Interrupted clone/import never damages the source VM.
- Exported bundles detect truncation and incompatible host requirements.
- Snapshot audit can explain every referenced disk layer.
- Restore tests cover branches, missing files, low disk space, and forced interruption.

### Milestone C — Guest integration

**Goal:** EasyVM knows whether a guest is ready and can provide safe, explicit
integration features without privileged host networking.

Work:

1. Specify an authenticated, versioned guest-agent protocol over Virtio Socket.
2. Implement heartbeat, OS metadata, IP reporting, shutdown, and restart.
3. Add guest-agent installation instructions and packages for selected Linux distros.
4. Add one-click SSH using reported addresses, without storing plaintext credentials.
5. Add explicit file-transfer jobs with destination confirmation and progress.
6. Complete Spice clipboard health/status and bidirectional tests.
7. Add guided Linux Rosetta setup and validation.

Exit criteria:

- A stale or malicious guest cannot impersonate another VM.
- Agent absence never prevents normal VM boot.
- Every host-to-guest mutation is visible and attributable in the UI.
- Clipboard and transfer tests cover guest-agent restart and disconnect.

### Milestone D — Local automation

**Goal:** the GUI and automation share the same validated operations.

Work:

1. Extract VM inspection and lifecycle operations into a reusable service layer.
2. Introduce read-only CLI commands: `list`, `inspect`, `validate`, and `doctor`.
3. Return versioned JSON and deterministic exit codes.
4. Add `start`, `stop`, `clone`, and `delete` with timeouts and confirmation rules.
5. Add headless mode for VMs that do not require a visible display.
6. Consider a local MCP interface only after the CLI contract is stable.

Exit criteria:

- CLI and GUI produce the same validation result for the same VM.
- Destructive commands require an explicit target and never accept broad paths.
- An automated smoke workflow can clone, start, observe, stop, and remove a disposable VM.

### Milestone E — New platform capabilities

**Goal:** adopt new framework APIs without making beta features part of the
production reliability boundary.

Candidates:

1. Stabilize macOS guest provisioning after macOS 27 API behavior is final.
2. Add nested virtualization on supported M3-or-newer hosts.
3. Evaluate a specific Custom Virtio use case with a maintained guest driver.
4. Evaluate user-space TCP forwarding after guest identity and discovery exist.
5. Revisit DiskImageKit layer compaction and shared base-image workflows.

Every candidate must have an availability gate, fallback behavior, migration
story, and automated test before its experimental toggle can be removed.

## Restricted-feature re-entry checklist

Bridged networking, vmnet logical networks, vmnet port forwarding, and physical
USB passthrough may return only when all of the following are true:

1. Apple has approved the exact entitlement for the EasyVM App ID.
2. A Developer ID provisioning profile contains that entitlement.
3. The profile is embedded in the signed application.
4. `codesign` shows only expected entitlements in the final archive.
5. Notarization, Gatekeeper, and launch tests pass on a clean Homebrew install.
6. The feature has a runtime availability check and a safe fallback.
7. Removing or denying the capability does not prevent EasyVM from launching.
8. Release automation rejects an unauthorized restricted entitlement.

Until then, those features belong in design documents or isolated experimental
branches, not the production target.

## Release quality gates

Every patch release must satisfy:

- `swift test` passes.
- The arm64 Release configuration builds from fresh DerivedData.
- Restricted-capability symbols and entitlements are absent from production.
- The archive round-trip passes strict `codesign` verification.
- Apple notarization returns `Accepted`.
- Gatekeeper accepts a quarantined extraction of the published archive.
- Homebrew installs the exact published checksum.
- The Homebrew-installed process enters application code and displays its window.
- A prepared NAT VM configuration validates; scheduled release candidates also boot the smoke VM.
- The worktree and release tag identify the exact tested commit.

## Recommended priority order

1. Release smoke automation and compatibility matrix.
2. Clone plus native import/export.
3. Snapshot and saved-state integrity hardening.
4. Guest-agent protocol and readiness/IP reporting.
5. One-click SSH, file transfer, and clipboard completion.
6. Headless service and read-only CLI.
7. Nested virtualization on supported hardware.
8. Stabilize macOS 27 provisioning and DiskImageKit features.
9. Reconsider restricted network and USB features only after Apple approval.

This order favors capabilities that improve reliability and daily use without
expanding the entitlement or distribution risk of the production application.

## Primary references

- [Virtualization framework overview](https://developer.apple.com/documentation/virtualization)
- [Virtual machine configuration](https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration)
- [Virtual machine lifecycle and saved state](https://developer.apple.com/documentation/virtualization/vzvirtualmachine)
- [Installing macOS in a virtual machine](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine)
- [Shared directories](https://developer.apple.com/documentation/virtualization/shared-directories)
- [Clipboard sharing](https://developer.apple.com/documentation/virtualization/clipboard-sharing)
- [Nested virtualization support](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported)
- [WWDC26: Expand the capabilities of your Virtualization app](https://developer.apple.com/videos/play/wwdc2026/224/)
- [`com.apple.vm.networking`](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_vm_networking)
- [Accessory Access entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-access.usb)
