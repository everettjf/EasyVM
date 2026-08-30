# VZ Custom Virtio GPU Prototype

This isolated macOS 27 experiment answers three questions before EZVM adopts a
new graphics architecture:

1. Can `VZCustomVirtioDevice` expose standard Virtio device ID 16 and bind the
   stock Linux `virtio_gpu` driver?
2. Can a minimal 2D virtio-gpu implementation present a Linux scanout without
   using `VZVirtioGraphicsDeviceConfiguration` or `VZVirtualMachineView`?
3. Can that device negotiate VirGL and drive VirGLRenderer through ANGLE's
   Metal backend, including real Hyprland and Xwayland 3D command streams?

All three gates passed on macOS 27 beta with Xcode 27 beta. The stage 3 path
implements capsets, contexts, 2D/3D resources, backing memory, transfers,
submits, and basic fences. Cursor handling and production lifecycle integration
remain incomplete, but the normal display path no longer performs a CPU
readback.

Stage 4's zero-copy gate also passed: the prototype calls
`virgl_renderer_borrow_texture_for_scanout` and obtains live GL texture IDs for
the real Hyprland triple-buffered scanouts. It wraps each ANGLE Metal texture in
an `EGLImage`, blits it directly into a `CAMetalDrawable`, and presents the
drawable without copying pixels through Swift `Data` or `CGImage`. All
VirGL/ANGLE calls run on one dedicated OS thread so the EGL context retains
stable thread affinity under sustained Hyprland and Xwayland load.

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

The executable is ad-hoc signed with the virtualization entitlement after it
is built. Its terminal output contains explicit `[stage1]`, `[stage2]`, and
`[stage3]`, and `[stage4]` markers. A successful first gate includes `DRIVER_OK` and
`VIRTIO_GPU_CMD_GET_DISPLAY_INFO`; a successful second gate shows the guest
scanout in the prototype window. Stage 3 succeeds when the log identifies the
ANGLE Metal renderer, delivers VirGL capset 1, creates Hyprland/Xwayland 3D
resources, and reports submitted commands. Stage 4 succeeds when the log reports
borrowed scanout textures and `zero-copy Metal frame ... presented` without an
EGL context-access error.

The prototype dynamically loads the VirGLRenderer and ANGLE libraries from an
installed Try Omarchy application by default. EZVM must make its own licensing
and packaging decision before distributing those runtime libraries.
