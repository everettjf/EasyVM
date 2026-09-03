#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ezvm-sparse-asif-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

source_disk="$work/source.raw"
destination="$work/result.asif"
truncate -s 67108864 "$source_disk"
printf 'header-marker' | dd of="$source_disk" bs=1 seek=0 conv=notrunc status=none
printf 'middle-marker' | dd of="$source_disk" bs=1 seek=33554432 conv=notrunc status=none
printf 'tail-marker' | dd of="$source_disk" bs=1 seek=67108853 conv=notrunc status=none

"$project_root/scripts/copy-sparse-raw-to-asif.sh" "$source_disk" "$destination"

[[ -f $destination ]]
[[ $(/usr/sbin/diskutil image info "$destination" | awk '/Image Format:/ { print $3; exit }') == ASIF ]]
[[ $(stat -f %z "$destination") -lt $(stat -f %z "$source_disk") ]]

cp "$source_disk" "$work/equal.raw"
"$project_root/scripts/verify-raw-device-bytes.pl" \
  "$source_disk" "$work/equal.raw" "$(stat -f %z "$source_disk")"
printf X | dd of="$work/equal.raw" bs=1 seek=33554432 conv=notrunc status=none
if "$project_root/scripts/verify-raw-device-bytes.pl" \
  "$source_disk" "$work/equal.raw" "$(stat -f %z "$source_disk")" 2>/dev/null; then
  echo 'byte verifier accepted a modified destination' >&2
  exit 1
fi

if "$project_root/scripts/copy-sparse-raw-to-asif.sh" "$source_disk" "$destination" 2>/dev/null; then
  echo 'existing destination was unexpectedly overwritten' >&2
  exit 1
fi

echo 'Verified sparse raw-to-ASIF import, byte comparison, and overwrite rejection.'
