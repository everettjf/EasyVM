# Custom VirGL architecture and engineering notes

_Last validated: September 1, 2026_

This document records the production architecture, invariants, observed
failure modes, and validation baseline for EZVM's macOS 27 Linux graphics path.
It is intentionally more durable than the chronological prototype notes.

## Scope and compatibility

EZVM requires macOS 27. Graphics selection still fails safely:

| Host / guest | Requested backend | Fallback |
| --- | --- | --- |
| macOS 27+, Linux | Custom Virtio GPU + VirGL | Apple Virtio if the runtime is unavailable or initialization fails |
| macOS guest | Apple Mac graphics | Custom VirGL is never selected |

The Custom VirGL setting defaults on where supported. The running VM window
shows both the requested and active backend so a fallback is diagnosable.

## Data paths

### Graphics

```text
Hyprland / Wayland / Xwayland
  -> Mesa Gallium + Linux virtio_gpu DRM
  -> VZCustomVirtioDevice queues (virtio device ID 16)
  -> EZVM VirtioGPUDevice
  -> VirGLRenderer
  -> libepoxy + ANGLE EGL/OpenGL ES
  -> Metal texture / CAMetalLayer
```

The normal scanout path borrows VirGL's live texture and wraps it in an
`EGLImage`; it does not copy pixels through Swift `Data`, `CGImage`, or a CPU
readback. All VirGL/ANGLE calls retain dedicated-thread EGL context affinity.

Presentation is display-clock driven. There is at most one in-flight drawable
and one latest pending frame; older pending frames are coalesced. The objective
is low visible latency, not delivery of stale intermediate frames.

### Dynamic display

```text
window/full-screen size settles
  -> host publishes a generation-tagged display configuration
  -> host raises the virtio-gpu display event
  -> guest reads GET_EDID and GET_DISPLAY_INFO
  -> host observes the generation and clears the event
  -> guest watcher applies the mode to the active compositor
  -> guest allocates a matching scanout
```

The event is level-like state, not a short pulse. Never clear it with a timer:
a booting or busy guest can miss an arbitrary timeout.

Logical AppKit points, guest pixels, layer bounds, and Retina drawable pixels
are distinct quantities. The validated full-screen example was:

```text
bounds=1920x1080 guest=1920x1080 layer=1920x1080 drawable=3840x2160
```

### Desktop input

The macOS 27 Custom Virtio beta API does not expose the guest configuration
writes needed by a conforming dynamic `virtio-input` device. The production
path therefore combines:

- Virtualization.framework's native USB digitizer for pointer movement when
  available;
- the mutually authenticated AF_VSOCK Guest Agent;
- Linux uinput keyboard, wheel, and negotiated absolute-pointer devices;
- explicit Command-to-Linux-Super key chords.

Physical keyboards normally deliver modifier changes before the associated
key-down. Accessibility and remote-control sources may instead attach
Shift/Control/Option only to the key-down event. EZVM detects that missing
transition and sends a bounded complete modifier chord; it does not synthesize
a second modifier when the physical transition is already held. This matters
for uppercase text and symbols such as `:` as well as for automated acceptance.

Agent readiness must mean that the live compositor owns the EZVM input event
node. A successful `hyprctl` call is insufficient because stale sockets can
survive a prior session. The current Omarchy integration intersects the
compositor's open `/proc` input descriptors with the EZVM device event node.

## Resource and protocol invariants

### Validate by resource target

Gallium `PIPE_BUFFER` (`target == 0`) stores a byte length in `width`. It is not
a texture dimension. Hyprland legitimately created this resource:

```text
target=0 width=1048576 height=1 depth=1
```

Applying an 8192-pixel texture dimension limit to that request caused:

```text
vrend_set_single_vbo: context error reported 5 "Hyprland" Illegal resource 44
context 5 failed to dispatch DRAW_VBO: 104
```

Keep the checks separate:

- buffers: validate byte length against the 256 MiB buffer limit;
- textures: validate dimensions, levels, layers, and total texels;
- all resources: use overflow-safe arithmetic and bound attached guest memory.

### Resource lifetime is cross-context state

`RESOURCE_UNREF` must detach the resource from every tracked context before
destroying it. Reset and stop must release fences, contexts, resources,
mappings, cursors, and pending presentation work. A renderer resource that is
gone from the protocol table but still attached to a context is a delayed crash.

