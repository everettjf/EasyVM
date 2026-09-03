# EZVM Omarchy product and integration plan

_Planning baseline: September 3, 2026_

## 1. Decision

EZVM Omarchy will be a new, independently installed macOS application whose
only guest product is Omarchy. It will launch directly into one persistent
Omarchy workspace and provide defaults and host integration suitable for daily
work. It is not a mode, screen, or preset inside the regular EZVM application.

The two products have separate applications, repositories, product UX, release
artifacts, and support promises:

| Product | Purpose | Primary audience |
| --- | --- | --- |
| **EZVM** | General-purpose macOS virtual machine manager for macOS and ARM64 Linux guests. | Users who need multiple configurable virtual machines. |
| **EZVM Omarchy** | Dedicated Omarchy workspace for Apple silicon Macs. | Users who want to open Omarchy and work without learning VM concepts. |

They must not develop independent copies of the virtualization, graphics,
storage, or Guest Agent implementations. Shared platform work is delivered by
EZVM Core and EZVM Integration Service; EZVM Omarchy supplies the focused
product shell, Omarchy profile, guest image policy, onboarding, and recovery
experience.

The proposed public positioning is:

> **EZVM Omarchy**  
> The Omarchy workspace for Apple silicon Macs.

The technical description is:

> Powered by Apple Virtualization.framework and EZVM Guest Integration.

Public material must make the project's independent status clear:

> EZVM Omarchy is an independent community project and is not affiliated with
> or endorsed by the Omarchy project.

The name, logo, screenshots, themes, wallpapers, and other Omarchy assets need
a separate branding and redistribution review before public release. An
open-source code license does not grant trademark or branding rights.

## 2. Product principles

1. **Open Omarchy, not a VM manager.** Normal launch goes directly to the saved
   Omarchy workspace. VM implementation terminology is kept out of the normal
   workflow.
2. **One workspace.** The application manages one primary persistent Omarchy
   environment. General multi-VM management remains in EZVM.
3. **Opinionated safe defaults.** CPU, memory, storage, graphics, input, audio,
   and sharing are selected by a versioned Omarchy profile.
4. **Mac and Omarchy muscle memory coexist.** When the VM display has keyboard
   focus, Command belongs to Omarchy as Super. When focus leaves the display,
   Command immediately returns to macOS.
5. **Integration is negotiated.** Host features are enabled only after an
   authenticated Guest Agent advertises the corresponding capability.
6. **User data survives product updates.** Updating the app or factory image
   never silently replaces the working disk.
7. **Recovery is a primary workflow.** Updates, migrations, suspend/resume,
   Agent restarts, and interrupted operations have explicit recovery behavior.
8. **No unrestricted host control.** The guest never receives a generic API to
   execute arbitrary macOS commands or read arbitrary host files.

## 3. Product boundary

### 3.1 Normal user surface

EZVM Omarchy presents only the controls needed to use and maintain Omarchy:

- Start, continue, stop, and restart Omarchy;
- windowed and immersive full-screen modes;
- keyboard integration permission and status;
- clipboard integration;
- one primary shared folder for the first release;
- audio output and optional microphone access;
- optional camera and USB access after the MVP;
- storage usage;
- updates, backup, restore, repair, and factory reset;
- an actionable integration diagnostics page.

### 3.2 Hidden implementation details

The default UI does not expose:

- a VM library or arbitrary VM creation;
- ISO, kernel, initramfs, firmware, or boot-device selection;
- graphics backend or virtual-device terminology;
- arbitrary Linux or macOS guest installation;
- advanced network topology;
- snapshot trees or low-level machine configuration.

An advanced settings screen may later expose bounded controls for CPU, memory,
disk capacity, display scale, the shared folder, and loopback-only port
forwarding. Every value remains constrained by the Omarchy profile.

## 4. Repository and shared-code strategy

Create a separate repository named `ezvm-omarchy` for the product application:

```text
ezvm-omarchy/
├── App/
│   ├── Application/
│   ├── Onboarding/
│   ├── Workspace/
│   ├── Settings/
│   ├── Diagnostics/
│   └── Recovery/
├── OmarchyProfile/
├── GuestOverlay/
│   ├── systemd/
│   ├── session-agent/
│   ├── omarchy-adapter/
│   └── packaging/
├── Resources/
├── Tests/
├── Scripts/
└── docs/
```

Proposed product identifiers:

| Item | Value |
| --- | --- |
| Application | `EZVM Omarchy.app` |
| Repository | `ezvm-omarchy` |
| Bundle identifier | `com.everettjf.ezvm.omarchy` |
| Internal product identifier | `omarchy` |
| Optional CLI | `ezvm-omarchy` |
| Application Support directory | `~/Library/Application Support/EZVM Omarchy` |

Before building substantial product UI, extract the smallest reusable seams
from EZVM. The intended package boundaries are:

```text
EZVMVirtualizationCore
EZVMGraphics
EZVMGuestIntegration
EZVMStorage
EZVMNetworking
EZVMDevices
```

Initially these packages should remain in the EZVM repository. EZVM Omarchy
can use local path dependencies during coordinated development and immutable
commit or tag dependencies in CI and releases. A separate `ezvm-core`
repository should be considered only after both applications consume stable
package APIs. Do not begin with a broad repository extraction.

The following code must never be copied into a divergent Omarchy-only version:

- Virtualization.framework lifecycle and device configuration;
- Custom VirGL protocol and renderer;
- authenticated Guest Agent framing and enrollment;
- keyboard mapping and input-event validation;
- disk, snapshot, and recovery transactions;
- networking and physical-device ownership;
- shared diagnostic and test infrastructure.

## 5. Two coordinated workstreams

The program consists of two plans with different ownership and deliverables.

### 5.1 Workstream A: EZVM Integration Service

This is product-neutral platform work shared by EZVM and EZVM Omarchy. Its goal
is a VMware Tools/Parallels Tools-style host/guest integration layer for Linux
desktops.

The current baseline already includes:

- a macOS host client and a Linux `ezvm-agent`;
- authenticated AF_VSOCK communication without a guest network port;
- per-VM enrollment, mutual authentication, replay protection, and bounded
  frames;
- heartbeat, status, shutdown, restart, and checksum-verified file transfer;
- capability-negotiated uinput keyboard, pointer, button, and wheel input;
- Command-to-Super handling on the Custom VirGL display path;
- VirtioFS, audio, dynamic display work, and an enabled SPICE clipboard path.

The target architecture separates privileged system operations from desktop
session operations:

```text
EZVM macOS host
├── Integration Controller
├── Permission and Focus Controller
└── Host adapters
    ├── Keyboard
    ├── Clipboard
    ├── Files and folders
    ├── Notifications and URLs
    ├── Audio and camera
    ├── USB
    └── Power, network, and appearance

Authenticated AF_VSOCK

Linux guest
├── ezvm-agent                 root system service
│   ├── authentication and capabilities
│   ├── system status and power
│   ├── bounded file transfer
│   └── input-device management
└── ezvm-session-agent         unprivileged user service
    ├── Wayland clipboard
    ├── desktop session state
    ├── notifications and URLs
    └── desktop-specific adapters
```

The root service must not impersonate the desktop user or directly own a
Wayland session. `ezvm-session-agent` communicates with the system service over
a narrowly scoped local IPC contract.

Candidate additive capabilities include:

- `keyboard-capture-v1`;
- `clipboard-text-v1`;
- `clipboard-image-v1`;
- `shared-folders-v1`;
- `desktop-session-v1`;
- `desktop-notifications-v1`;
- `open-host-url-v1`;
- `open-guest-path-v1`;
- `host-appearance-v1`;
- `host-power-events-v1`;
- `camera-v1`.

Capability names and payloads are not final until their threat model, limits,
ownership, cancellation, and compatibility behavior are documented.

### 5.2 Workstream B: EZVM Omarchy product

This workstream builds the separate application using Workstream A. It owns:

- the single-workspace product model;
- the Omarchy profile and compatibility matrix;
- first-run permissions and account-provisioning UX;
- factory-image acquisition and provenance;
- immersive window behavior;
- Omarchy-specific readiness and diagnostics;
- update, backup, repair, restore, and reset UX;
- branding, signing, notarization, packaging, and release communication.

It may add an unprivileged `ezvm-omarchy-adapter` for Omarchy Shell and
Hyprland integration, but it does not fork the general Guest Agent.

## 6. First vertical slice: focused Command-to-Super

The first product milestone is a reliable keyboard contract:

> While the Omarchy display is focused, Command is guest Super. Outside the
> display, the same key remains macOS Command.

The existing AppKit local monitor and `performKeyEquivalent` paths cannot
reliably receive `Command-Space` before Spotlight, Raycast, or another global
shortcut owner. Add an Accessibility-authorized, session-level `CGEventTap` at
the Host Integration layer:

```text
macOS keyboard event
        │
        ├── Omarchy display is not focused ──> unchanged macOS event
        │
        └── Omarchy display is focused
             ├── suppress the host Command chord
             ├── produce balanced Super/key transitions
             └── send through authenticated Agent/uinput input
```

EZVM should borrow the state-machine lessons from Try Omarchy's focused event
tap, but use the existing authenticated Agent input channel rather than QMP.
Any copied or substantially derived MIT-licensed implementation must retain
the required copyright and license notice.

Capture is active only when all of these conditions are true:

- EZVM Omarchy is the active application;
- its VM window is the key window;
- the VM display is the first responder;
- no alert, sheet, file picker, or modal window is active;
- no application control or settings text field owns input;
- the VM is running; and
- authenticated desktop input is ready.

All synthetic guest key state is released when the application loses focus,
the VM pauses or stops, the host sleeps, the Agent disconnects, the event tap
is disabled, or capture terminates unexpectedly. The event tap and existing
AppKit monitor must share one chord-ownership state machine so a chord is never
injected twice.

A small, documented host shortcut allowlist remains outside the guest. It
should cover only essential operations such as releasing capture, presenting
the control window, and controlling host full screen.

Acceptance requires:

1. `Command-Space` opens the Omarchy menu without opening Spotlight or Raycast
   while the display is focused.
2. The same shortcut returns to its normal macOS behavior immediately after
   focus leaves the display.
3. `Command-Return`, `Command-K`, and `Command-W` reach Omarchy.
4. Left/right Command and chords with Shift, Option, and Control remain
   balanced.
5. Losing focus while keys are held never leaves Super or another key stuck.
6. Agent restart, VM pause/resume, and host sleep/wake recover automatically.
7. Password fields, sustained typing, keyboard layouts, and macOS input methods
   pass real-guest testing.

## 7. Omarchy profile and resource policy

EZVM Omarchy uses a versioned profile instead of exposing arbitrary hardware:

```text
OmarchyProfile
├── schemaVersion
├── minimumHostVersion
├── guestArchitecture
├── minimum and recommended resources
├── disk format and capacity
├── graphics and display defaults
├── required Agent and protocol versions
├── required and optional capabilities
├── keyboard and host-shortcut policy
├── sharing and network policy
├── update policy
└── storage and boot compatibility version
```

Resource recommendations must be derived from host capacity and verified with
real workloads. They must leave macOS usable and avoid assigning all available
memory or performance cores to the guest. The supported host matrix should
include an explicitly constrained minimum-memory configuration and recommended
profiles for common 16 GB, 24/32 GB, and larger Macs.

## 8. Workspace, image, and update model

### 8.1 One persistent workspace

The application manages a versioned state directory similar to:

```text
~/Library/Application Support/EZVM Omarchy/
├── Workspace/
│   ├── Disk.asif
│   ├── Configuration.json
│   ├── MachineIdentifier
│   ├── Boot/
│   └── Snapshots/
├── Enrollment/
├── Cache/
├── Diagnostics/
└── Preferences.json
```

The initial workspace states are:

```text
notPrepared -> preparing -> needsProvisioning -> ready
ready -> starting -> running -> stopping -> ready
any state -> recovering | needsMigration | failed
```

User-facing errors describe recovery actions. Low-level Virtualization,
renderer, Agent, and filesystem details remain available in diagnostics.

### 8.2 Factory image

The ARM64 Omarchy factory must record and validate:

- Omarchy release, source commit, and source digest;
- complete Arch Linux ARM package identity;
- kernel, initramfs, boot ABI, Mesa, and graphics compatibility;
- Guest Agent, Session Agent, and Omarchy Adapter versions;
- disk logical size, encoded size, and SHA-256;
- build environment and reproducible provenance;
- third-party licenses and redistributed source obligations;
- clean-image real-guest acceptance results.

The initial release should download a signed/verified manifest and image on
first run rather than place a multi-gigabyte disk in every application update.
Downloads need a size forecast, resumable staging, cancellation, digest
verification, atomic publication, and cleanup after interruption.

### 8.3 Update layers

The product must distinguish:

1. EZVM Omarchy application updates;
2. shared EZVM Core updates;
3. Guest Agent protocol and package updates;
4. Session Agent and Omarchy Adapter updates;
5. Omarchy and ordinary Arch package updates;
6. kernel/initramfs and graphics-stack updates; and
7. new factory images.

