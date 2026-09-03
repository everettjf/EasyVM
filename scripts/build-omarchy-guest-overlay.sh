#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:-}
output_dir=${2:-"$project_root/dist"}

if [[ -z $version ]]; then
  echo "usage: $0 <version> [output-directory]" >&2
  exit 64
fi
version=${version#v}
[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || {
  echo "invalid overlay version" >&2
  exit 64
}

source_root="$project_root/EZVMOmarchy/GuestOverlay/systemd"
mount_unit="$source_root/mnt-ezvm\x2dshared.mount"
session_unit="$source_root/ezvm-session-agent.service"
test -f "$mount_unit"
test -f "$session_unit"

mkdir -p "$output_dir"
staging=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-overlay.XXXXXX")
trap 'rm -rf "$staging"' EXIT

install -d -m 0755 \
  "$staging/etc/systemd/system" \
  "$staging/etc/systemd/user" \
  "$staging/mnt/ezvm-shared"
install -m 0644 "$mount_unit" \
  "$staging/etc/systemd/system/mnt-ezvm\x2dshared.mount"
install -m 0644 "$session_unit" \
  "$staging/etc/systemd/user/ezvm-session-agent.service"

manifest="$staging/overlay-manifest.json"
jq -n \
  --arg version "$version" \
  --arg mount_sha "$(shasum -a 256 "$mount_unit" | awk '{print $1}' | tr -d '\\')" \
  --arg session_sha "$(shasum -a 256 "$session_unit" | awk '{print $1}')" \
  '{
    schemaVersion: 1,
    productID: "com.everettjf.ezvm.omarchy",
    version: $version,
    files: [
      {path: "etc/systemd/system/mnt-ezvm\\x2dshared.mount", sha256: $mount_sha},
      {path: "etc/systemd/user/ezvm-session-agent.service", sha256: $session_sha}
    ]
  }' >"$manifest"

archive="EZVM-Omarchy-GuestOverlay-$version.tar.gz"
archive_path="$output_dir/$archive"
find "$staging" -exec touch -h -t 202001010000 {} +
uncompressed="$staging/overlay.tar"
COPYFILE_DISABLE=1 tar --format ustar -C "$staging" -cf "$uncompressed" \
  overlay-manifest.json \
  mnt/ezvm-shared \
  'etc/systemd/system/mnt-ezvm\x2dshared.mount' \
  etc/systemd/user/ezvm-session-agent.service
gzip -n -9 -c "$uncompressed" >"$archive_path"
shasum -a 256 "$archive_path" >"$archive_path.sha256"
(cd "$output_dir" && shasum -a 256 -c "$archive.sha256")
echo "Created $archive_path"
