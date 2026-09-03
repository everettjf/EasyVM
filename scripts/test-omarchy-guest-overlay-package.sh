#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-overlay-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

if bash "$project_root/scripts/build-omarchy-guest-overlay.sh" '../unsafe' "$fixture/invalid" >/dev/null 2>&1; then
  echo "invalid overlay version was accepted" >&2
  exit 1
fi

for attempt in first second; do
  output="$fixture/$attempt"
  bash "$project_root/scripts/build-omarchy-guest-overlay.sh" 0.1.0-test "$output" >/dev/null
  archive="$output/EZVM-Omarchy-GuestOverlay-0.1.0-test.tar.gz"
  (cd "$output" && shasum -a 256 -c "$(basename "$archive").sha256" >/dev/null)
  mapfile_file="$fixture/$attempt.list"
  tar -tzf "$archive" >"$mapfile_file"
  diff -u <(printf '%s\n' \
    overlay-manifest.json \
    mnt/ezvm-shared/ \
    'etc/systemd/system/mnt-ezvm\\x2dshared.mount' \
    etc/systemd/user/ezvm-session-agent.service) "$mapfile_file"

  extracted="$fixture/$attempt-extracted"
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted"
  jq -e '
    .schemaVersion == 1 and
    .productID == "com.everettjf.ezvm.omarchy" and
    .version == "0.1.0-test" and
    (.files | length) == 2 and
    ([.files[].path] == [
      "etc/systemd/system/mnt-ezvm\\x2dshared.mount",
      "etc/systemd/user/ezvm-session-agent.service"
    ]) and
    all(.files[]; .sha256 | test("^[0-9a-f]{64}$"))
  ' "$extracted/overlay-manifest.json" >/dev/null
  for path in \
    'etc/systemd/system/mnt-ezvm\x2dshared.mount' \
    etc/systemd/user/ezvm-session-agent.service; do
    expected=$(jq -r --arg path "$path" '.files[] | select(.path == $path) | .sha256' \
      "$extracted/overlay-manifest.json")
    actual=$(shasum -a 256 "$extracted/$path" | awk '{print $1}' | tr -d '\\')
    [[ $actual == "$expected" ]]
  done
done

cmp "$fixture/first/EZVM-Omarchy-GuestOverlay-0.1.0-test.tar.gz" \
  "$fixture/second/EZVM-Omarchy-GuestOverlay-0.1.0-test.tar.gz"
