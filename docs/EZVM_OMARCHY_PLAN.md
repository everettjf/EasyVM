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

Owner creation is a native EZVM Omarchy form rather than simulated typing into
the Guest console. The app keeps both password fields only in its live SwiftUI
state, validates the same username, keyboard, hostname, time-zone, and length
constraints as the image, then sends one authenticated `ownerProvisioning`
request over vsock. The system Agent atomically stages a mode-0600 request in
`/run`; the patched Omarchy first-boot flow consumes and deletes it before
calling Omarchy's existing owner setup functions. The capability is advertised
only while provisioning is pending and is required by factory manifests, but is
deliberately excluded from steady-state desktop readiness after first boot.
Older images without the capability retain their interactive console flow.

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
`publish <version> <evidence> <manifest> <image> <integration-observation>
<lifecycle-observation> <command-super-observation> <rollback-observation>
<full-screen-observation> <desktop-notification-observation> <soak-observation>`
invocation reuses the same
checksum-verified bytes,
validates the bound evidence, and only then pushes the release branch/tag and
creates the GitHub release. The schema-7 release record contains SHA-256 digests
of all seven structured observations. Promotion therefore fails if either the live
clipboard/display/shared-folder result or the lock-to-active recovery result is
missing, stale, version-mismatched, or changed after acceptance. The schema-5
lifecycle observation also records the ordered VM pause request, framework
pause completion, framework resume completion, and authenticated desktop
recovery; authenticated Agent restart with an unchanged Linux boot ID and a new
Agent instance ID; Guest restart with a changed Linux boot ID; and finally Host
sleep, Host wake, and authenticated desktop recovery after wake. The release
verifier rejects missing, reordered, or identity-inconsistent transitions, so
none of these recovery scenarios relies on a hand-authored boolean.
The lifecycle's observed provisioning-pending-to-active transition also replaces
the former `ownerProvisioning` assertion. Text and PNG clipboard checks and the
file-import check are bound to content digests in the integration observation,
so those former scenario booleans are removed as well. Focused Command+Space is
also no longer a hand-authored scenario flag: acceptance posts a complete
Command+Space down/up pair only after the signed App has an active desktop and
the VM display is focused. The session event tap must intercept both transitions,
repost them to the VM process, and leave both the App and VM window focused before
`Diagnostics/command-super.json` is written. Promotion rejects a missing, stale,
altered, unfocused, or source-revision-mismatched observation.
The lock transition is actively exercised in an isolated acceptance launch.
After display integration passes, the Host injects Super+Control+L through the
authenticated input channel, waits for the Agent to report an inactive desktop,
submits the ephemeral `EZVM_OMARCHY_ACCEPTANCE_UNLOCK_PASSWORD` without logging
or persisting it, waits for the desktop to become active again, and only then
continues to pause/resume and restart recovery. Production launches never read
or use this acceptance-only secret. Acceptance fails closed before later
lifecycle probes when the secret is absent, contains non-printable/non-ASCII
input, or exceeds 128 bytes; it never silently skips the lock transition.
Full-screen behavior is derived from AppKit lifecycle notifications rather than
a manual assertion. After the authenticated desktop becomes active, acceptance
mode asks the actual VM window to enter full screen, waits for
`didEnterFullScreen`, exits it, waits for `didExitFullScreen`, restores the VM
view as first responder, and writes `Diagnostics/full-screen.json`. Promotion
requires ordered entry/exit timestamps plus an active App, key VM window, and
focused VM view after exit, all bound to the exact source revision.
Notification acceptance is derived from the live Guest path as well. After the
user explicitly enables notification mirroring, acceptance mode lets the first
Agent poll establish a baseline, opens an Omarchy terminal through authenticated
desktop input, runs `notify-send`, and waits for that exact generated title to
cross the Session Agent boundary. `Diagnostics/desktop-notification.json` is
written only after macOS Notification Center accepts the corresponding request.
The standalone and release verifiers require the current source revision, a
fresh timestamp, a Guest boot and notification identity, and the constrained
acceptance title; unrelated or edited notifications cannot satisfy the gate.
Update rollback is derived in the same way. With the VM stopped, the restricted
`omarchy-rollback-acceptance-tool` accepts only a temporary acceptance workspace,
writes a random pre-update marker into the real VM bundle, creates a protected
pre-update recovery point through `VMOmarchyRecoveryManager`, changes the marker,
restores the recovery point transactionally, and verifies the exact pre-update
bytes and a ready workspace. `Diagnostics/update-rollback.json` records three
distinct content digests and the committed recovery-point identity; promotion
rejects a hand-authored `updateRollback` flag or any altered observation.
The final legacy boolean, `continuousOperation`, is replaced by
`omarchy-soak-acceptance-tool`. While the signed App and Guest remain running,
the App atomically refreshes `Diagnostics/soak-heartbeat.json` from authenticated
Agent status. The monitor requires an unchanged Linux boot ID, Agent instance
and Agent version, monotonically increasing Guest uptime, continuously active
desktop, completed provisioning, and no heartbeat gap above 120 seconds. Only a
real interval of at least 86,400 seconds with at least one independent sample per
120 seconds produces `soak-observation.json`; schema-7 promotion binds its digest
and rejects all legacy hand-authored scenario flags.
`cleanInstall` is also derived rather than asserted: the verifier requires the
transactional workspace `createdAt` to fall inside the acceptance interval,
the first provisioning-pending observation to follow workspace creation, and
the integration-ready observation to complete before the acceptance interval
ends.
The shared-folder scenario is likewise proven by the integration observation's
bidirectional content-digest round trip and is therefore not duplicated as a
manually asserted release-evidence boolean.
Omarchy Edition tags use the separate
`ezvm-omarchy-v<version>` namespace.