### Fences must not serialize the VM

Virtio fences complete asynchronously. Blocking the command queue until the GPU
finishes makes simple tests deterministic at the cost of desktop latency and
can deadlock teardown. Track pending fences, signal completions, and invalidate
them explicitly during reset/stop.

### Fallback ends before virtual-machine construction

EZVM creates the renderer, Custom Virtio provider, and all
`VZCustomVirtioDeviceConfiguration` instances inside one recoverable backend
construction boundary. A missing runtime, renderer initialization failure, or
device-configuration failure therefore selects Apple Virtio before creating a
`VZVirtualMachine`; EZVM never exposes a partially initialized custom device to
the guest. Once construction succeeds, configuration application is infallible
and only installs the already validated device objects.

## Failure modes and lessons

### Typed characters appear only after mouse movement

This symptom does not prove input loss. In the observed failure, Linux had
already processed the keys, but the host refreshed the live scanout only when a
later AppKit event caused work. The fixes were:

1. move presentation off the main actor;
2. drive it from the display cadence;
3. synchronize producer/presenter EGL contexts with fences;
4. keep pending work bounded and coalesce stale frames.

Always correlate Agent input acknowledgements, Guest state, submitted frames,
and host presents before changing key mapping code.

### Full-screen content is stretched or remains oversized

Do not scale an old guest framebuffer to disguise a missing mode change. Check
the generation handshake first, then verify the guest compositor actually
applied the mode and created a matching scanout. Setup/login consoles may keep a
fixed mode; the real compositor desktop is the final validation target.

### Super shortcuts do nothing

Check the complete chord and ownership chain:

1. AppKit local monitor does not let the menu consume the event;
2. the VM view regained first responder after toolbar interaction;
3. Agent advertises both base uinput and desktop-ready capability;
4. the batch contains ordered down/up events for Super and the key;
5. Guest acknowledges the batch;
6. the live compositor owns the uinput device.

### Trackpad scrolling jumps hundreds of lines

macOS can report high-resolution scroll deltas. Never forward an unbounded
host-derived detent count. The current path bounds each emitted wheel amount to
`-16...16` while preserving direction and repeated events.

### Keychain prompts block automated testing

Authentication must not be removed to fix prompting. EZVM retains a random
per-VM token and mutual HMAC authentication, but stores the host enrollment in
a private Application Support directory (`0700`) with token files at `0600`.
This avoids interactive Keychain ACL changes across development signatures.
The user account and its private application data are part of the trust model.

### First-run setup loops or loses input

The host app cannot solve every early-boot issue. The Omarchy image must start
the Agent/uinput service before first-run setup, avoid assuming a complete
desktop D-Bus session for timezone selection, and retry display-watcher startup
until the compositor/device state is real. Host and guest changes must be
versioned and tested together.

### A notarized app starts but no Control Center appears

Process launch, a valid Developer ID signature, Gatekeeper acceptance, and a
responsive SwiftUI event loop are separate release properties. SwiftUI can
restore the persisted state in which every window was previously closed. A
GUI smoke test must therefore reject an already-running EZVM instance, launch
the quarantined candidate through Launch Services, send the same
reopen/activate lifecycle event as a second user click, and require a readiness
record from a visible window of at least 800x600. Do not weaken this to a PID
check: a running process with no usable window is still a broken desktop app.

## Lifecycle constraints

Custom VirGL supports VM start, pause, resume, reset, stop, and stopped-VM file
snapshots. It does **not** support Virtualization.framework machine-state
save/restore. Guest RAM does not contain enough information to recreate host
VirGL contexts, GL objects, mappings, borrowed textures, or in-flight fences.

The UI must continue to disable or explain state-save operations for this
backend. A future implementation would need an explicit renderer-state
serialization contract; silently attempting native save/restore is unsafe.

## End-to-end Omarchy validation

The final validation did not reuse a configured development guest. It rebuilt
the complete 64 GiB sparse Omarchy disk from the maintained AArch64 image
repository, ran its Linux/ARM64 validation suite to a fail-closed `PASS`, and
imported an APFS clone through EZVM. This caught an ordering bug that unit-only
testing missed: incompatible services had to be masked after Omarchy's system
apply step, because that step could restore them.