An application or factory update never silently overwrites the working disk.
Existing disks retain a compatible boot pair. Risky guest integration or ABI
migrations create a protected snapshot first, use a versioned transaction, and
offer deterministic rollback. A new factory is used only for a new workspace
or an explicitly confirmed reset unless a preserving migration is separately
designed and validated.

## 9. Daily-work integration scope

### 9.1 Clipboard

The target is bidirectional UTF-8 text and PNG images between `NSPasteboard`
and the active Wayland user session, with bounded payloads, type allowlists,
loop prevention, expiry, reconnect behavior, and user controls.

The existing SPICE clipboard path may be completed as the first implementation,
but the product must eventually designate one authoritative clipboard path.
SPICE and Agent clipboard implementations must not race or echo each other. If
the SPICE path is not sufficiently observable and reliable for Omarchy, use an
authenticated Agent protocol with the unprivileged Session Agent.

### 9.2 Files and folders

The MVP exposes one user-selected host folder, disabled until explicit consent.
It appears under the same intuitive name in the Omarchy user's home directory.
The UI explains read/write scope and supports read-only mode if the underlying
framework path can enforce it safely.

Later work adds:

- host-to-guest drag and drop;
- guest export to a user-selected Mac destination;
- Finder "Open in Omarchy";
- guest "Show in Finder" for files inside authorized shares;
- multi-file progress, cancellation, collision handling, and reconnect;
- runtime share changes with explicit live/restart-required state.

All paths retain the existing Agent and VirtioFS safety rules. Symlinks,
authorization scope, unavailable volumes, and replacement behavior must be
handled explicitly.

### 9.3 Desktop awareness

After the MVP, add capability-gated integration for:

- guest notifications in macOS Notification Center;
- activating the VM, workspace, or application from a notification;
- opening allowlisted guest URLs in a macOS browser;
- opening host URLs or authorized files in Omarchy;
- host time zone, appearance, sleep/wake, and network-change events;
- Omarchy readiness, active workspace, focused application, update state, and
  attention indicators.

The guest is never allowed to invoke an arbitrary host executable. URL schemes,
file roots, payload sizes, rate limits, and prompts are part of each operation's
contract.

### 9.4 Audio, camera, and USB

Audio output is part of the MVP; microphone, camera, and USB are optional and
permission-gated. Prefer Virtualization.framework devices when they meet the
product requirement. Use an Agent or media bridge only for capabilities the
framework does not provide.

Camera capture should be demand-driven: a Mac camera opens only while a guest
application is consuming the virtual V4L2 device, and denial or device removal
must not prevent Omarchy from running. Microphone ownership follows the same
principle. Physical USB is never auto-attached; users explicitly select and
release a device, with stronger warnings for storage devices.

## 10. Product experience

### 10.1 First launch

```text
Welcome
  -> host compatibility and space check
  -> keyboard integration / Accessibility explanation
  -> optional shared folder and microphone choices
  -> image download and verification
  -> transactional workspace creation
  -> Omarchy owner provisioning
  -> desktop ready
```

The user sees download size, required space, recoverable progress, and clear
permission consequences. Camera and USB can remain post-MVP options and should
not block setup.

### 10.2 Normal launch

Opening the application starts or restores the primary workspace and presents
Omarchy directly. A start menu is shown only when user action or exceptional
state is required: first setup, missing external storage, migration consent,
recovery, or diagnostics.

### 10.3 Control surface

The compact control surface contains:

```text
Omarchy
├── Start / Stop / Restart
├── Window / Full Screen
├── Keyboard Integration
├── Clipboard
├── Shared Folder
├── Audio / Microphone
├── Camera / USB Devices
├── Storage
├── Backup and Restore
├── Updates
└── Diagnostics
```

### 10.4 Diagnostics

Diagnostics should report actionable capability state without requiring logs:

| Area | Example states |
| --- | --- |
| Virtual machine | Starting, Ready, Paused, Recovery required |
| Graphics | Apple Virtio, Custom VirGL/Metal, fallback |
| Guest Agent | Not installed, Enrolling, Authenticated, Incompatible |
| Desktop session | Logged out, Starting, Ready, Restarting |
| Keyboard | Full, Accessibility required, Agent input unavailable |
| Clipboard | Connected, Disabled, Session unavailable |
| Shared folder | Mounted, Restart required, Host volume unavailable |
| Network | Connected, DNS failure, address unavailable |
| Media/devices | Available, Permission required, In use, Disconnected |