Acceptance-mode launches (`EZVM_OMARCHY_ACCEPTANCE=1`) also write an atomic
schema-5 `Diagnostics/integration-readiness.json` observation after the authenticated
Guest Agent reports an active desktop, completed provisioning, and every
profile-required capability. Capability booleans explicitly mean “advertised,”
not “round trip proven.” The observation binds those live facts to the App
source revision, factory-image version, Omarchy revision, and Guest Agent
version. In acceptance mode the Host also writes a random marker through
VirtioFS, downloads it through the authenticated Agent, uploads a different
random marker through the Agent, and verifies it on the Host. The report records
both content digests only after this bidirectional round trip passes. It then
creates a separate random source under diagnostics, invokes the same atomic
`VMOmarchySharedFolderImporter` used by drag-and-drop and the file picker, and
downloads the imported destination through the authenticated Agent. A fresh
timestamp and content digest are recorded only when the Guest reads back the
exact source bytes; `fileImport` is therefore not a hand-authored release flag.
The acceptance sequence then
opens a Guest terminal through the authenticated uinput device and runs an
isolated shared-folder script that proves UTF-8 text and PNG in both directions
through the actual `NSPasteboard`/SPICE/Wayland clipboard path. Four additional
content digests are recorded only after those transfers match byte-for-byte.
Finally, the Host resizes the VM window, measures the display view in Retina
backing pixels, and compares it with Hyprland's live monitor dimensions before
and after the change. Display evidence is recorded only when the Guest changes
resolution and exactly matches the Host backing surface.
`scripts/verify-omarchy-integration-observation.sh` rejects stale,
version-mismatched, incomplete, or internally inconsistent observations; its
positive and tamper-rejection cases run in CI. This is machine evidence for the
integration-ready checkpoint only. It deliberately does not claim that focused
Command capture, full-screen transitions, sleep/wake, rollback, or 24-hour
scenarios completed; those remain separate real actions in the release evidence
record.

### 11.1 Shared-folder real-guest checkpoint (2026-09-03)

