#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unit="$project_root/EZVMOmarchy/GuestOverlay/systemd/mnt-ezvm-shared.mount"

test -f "$unit"
grep -qx 'What=ezvm_shared' "$unit"
grep -qx 'Where=/mnt/ezvm-shared' "$unit"
grep -qx 'Type=virtiofs' "$unit"
grep -qx 'Options=rw,nosuid,nodev' "$unit"
grep -qx 'WantedBy=multi-user.target' "$unit"

if find "$project_root/EZVMOmarchy/GuestOverlay" -type l | grep -q .; then
    echo "Guest Overlay must not contain symbolic links" >&2
    exit 1
fi