The clean-image scenario then established:

- the first-run greeter remains centered at window and full-screen sizes;
- keyboard layout, account, password, hostname, and timezone advance exactly
  once, including `America/Los_Angeles` without returning to keyboard setup;
- the early-boot Agent accepts text and Return before the desktop session;
- the completed Hyprland desktop consumes the negotiated full-screen mode
  after compositor startup (allow several seconds for watcher readiness);
- `Command+K` reaches the guest as `Super+K`, and `Command+Return` opens a
  terminal;
- a long alphabetic command appears and executes immediately, with no pointer
  movement needed to reveal delayed characters;
- injected `Shift+A` and `Shift+;` produce `A` and `:` while a physically held
  modifier is not duplicated;
- NAT assigns `192.168.64.2/24` with a default route, DNS resolves both Arch
  endpoints, HTTPS negotiates TLS 1.3 and HTTP/2 with a 200 response, and
  `checkupdates` downloads the live package databases and reports upgrades;
- pointer movement and browser scrolling work in the real desktop; and
- the first-run password field is a normal single-line control rather than an
  oversized framebuffer-scaled field.

The rebuilt image SHA-256 was
`88d4fa72b7cafbef5cda3ea5e7306a14cdd75e9f57fadc97f00bc31951394c2b`.
It is a QA provenance value, not a stable public release identifier.

## Performance baseline

The August 31–September 1 real-guest validation used Omarchy/Hyprland and
established:

- approximately 60 FPS in windowed and full-screen desktop operation;
- typical Metal present time around 0.4–0.8 ms;
- zero drawable misses and zero presentation failures in the final sample;
- a complete 1920x1080 generation/EDID/display-info/ack handshake;
- successful `Super+K` and `Super+Space` batches through Agent/uinput;
- responsive continuous typing without requiring pointer movement;
- bounded wheel delivery and successful human verification of browser
  scrolling;
- successful 126-test Swift suite, 27 Guest Agent protocol tests, 17 prototype tests,
  Linux Go Agent tests, the complete image validation suite, a source-rebuilt
  VirGL runtime, Release build, Developer ID signature, strict code-signing
  verification, and signed-archive extraction verification.

The `1.0.4` release additionally passed Apple notarization, Gatekeeper and GUI
readiness after quarantine extraction, two concurrent headless VMs, SIGKILL
restart, corrupt saved-state fallback, EFI boot recovery, authenticated Agent
upload/download byte round-trips, clean stop, guest `/dev/kvm` validation with
`KVM_GET_API_VERSION=12`, and the same gates again after a real Homebrew
`1.0.3 -> 1.0.4` upgrade.

These numbers prove the local path is healthy; they do not by themselves prove
universal performance parity with QEMU/HVF-based products. Comparative claims
require the same Mac, guest image, CPU/memory allocation, resolution, scaling,
workload, and capture duration.

Use [`VIRGL_PERFORMANCE.md`](VIRGL_PERFORMANCE.md) for repeatable captures.

## Maintenance checklist

Before merging changes to the Custom VirGL path:

1. Run the root Swift test suite and prototype tests.
2. Run Linux Guest Agent Go tests with a writable isolated Go cache.
3. Boot a real Omarchy/Hyprland guest, not only the setup console.
4. Verify continuous typing, Return, Command/Super chords, pointer, and wheel.
5. Resize the window, enter/exit full screen, and verify the display ACK chain.
6. Confirm zero presentation failures and no illegal-resource/DRAW_VBO errors.
7. Pause/resume and stop/restart; confirm resources and cadence are released.
8. Verify Apple Virtio fallback on a host/configuration without Custom Virtio.
9. Build the pinned runtime from source; do not depend on mutable Homebrew libs.
10. Audit bundled licenses and source checksums before distribution.

## Follow-up work

- same-host, same-workload A/B measurements against QEMU/HVF + VirGL;
- longer compositor/browser/video soak tests and memory-pressure testing;
- broader Linux desktop and kernel matrix;
- automated end-to-end input/display state-machine assertions;
- bidirectional Unicode/large-text and PNG clipboard validation;
- audio/camera integration parity where it fits EZVM's product scope;
- protocol fuzzing for malformed descriptors, resource sizes, and teardown races.