The draft `ezvm-omarchy-integration-20260903.5` image exposed two defects that
unit and image-assembly tests had not caught: the Agent reported the placeholder
version `image`, and `ProtectSystem=strict` made `/mnt/ezvm-shared` read-only in
the system Agent's mount namespace. The acceptance probe correctly rejected the
candidate with `sharedFolderRoundTripPassed=false` and the strict validator
rejected the wrong Agent version.

The corrected draft `ezvm-omarchy-integration-20260903.6` completed the full
image CI, release-asset digest verification, 64 GiB raw reconstruction, signed
factory conversion, clean-workspace preparation, first-owner provisioning, and
Hyprland startup. Its live schema-2 observation passed the strict validator with:

- App source and Guest Agent revision
  `0ac3580464d532d58798b69071980f834e06219a`;
- `desktopSessionActive=true` and `provisioningPending=false`;
- text/image clipboard and dynamic-display capabilities advertised;
- `sharedFolderRoundTripPassed=true`;
- distinct recorded SHA-256 digests for Host-to-Guest and Guest-to-Host marker
  transfers, with all temporary markers removed afterward.

This closes only the shared-folder integration checkpoint. Clipboard payloads,
keyboard capture, display resizing, lifecycle recovery, and soak scenarios still
require their own real-guest evidence.

### 11.2 Clipboard real-guest checkpoint (2026-09-03)

The exact `.6` workspace was retested with App source revision
`f8cc79444b70a0914272b0a81703a78be3bcbe58`. The first attempts exposed three
real automation defects that capability-only tests could not see: a literal
`(nonce)` path caused by missing Swift interpolation, a locked desktop being
reported as active, and libinput dropping an unrealistically fast burst of
batched character transitions. The acceptance path now uses a random directory,
waits until owner provisioning is complete and the desktop is active before
starting desktop probes, uses complete per-character evdev reports with pacing,
and applies a bounded SPICE propagation window. Lock recovery is recorded
independently so a first-run TTY cannot be mistaken for a locked desktop.

The final schema-3 observation passed the strict validator and recorded:

- Host-to-Guest UTF-8 text SHA-256
  `56576eff2eff7567b83ad5360b9811bcb897c6df6d4a1a9210bf0860d343eb8c`;
- Guest-to-Host UTF-8 text SHA-256
  `4a714354ce6888ce0bf26e5a0456294adea3dbcbc6c19c687b5aadc198221630`;
- matching Host-to-Guest and Guest-to-Host PNG SHA-256
  `535f3019bc845f4ad326f1e4ada85c78ea641fb8832c2420ad5cf29956012aab`;
- `clipboardRoundTripPassed=true`, alongside the already proven writable
  shared-folder round trip.

The probe restored the prior macOS pasteboard and removed all Guest/Host marker
files after completion. This closes the bidirectional text/PNG clipboard
checkpoint. The locked-session readiness signal remains tracked for correction
in the lifecycle/recovery phase rather than being treated as a successful
interactive desktop.

### 11.3 Dynamic-display real-guest checkpoint (2026-09-03)

The exact `.6` workspace was retested with App source revision
`2126bc4a4ff530ee1df17f3e5d34ecf793a7bb88`. Real execution first exposed a
phase race: the Host began typing the display probe before the preceding Guest
clipboard script had returned to its shell prompt. A Guest-written completion
marker now synchronizes the two acceptance phases. The next run exposed a
measurement-unit error: Hyprland reported physical display pixels while AppKit
reported logical points. The Host now uses the VM view's Retina backing size.

The final schema-4 observation passed the strict validator and recorded:

- Guest display before resize: `2200x1216` pixels;
- Guest display after resize: `1760x1320` pixels;
- Host VM backing view after resize: `1760x1320` pixels;
- `dynamicDisplayRoundTripPassed=true`, together with fresh shared-folder and
  bidirectional text/PNG clipboard results.

