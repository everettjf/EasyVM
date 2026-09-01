# VZ Custom Virtio GPU Prototype

This isolated macOS 27 experiment answered three questions before EZVM adopted
a new graphics architecture:

1. Can `VZCustomVirtioDevice` expose standard Virtio device ID 16 and bind the
   stock Linux `virtio_gpu` driver?
2. Can a minimal 2D virtio-gpu implementation present a Linux scanout without
   using `VZVirtioGraphicsDeviceConfiguration` or `VZVirtualMachineView`?
3. Can that device negotiate VirGL and drive VirGLRenderer through ANGLE's
   Metal backend, including real Hyprland and Xwayland 3D command streams?

All three gates passed on macOS 27 beta with Xcode 27 beta. The stage 3 path
implements capsets, contexts, bounded 2D/3D resources, backing memory,
transfers, submits, asynchronous fences, and cursor updates. The normal display
path no longer performs a CPU readback.

Stage 4's zero-copy gate also passed: the prototype calls
`virgl_renderer_borrow_texture_for_scanout` and obtains live GL texture IDs for
the real Hyprland triple-buffered scanouts. It wraps each ANGLE Metal texture in
an `EGLImage`, blits it directly into a `CAMetalDrawable`, and presents the
drawable without copying pixels through Swift `Data` or `CGImage`. All
VirGL/ANGLE calls run on one dedicated OS thread so the EGL context retains
stable thread affinity under sustained Hyprland and Xwayland load.

Stage 6 handles Custom Virtio pause, resume, reset, and stop explicitly. Reset
and stop release fences, contexts, resources, mappings, cursors, and pending
presentation work. EZVM intentionally disables Virtualization machine-state
save/restore for Custom VirGL: restoring guest RAM cannot reconstruct the
renderer command-stream state safely. File-level stopped-VM snapshots remain
independent of this restriction.

Stage 7 bounds presentation dispatch to one in-flight frame and one latest
pending frame. A stalled main actor therefore drops stale frames instead of
building an unbounded queue. Runtime counters report submitted, delivered, and
coalesced frames.

## Input API finding

`VirtioInputProbeDevice` is a default-off diagnostic enabled in EZVM with
`EZVM_EXPERIMENTAL_STATIC_VIRTIO_INPUT=1`. It proves a limitation in the macOS
27 beta public API: `VZCustomVirtioDevice` exposes whole device-configuration
updates but no callback for guest configuration writes. Linux `virtio_input`
writes `select` and `subsel` before each capability read, so a conforming input
device must answer dynamically.

The static probe is created successfully by Virtualization, but the stock
Omarchy Linux driver does not reach `DRIVER_OK` and does not provide event
buffers. It must not be enabled as a production input backend. Product input
therefore needs either an Apple-supported injection API, a guest-agent/uinput
channel, or a future Custom Virtio configuration-write API.

## Safety

Pass only disposable writable copies of a Linux disk and EFI variable store.
Never pass an EZVM machine's live files. `run-with-omarchy-copy.sh` creates
copy-on-write clones in a fresh temporary directory and removes them when the
prototype exits.

`run-with-try-omarchy-rootfs.sh` likewise clones Try Omarchy's current working
rootfs and direct-boots its bundled kernel and initramfs with
`omarchy.qemu_virgl=1`. Both scripts delete their temporary clones on exit.

## Run

```sh
./run-with-omarchy-copy.sh

# Stronger stage 3 validation using Try Omarchy's own guest profile:
./run-with-try-omarchy-rootfs.sh
```

For local integration diagnostics, the full EZVM app can direct-boot a Linux
kernel and optional initramfs without changing the VM bundle configuration.
This path is accepted only by a `--ezvm-headless` launch or an explicitly
configured release-smoke launch, and requires all of these environment values:

- `EZVM_EXPERIMENTAL_LINUX_KERNEL`
- `EZVM_EXPERIMENTAL_LINUX_INITRD` (optional)
- `EZVM_EXPERIMENTAL_LINUX_COMMAND_LINE`

Setting `EZVM_RELEASE_REQUIRE_GUEST_INPUT=1` on a Guest Agent smoke launch adds
two gates before the existing byte-exact upload/download test: the authenticated
Agent must advertise `input-uinput-v1`, and it must successfully write a
complete no-op event batch to the guest's real `/dev/uinput` device.

The executable is ad-hoc signed with the virtualization entitlement after it
is built. Its terminal output contains explicit `[stage1]`, `[stage2]`, and
`[stage3]`, and `[stage4]` markers. A successful first gate includes `DRIVER_OK` and
`VIRTIO_GPU_CMD_GET_DISPLAY_INFO`; a successful second gate shows the guest
scanout in the prototype window. Stage 3 succeeds when the log identifies the
ANGLE Metal renderer, delivers VirGL capset 1, creates Hyprland/Xwayland 3D
resources, and reports submitted commands. Stage 4 succeeds when the log reports
borrowed scanout textures and `zero-copy Metal frame ... presented` without an
EGL context-access error.

## Product adoption status

The feasibility work is complete. Its productionized implementation now lives
in EZVM's normal Linux VM path rather than in the prototype window. The product
version adds backend fallback, compact/full-screen window behavior,
guest-acknowledged resolution changes, display-clock presentation, authenticated
Agent/uinput desktop input, release packaging, and lifecycle cleanup.

Keep this package as an isolated protocol/runtime regression harness. New
product behavior belongs in EZVM; experiments that can corrupt disks or test
untrusted command streams should remain here. See
[`docs/CUSTOM_VIRGL_ARCHITECTURE.md`](../../docs/CUSTOM_VIRGL_ARCHITECTURE.md)
for the maintained architecture and lessons.

The prototype dynamically loads the VirGLRenderer and ANGLE libraries from an
installed Try Omarchy application by default. EZVM must make its own licensing
and packaging decision before distributing those runtime libraries.