Every degraded state offers the safest relevant action, such as opening System
Settings, restarting integration, reconnecting a share, creating diagnostics,
or entering recovery. Enrollment secrets and guest clipboard/file contents are
never included in diagnostic bundles.

## 11. Milestones

### M0 — Architecture and new-project skeleton

Deliverables:

- create the `ezvm-omarchy` repository and signed macOS application target;
- establish the identifiers and independent data directory;
- define the first shared EZVM package seam;
- launch a minimal fixed Linux configuration through shared code;
- establish CI, test, notices, and artifact provenance scaffolding;
- complete the preliminary brand and redistribution review.

Exit gate: the new application launches through shared EZVM code without a
copied virtualization implementation or changes to a user's normal EZVM data.

### M1 — Omarchy workspace bootstrap

Deliverables:

- versioned Omarchy profile;
- manifest-backed factory-image download and validation;
- transactional creation of one persistent workspace;
- start, stop, restart, and basic failure UI;
- first-owner provisioning and desktop readiness.

Exit gate: a clean supported Mac can go from app installation to Omarchy
provisioning, and subsequent launches return to the same desktop and data.

### M2 — Complete focused keyboard

Deliverables:

- Accessibility onboarding and repair guidance;
- focus-scoped `CGEventTap`;
- unified host/guest chord ownership and release state machine;
- essential host shortcut allowlist;
- Agent and desktop-readiness diagnostics;
- unit, integration, and clean-guest acceptance tests.

Exit gate: all keyboard acceptance criteria in section 6 pass repeatedly across
window, full-screen, focus, pause/resume, Agent restart, and sleep/wake paths.

### M3 — Daily-work MVP

Deliverables:

- unprivileged Session Agent;
- bidirectional text and PNG clipboard;
- one managed shared folder;
- file import/export and basic drag and drop;
- dynamic window/full-screen resolution and Retina behavior;
- stable audio output and optional microphone;
- compact control surface and integration diagnostics.

Exit gate: a user can complete sustained browser, terminal, editor, Git/SSH,
clipboard, and file-sharing work without opening general VM configuration.

### M4 — Safe update and recovery

Deliverables:

- protected pre-update snapshots;
- versioned Agent and workspace migration;
- repair, rollback, restore, and confirmed factory reset;
- application/factory/guest update separation;
- interrupted-operation fault injection;
- storage forecasting and low-space recovery.

Exit gate: every supported update either commits completely or leaves the prior
workspace bootable, and a user can identify and invoke the appropriate recovery
action without manual disk surgery.

### M5 — Deep desktop integration

Deliverables:

- notifications and attention state;
- allowlisted URL and authorized-file handoff;
- host appearance, time zone, power, and network events;
- demand-driven camera bridge where needed;
- explicit USB attachment;
- multi-display and cross-scale hardening.

Exit gate: each integration is capability-gated, independently disableable,
permission-correct, recoverable after device/session changes, and covered by a
real-guest scenario.

### M6 — Daily Driver Beta

Required evidence:

- multi-day continuous operation;
- repeated Mac sleep/wake and VM pause/resume;
- Wi-Fi and external-display changes;
- Omarchy Shell, compositor, Session Agent, and system Agent restarts;
- App and Omarchy updates with preserved workspace data;
- representative development, browser, media, and video-call workflows;
- bounded host CPU/memory use and documented performance baselines;
- complete diagnostic and support-bundle behavior.

### M7 — 1.0

Release gates:

- Developer ID signing and strict code-sign verification;
- notarization, stapling, quarantine, and Gatekeeper acceptance;
- clean install, update install, relaunch, and uninstall-data explanation;
- signed-artifact clean-image acceptance on the supported host matrix;
- dependency licenses, notices, source obligations, and image provenance;
- Guest Agent compatibility matrix and update rollback;
- release publication and previous-version rollback procedure;
- documented backup, repair, restore, reset, and support flows.

Release automation must reject promotion unless a fresh real-guest evidence
record is cryptographically bound by SHA-256 to the exact App archive, signed
factory manifest, factory image, and full source revision being released. The
record must enumerate every required scenario rather than relying on a single
aggregate pass flag. `scripts/verify-omarchy-release-evidence.sh` defines this
machine-enforced boundary; CI tests its positive and tamper-rejection paths.
`scripts/publish-omarchy-release.sh prepare <version>` creates, signs, notarizes,
and Gatekeeper-tests one immutable candidate in a versioned state directory.
Real-guest acceptance runs against that exact ZIP. A later
`publish <version> <evidence> <manifest> <image>` invocation reuses the same
checksum-verified bytes, validates the bound evidence, and only then pushes the
release branch/tag and creates the GitHub release. Omarchy Edition tags use the
separate `ezvm-omarchy-v<version>` namespace.