All randomly named acceptance directories were removed afterward. This closes
the windowed dynamic-resolution and Retina-mapping checkpoint. Repeated resize,
full-screen, multi-Space, sleep/wake, and long-running display recovery remain
part of lifecycle and soak acceptance.

### 11.4 Native owner-provisioning implementation checkpoint (2026-09-03)

The Host protocol, strict Linux Agent staging endpoint, dedicated SwiftUI owner
form, factory capability contract, and image-side one-shot consumer are now
implemented on the integration branches. Unit tests cover valid Unicode
credentials, password confirmation and erasure, reserved users, unknown or
trailing JSON, unsafe fields, request file mode/symlink rejection, one-time
deletion, and the transient-versus-steady capability boundary. The main
image-source verifier also requires the consumer to be present and integrated
by the image builder. This checkpoint is implementation evidence only; it is
not complete until a newly built candidate performs owner creation from the Mac
form and reaches an authenticated active Hyprland session without console input.
Real-guest automation may provide the existing acceptance-only unlock password
to the same native state machine. That shortcut is enabled only when the app is
explicitly in acceptance mode and its application-support root resolves beneath
`/tmp`; ordinary launches never read an automated owner credential. This lets a
clean-image journey prove the authenticated operation without UI password
injection while preserving the manual product form as the normal path.

### 11.5 Clipboard ownership and Accessibility correction checkpoint (2026-09-04)

Later real-guest testing invalidated one assumption behind checkpoint 11.2:
successfully starting `wl-copy` does not prove that the compositor accepted and
now serves the requested selection. The Linux Session Agent now writes through
an OS pipe, reads the selection back through `wl-paste`, compares the exact
bytes, and retries a bounded number of times before rejecting the Host request.
Tests cover delayed ownership and persistent mismatches. The acceptance probe
also publishes Guest text and PNG payloads through stdin, matching the proven
Wayland path. Linux unit tests, the AArch64 cross-build, all 34 macOS tests, and
the two-job Host CI run `33857119051` pass at source revision
`a8888daab0065ce15b71f7eff375b63b7b6a90d1`.

The Accessibility banner had a separate lifecycle race: it can be rendered
before the VM view creates its keyboard bridge, so the original optional call
silently did nothing. The action now requests trust and opens the Accessibility
privacy pane even before that bridge exists; once the bridge is available it
continues polling and enables focused capture normally. Existing real-guest
evidence proves that the authorized event tap receives a focused
`Command-Space` down/up pair without leaking the chord to macOS.

These corrections supersede the claim that the clipboard checkpoint is fully
closed. Source behavior and automated tests are complete, but final clipboard
acceptance remains open until a newly built factory containing Guest Agent
revision `b36e312597a2e53c92e0fc80f64d0622c8c2758c` passes fresh-workspace text
and PNG round trips in both directions. The candidate build is currently gated
by an inconsistent signed Arch Linux ARM repository graph, so the same release
tag must be retried only after the official repository publishes mutually
compatible Hyprland and Aquamarine packages.

### 11.6 `.28` factory and real-guest checkpoint (2026-09-04)

The repository-graph blockage described in checkpoint 11.5 is no longer
current. Image workflow `33887520897` completed successfully and published the
draft `v4.0.0-alpha-ezvm.28` assets. Every asset matched the release
`SHA256SUMS`; reconstructing the split raw image produced SHA-256
`83b92ceb2398acbf3c6b199204e1815ce474bf9f6f7736972733fb1b0c52a2f2`.
The factory conversion then passed manifest signature verification and an exact
raw-to-ASIF byte comparison. Its ASIF SHA-256 is
`7fcba48e8bcc51244fc812028f6fa0adbeae463dd0d86cc8ef5074e2fd0b56ff`.
The image declares Guest Agent source revision
`22fd96505cf4f426f6359996e7b64b217b034d8e`.

An isolated workspace created from that factory reached the provisioned
Hyprland desktop and produced fresh live evidence for:

- authenticated Guest Agent readiness and a writable VirtioFS round trip;
- bidirectional UTF-8 text and PNG clipboard payloads;
- dynamic display movement from `2200x1104` to `1760x1320`, with the latter
  exactly matching the Host VM view's Retina backing size;
- an authorized, focused Accessibility event tap receiving the synthetic
  `Command-Space` down/up pair while the VM window was key.

This checkpoint does **not** close keyboard or lifecycle acceptance. Guest
diagnostics prove Hyprland 0.56.1 exposes the expected `SUPER+CTRL+L` lock bind
and recognizes `EZVM Keyboard`, but two attempted lock probes reached their
ready marker without observing a `hyprlock` process. The first probe used the
authenticated uinput endpoint; the second posted a key carrying modifier flags
through the Host event tap. The acceptance implementation at Host revision
`d0b6327e62273e2038b85bc5062c999486e8e75e` now emits balanced physical
Command/Control/key transitions with pacing, refreshes Accessibility state on
activation, and treats an absent Wayland clipboard owner as an idle read rather
than a per-second error log. Unit and native App tests pass, but this revised
path still requires a single-instance real-guest run before the lock/unlock,
pause/resume, Agent restart, Guest restart, and full-screen lifecycle gate can
be considered complete.

### 11.7 `.31.2` release-candidate checkpoint (2026-09-04)

Image workflow `33901210922` completed successfully and published the draft
`v4.0.0-alpha-ezvm.31` image assets. Every downloaded part matched the signed
`SHA256SUMS`; reconstructing the split raw image produced SHA-256
`05001d32709b0c1b295ff18ecf1f9e256dbddbc830afb4eb70f3b1a41deadbc5`.
The signed Factory passed manifest verification and an exact raw-to-ASIF byte
comparison. It pins Omarchy revision
`f38d909b38e4fc34d1853daf11039e2fbb96ead7` and Guest Agent revision
`0eccc06cbde3a0f589a4032ab44440cf3c6fd1cf`.

A clean workspace created from that Factory was exercised with the signed
`1.0.0-alpha.31.2` App built from Host revision
`6fe5b05ec54e1b2e9795b179864438424eb31e72`. The live, machine-generated
observations and strict validators prove:

- first-owner provisioning reached an authenticated active Hyprland session;
- writable shared-folder and file-import round trips returned the exact bytes;
- UTF-8 text and PNG crossed both clipboard directions byte-for-byte using the
  advertised Agent clipboard capabilities;
- the Guest display moved from `2200x1200` to `1760x1416`, exactly matching the
  Host VM view's Retina backing size;
- the focused Accessibility event tap received balanced `Command-Space`
  down/up events while the Omarchy window was key;
- the session completed a real lock/unlock cycle, pause/resume, an Agent restart
  with the same boot ID and a new Agent instance ID, and a Guest restart with a
  new boot ID followed by automatic owner unlock;
- full-screen entry and exit were observed and keyboard focus was restored;
- the rollback acceptance tool protected a snapshot, mutated the workspace,
  restored it, and verified that the restored workspace SHA-256 exactly matched
  its pre-update value.

The final Host CI run `33903834434` passed at that exact revision. Local final
regression runs passed all 370 Swift Package tests (one environment-dependent
test skipped) and all 42 dedicated App Xcode tests. The signed App contains the
new pixel-rally `AppIcon.icns`; replacing an already installed development copy
is intentionally separate from producing and verifying the candidate.

This checkpoint closes the clean-factory, owner-provisioning, integration,
focused `Command-Space`, core lifecycle, full-screen, and rollback gates for the
first Alpha candidate. It deliberately leaves two release-quality endurance
gates open: a real macOS sleep/wake cycle and a continuous 24-hour soak. The
lifecycle and release-evidence validators continue to reject a candidate that
does not contain fresh evidence for those actions; neither gate may be replaced
by a synthetic notification or shortened timer.

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
