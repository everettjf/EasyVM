#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/ezvm-real-low-space.XXXXXX")"
image_path="$work_root/near-full.dmg"
mount_path="$work_root/volume"
mounted=0

fail() {
  echo "verify-real-low-space-snapshot: $*" >&2
  exit 1
}

cleanup() {
  if [[ "$mounted" == "1" ]]; then
    diskutil eject "$mount_path" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_root"
}
trap cleanup EXIT

mkdir "$mount_path"
diskutil image create blank --format RAW --size 1100m --fs APFS \
  --volumeName EZVMNearFull "$image_path" >/dev/null
diskutil image attach --nobrowse --mountPoint "$mount_path" "$image_path" >/dev/null
mounted=1

# Allocate real blocks inside an isolated disposable volume. This leaves well
# under EZVM's 1 GiB safety reserve without filling the user's live volume.
mkfile 800m "$mount_path/filler.bin"

available_kib="$(df -k "$mount_path" | awk 'NR == 2 { print $4 }')"
[[ "$available_kib" =~ ^[0-9]+$ ]] || fail "could not read isolated-volume capacity"
(( available_kib < 1048576 )) || fail "isolated volume still has at least 1 GiB available"

EZVM_REAL_LOW_SPACE_VOLUME="$mount_path" \
  swift test --package-path "$project_root" \
  --filter VMSnapshotManagerTests/testRealNearlyFullVolumeRejectsSnapshotBeforeMutation

echo "Verified real APFS low-space snapshot rejection before mutation (${available_kib} KiB available)."
