# EZVM Omarchy Guest Overlay

This directory contains the Omarchy-specific image additions owned by the
dedicated product. It does not fork the general EZVM Guest Agent.

The image build installs and enables `systemd/mnt-ezvm-shared.mount`. The unit
mounts the Host-provided VirtioFS tag `ezvm_shared` at `/mnt/ezvm-shared` with
`nosuid,nodev`. The Guest Agent advertises `shared-folders-v1` only after Linux
mountinfo proves that this exact tag, filesystem type, and mount point are
active.

The Host must treat absence of that capability as degraded integration. Merely
configuring a Virtualization.framework directory-sharing device is not proof
that the guest can use it.

The image also installs and enables `systemd/ezvm-session-agent.service` as a
user service. It runs the same signed Agent binary without root privileges and
registers only currently verified desktop capabilities over a local Unix
socket. The system Agent authenticates the peer UID with `SO_PEERCRED`, expires
registrations after 15 seconds, and never exposes a general command channel.

`scripts/build-omarchy-guest-overlay.sh` packages these units into a bounded,
versioned archive with a machine-readable manifest and per-file SHA-256 values.
The image pipeline must verify the archive checksum and manifest before copying
the files into a factory image, then enable both units explicitly.

After integration, run
`scripts/verify-omarchy-image-source-integration.sh <image-checkout>` from the
EZVM repository. It verifies exact unit contents, explicit `wl-clipboard`
installation, system/user enablement, and final-image required-path checks.
