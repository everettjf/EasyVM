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
