#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-notification.XXXXXX")
trap 'rm -rf "$work"' EXIT
revision=0123456789abcdef0123456789abcdef01234567
observed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

write_observation() {
  ruby -rjson -e '
    value = {
      schemaVersion: 1,
      observedAt: ARGV.fetch(0),
      sourceRevision: ARGV.fetch(1),
      guestBootID: "boot-id",
      guestNotificationID: "guest-notification-id",
      notificationTitle: "EZVM notification 12345678-1234-1234-1234-123456789abc",
      macOSRequestAccepted: true
    }
    File.write(ARGV.fetch(2), JSON.pretty_generate(value))
  ' "$observed" "$revision" "$work/observation.json"
}

verify=("$project_root/scripts/verify-omarchy-notification-observation.sh" \
  "$work/observation.json" "$revision")

expect_rejection() {
  local message=$1
  if "${verify[@]}" >/dev/null 2>&1; then
    echo "$message" >&2
    exit 1
  fi
}

write_observation
"${verify[@]}" >/dev/null

ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["macOSRequestAccepted"]=false; File.write(ARGV[0], JSON.generate(v))' "$work/observation.json"
expect_rejection "an unaccepted macOS notification request was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["notificationTitle"]="unrelated"; File.write(ARGV[0], JSON.generate(v))' "$work/observation.json"
expect_rejection "an unrelated notification was accepted"

write_observation
verify=("$project_root/scripts/verify-omarchy-notification-observation.sh" \
  "$work/observation.json" ffffffffffffffffffffffffffffffffffffffff)
expect_rejection "an observation for a different Host revision was accepted"

echo "Verified notification observation validation and rejection gates."