Acceptance-mode launches (`EZVM_OMARCHY_ACCEPTANCE=1`) also write an atomic
`Diagnostics/integration-readiness.json` observation after the authenticated
Guest Agent reports an active desktop, completed provisioning, and every
profile-required capability. The observation binds those live facts to the App
source revision, factory-image version, Omarchy revision, and Guest Agent
version. `scripts/verify-omarchy-integration-observation.sh` rejects stale,
version-mismatched, incomplete, or internally inconsistent observations; its
positive and tamper-rejection cases run in CI. This is machine evidence for the
integration-ready checkpoint only. It deliberately does not claim that input,
clipboard, shared-folder, sleep/wake, rollback, or 24-hour scenarios completed;
those remain separate real actions in the release evidence record.

## 12. Test and measurement strategy

### 12.1 Unit and protocol tests

- Command/Super state transitions, left/right modifiers, repeats, and focus loss;
- capability negotiation and backward compatibility;
- Agent/Session Agent local authorization;
- clipboard type, size, fingerprint, echo, and expiry behavior;
- URL schemes, paths, file collisions, and symbolic-link rejection;
- profile validation and resource recommendations;
- image manifests, workspace migrations, and recovery transactions.

### 12.2 Integration tests

- Host/Agent authentication and enrollment isolation;
- Agent, session, compositor, guest, and host restart behavior;
- clipboard and file round trips;
- shared-folder mount, unmount, host-volume loss, and permissions;
- dynamic resolution and full-screen transitions;
- audio device switching and microphone lifecycle;
- camera demand and USB attach/detach;
- update interruption at every mutation boundary.

### 12.3 Clean real-guest journeys

Every release candidate must rebuild or acquire the declared factory image and
verify at least:

- first-owner provisioning;
- continuous typing and modified characters;
- `Command-Space`, `Command-Return`, `Command-K`, and focus return to macOS;
- browser, terminal, editor, Git, SSH, clipboard, and file workflows;
- window, full-screen, Retina, and external-display behavior;
- network, DNS, TLS, and Omarchy update behavior;
- audio and, when promoted, microphone/camera/USB;
- sleep/wake, restart, clean shutdown, snapshot, update, and rollback.

### 12.4 Comparative performance

Do not claim performance superiority over Try Omarchy, QEMU, UTM, Parallels,
or VMware without a repeatable same-host comparison. Fix guest image, vCPU,
memory, resolution, scale, window mode, workload, and capture duration. Record
startup time, idle CPU, memory, frame cadence, presentation time, input latency,
clipboard latency, audio xruns, and recovery time.

## 13. Delivery order

Use vertical slices rather than completing all platform work before starting
the product:

1. Define the shared Core API and create the independent project skeleton.
2. Boot the existing verified Omarchy image as one persistent workspace.
3. Deliver focus-scoped Command-to-Super, including `Command-Space`.
4. Add Session Agent, text/PNG clipboard, and the primary shared folder.
5. Complete dynamic display, audio, diagnostics, and daily-work acceptance.
6. Add protected updates, migrations, repair, restore, and reset.
7. Add notifications, URL/file handoff, camera, USB, and deeper awareness.
8. Run multi-day Daily Driver Beta and signed-artifact release gates.

The first engineering proof is intentionally small:

```text
Open EZVM Omarchy
  -> prepare or locate the workspace
  -> start through shared EZVM Core
  -> reach the Omarchy desktop
  -> Command-Space opens the Omarchy menu
  -> stop cleanly with the workspace preserved
```

## 14. Definition of success

EZVM Omarchy succeeds when a user can install one application, complete the
Omarchy owner flow, and use Omarchy for sustained daily work without learning
virtual machine concepts. Keyboard, clipboard, files, display, audio, network,
updates, sleep/wake, and recovery must behave as coherent product features, not
as unrelated VM devices.

The program succeeds architecturally when the same integration improvements
also strengthen regular EZVM, and neither application maintains a divergent
copy of the shared virtualization, graphics, Guest Agent, storage, or device
code.
