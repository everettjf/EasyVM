#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image_source=${1:-}
fail() { echo "verify-omarchy-image-source-integration: $*" >&2; exit 1; }

[[ -d $image_source && ! -L $image_source ]] || fail "usage: $0 <omarchy-aarch64-image-checkout>"
profile="$image_source/profiles/aarch64-virt"
build="$image_source/bin/build-image"
[[ -f $build && ! -L $build && -f $profile/runtime-packages ]] || fail "not an expected image source tree"

system_unit='etc/systemd/system/mnt-ezvm-shared.mount'
user_unit='etc/systemd/user/ezvm-session-agent.service'
cmp -s "$project_root/EZVMOmarchy/GuestOverlay/systemd/mnt-ezvm-shared.mount" \
  "$profile/overlay/$system_unit" || fail "shared-folder mount unit is missing or differs from the product contract"
cmp -s "$project_root/EZVMOmarchy/GuestOverlay/systemd/ezvm-session-agent.service" \
  "$profile/overlay/$user_unit" || fail "Session Agent unit is missing or differs from the product contract"

grep -Eq '^[[:space:]]*wl-clipboard([[:space:]]*(#.*)?)?$' "$profile/runtime-packages" || \
  fail "wl-clipboard is not an explicit image runtime dependency"
grep -Fq 'target_chroot systemctl enable mnt-ezvm-shared.mount' "$build" || \
  fail "shared-folder mount is not enabled during image assembly"
grep -Fq 'target_chroot systemctl --global enable ezvm-session-agent.service' "$build" || \
  fail "Session Agent is not globally enabled for the owner desktop session"
for required in \
  "$system_unit" \
  "$user_unit" \
  'etc/systemd/system/multi-user.target.wants/mnt-ezvm-shared.mount' \
  'etc/systemd/user/graphical-session.target.wants/ezvm-session-agent.service'; do
  grep -Fq "$required" "$build" || fail "final image validation does not require /$required"
done

echo "Verified Omarchy image source implements the EZVM Omarchy Guest Overlay contract."
