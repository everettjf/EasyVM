#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-lifecycle.XXXXXX")
trap 'rm -rf "$work"' EXIT
agent=0123456789abcdef0123456789abcdef01234567
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

write_observation() {
  ruby -rjson -e '
    value = {
      schemaVersion: 2,
      firstProvisioningPendingObservedAt: ARGV.fetch(0),
      firstLockedObservedAt: ARGV.fetch(0),
      firstActiveObservedAt: ARGV.fetch(0),
      firstActiveAfterLockedObservedAt: ARGV.fetch(0),
      lastObservedAt: ARGV.fetch(0),
      lastDesktopSessionActive: true,
      lastProvisioningPending: false,
      guestAgentVersion: ARGV.fetch(1)
    }
    File.write(ARGV.fetch(2), JSON.generate(value))
  ' "$now" "$agent" "$work/lifecycle.json"
}

verify=("$project_root/scripts/verify-omarchy-lifecycle-observation.sh" \
  "$work/lifecycle.json" "$agent")

expect_rejection() {
  local message=$1
  if "${verify[@]}" >/dev/null 2>&1; then
    echo "$message" >&2
    exit 1
  fi
}

write_observation
"${verify[@]}" >/dev/null

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v.delete("firstLockedObservedAt"); File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without a lock observation was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v.delete("firstActiveAfterLockedObservedAt"); File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without post-lock recovery was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["lastDesktopSessionActive"]=false; File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle ending with an inactive desktop was accepted"

write_observation
verify=("$project_root/scripts/verify-omarchy-lifecycle-observation.sh" \
  "$work/lifecycle.json" wrong-agent)
expect_rejection "lifecycle from a different Guest Agent was accepted"

echo "Verified lifecycle observation validation and rejection gates."
