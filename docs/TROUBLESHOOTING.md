# EZVM troubleshooting and hard-won lessons

_Updated: September 1, 2026_

This guide records failures found while bringing Omarchy from bootable to
usable on EZVM. Start with the symptom, preserve the first useful log, and
avoid changing the host, guest image, display backend, and Agent at the same
time.

## First identify the active path

Before debugging, record the host macOS version, guest OS/image version, EZVM
version, CPU/memory allocation, and whether the VM is using Custom VirGL or
Apple graphics.

| Host and guest | Expected graphics path |
| --- | --- |
| macOS 27+, Linux | Custom Virtio GPU with VirGL/ANGLE; Apple Virtio fallback on startup failure |
| macOS 26, Linux | Apple Virtio graphics compatibility path |
| macOS guest | Apple native Mac graphics path |

The EZVM deployment target remains macOS 26. A macOS 26 success does not test
Custom VirGL, and a macOS 27 Custom VirGL fix must not silently remove the
Apple compatibility path.

Run `ezvm doctor` and `ezvm validate "/path/to/Machine.ezvm"` before modifying
a machine. Do not attach disks or logs containing credentials to a bug report.

## App runs but no Control Center appears

A PID, valid signature, successful notarization, and Gatekeeper acceptance do
not prove that a SwiftUI window is visible. The app can restore the persisted
state in which all windows were closed.

- Click the app again or use the normal reopen action; do not assume the first
  process launch created a window.
- During release testing, reject an already-running EZVM, launch the exact
  quarantined candidate through Launch Services, send reopen/activate, and
  require a visible window of at least 800x600 with a responsive event loop.
- A process-only smoke test is insufficient and must not replace GUI readiness.

## Keyboard input is missing, delayed, or appears after mouse movement

This symptom previously combined several distinct problems: the VM view did
not own focus, Agent input was sent before authenticated desktop ownership, and
rendering did not wake promptly after input changed the guest surface.

- Click once inside the guest and retry ordinary text before changing settings.
- Confirm the guest Agent is authenticated and its desktop input capability is
  ready. A connected socket alone is not desktop readiness.
- Keep boot/setup input and compositor-owned desktop input as separate states.
  Do not route both paths simultaneously; duplicate ownership causes missing or
  repeated keys.
- Test sustained typing, Return, password fields, Shift-modified characters,
  and input immediately after login—not only a single key on the setup screen.
- If characters become visible only after pointer movement, investigate render
  wakeup/frame scheduling as well as keyboard delivery.

## Command-to-Super shortcuts do nothing

macOS Command must be translated to the Linux Super key on the authenticated
desktop path. Host menu shortcuts and focus handling can consume the chord
before it reaches the guest.

- Test both `Command-K` and `Command-Space` after Hyprland is fully ready.
- Verify key-down and key-up ordering; a stuck modifier can make later input
  look unrelated and broken.
- Do not infer shortcut support from ordinary typing.

## Pointer capture or scrolling feels wrong

EZVM prefers the native USB digitizer and uses capability-negotiated Agent
input where desktop delivery is required. Pointer release, absolute movement,
and wheel deltas are separate behaviors.

- Verify that the pointer can enter and leave the VM before tuning scroll.
- Preserve high-resolution trackpad deltas, but accumulate and clamp them into
  guest wheel steps. Sending every macOS delta as a Linux notch can jump
  hundreds of lines.
- Test a browser and a terminal/list view. One application can mask a scaling
  or compositor issue.

## Full screen is stretched, oversized, or surrounded by black bars

Resizing the host view is not the same as changing the guest mode. Custom
VirGL must publish a generation-tagged mode and retain the display event until
the guest acknowledges it through display-info/EDID handling.

- Test window resize completion, enter full screen, exit full screen, and
  repeated transitions.
- Keep aspect ratio while a new guest mode is pending; never fill the host view
  by stretching the previous framebuffer.
- A large password box is often the old guest resolution scaled into a new host
  rectangle, not a login-screen layout bug.
- Confirm the compositor selected the announced mode rather than judging only
  the outer macOS window size.

## First-run setup loops between keyboard and time zone

The Omarchy first-run UI depends on more than key delivery. Time-zone selection
requires a working desktop D-Bus/session environment, and display/input helpers
may start before the compositor and devices are truly ready.

- Use the matched EZVM and guest-image/Agent versions.
- Retry helpers on real compositor/device readiness instead of using a fixed
  sleep as proof of readiness.
- Validate the entire flow from keyboard and user name through time zone,
  password, login, and the real Hyprland desktop. Passing the splash screen is
  not acceptance.

## Login succeeds and then the screen turns black

First distinguish a running guest with a missing frame from a stopped or
failed VM. Check VM state and logs before force-stopping it.

- A corrupt or incompatible saved state must fall back to a cold EFI boot.
- Custom VirGL does not support Virtualization.framework machine-state
  save/restore: restored RAM cannot reconstruct renderer contexts/resources.
  Use stopped-VM file snapshots instead.
- Test cold boot, clean shutdown, SIGKILL recovery, corrupt saved-state
  fallback, and a second boot. A one-time successful login is not enough.

## Repeated Keychain prompts

Changing signatures, identities, bundle locations, or ad-hoc development
builds can invalidate Keychain access expectations. Repeatedly clicking Allow
does not make an unstable identity suitable for automation.

- Test the exact Developer ID signed candidate that will be released.
- Keep Agent enrollment files mode `0600` and use a disposable VM clone for
  automated authentication/file-transfer tests.
- Do not weaken authentication or store a test password in source to avoid a
  prompt.

## Image import, disk size, and macOS compatibility

The public preinstalled-image manifest describes a decoded bootable ARM64 raw
disk. Its logical size and decoded SHA-256 are part of the product contract.
The 64 GiB disk is sparse: logical capacity is not the same as download or
physical host usage.

- Never confuse a local build artifact with the public GitHub image source.
- Verify every downloaded part, the complete compressed stream, decoded image
  hash, and logical size before import.
- Install transactionally so interruption cannot leave a machine that appears
  valid but contains a partial disk.
- macOS 26 and 27 do not require different Omarchy images merely because their
  host graphics backends differ. Guest changes must remain compatible with the
  Apple Virtio path unless the manifest explicitly says otherwise.

## Guest has no internet access

Graphics success does not imply networking success. The normal production
path is Virtualization.framework NAT.

- Test IP assignment, DNS, TLS, and an actual package-manager request; ping
  alone is not sufficient.
- Record whether failure is name resolution, routing, certificate/time, or the
  upstream repository.
- Bridged and custom vmnet modes are not a fallback in the normal Developer ID
  release because their entitlement/distribution constraints differ.

## Definition of fixed

A fix is complete only when the exact signed candidate—and then the
Homebrew-installed app—passes the affected scenario. For the Omarchy path this
includes clean import, complete first-run setup, login, continuous typing,
Command-to-Super, pointer and wheel, dynamic window/full-screen resolution,
NAT/DNS/TLS/package access, clean stop, recovery boot, and a second launch.

For implementation details and repeatable measurements, see
[Custom VirGL architecture](CUSTOM_VIRGL_ARCHITECTURE.md),
[VirGL performance validation](VIRGL_PERFORMANCE.md),
[Guest Agent protocol](GUEST_AGENT_PROTOCOL.md), and
[Homebrew distribution](HOMEBREW.md).
