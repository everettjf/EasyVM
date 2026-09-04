#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-lifecycle.XXXXXX")
trap 'rm -rf "$work"' EXIT
agent=0123456789abcdef0123456789abcdef01234567
revision=1234567890abcdef1234567890abcdef12345678
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

write_observation() {
  ruby -rjson -e '
    value = {
      schemaVersion: 6,
      sourceRevision: ARGV.fetch(3),
      firstProvisioningPendingObservedAt: ARGV.fetch(0),
      firstLockedObservedAt: ARGV.fetch(0),
      firstActiveObservedAt: ARGV.fetch(0),
      firstActiveAfterLockedObservedAt: ARGV.fetch(0),
      firstPauseRequestedAt: ARGV.fetch(0),
      firstPausedAt: ARGV.fetch(0),
      firstResumedAt: ARGV.fetch(0),
      firstActiveAfterResumeObservedAt: ARGV.fetch(0),
      firstAgentRestartRequestedAt: ARGV.fetch(0),
      firstAgentDisconnectedAfterRestartAt: ARGV.fetch(0),
      firstAgentRecoveredAt: ARGV.fetch(0),
      agentBootIDBeforeRestart: "boot-before",
      agentBootIDAfterRestart: "boot-before",
      agentInstanceIDBeforeRestart: "instance-before",
      agentInstanceIDAfterRestart: "instance-after",
      firstGuestRestartRequestedAt: ARGV.fetch(0),
      firstGuestDisconnectedAfterRestartAt: ARGV.fetch(0),
      firstGuestRecoveredAt: ARGV.fetch(0),
      guestBootIDBeforeRestart: "boot-before",
      guestBootIDAfterRestart: "boot-after",
      firstHostSleepObservedAt: ARGV.fetch(0),
      firstHostWakeObservedAt: ARGV.fetch(0),
      firstActiveAfterHostWakeObservedAt: ARGV.fetch(0),
      lastObservedAt: ARGV.fetch(0),
      lastDesktopSessionActive: true,
      lastProvisioningPending: false,
      guestAgentVersion: ARGV.fetch(1)
    }
    File.write(ARGV.fetch(2), JSON.generate(value))
  ' "$now" "$agent" "$work/lifecycle.json" "$revision"
}

verify=("$project_root/scripts/verify-omarchy-lifecycle-observation.sh" \
  "$work/lifecycle.json" "$agent" "$revision")

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
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v.delete("firstProvisioningPendingObservedAt"); File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without observed owner provisioning was accepted"

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
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v.delete("firstPausedAt"); File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without a pause confirmation was accepted"

write_observation
ruby -rjson -e '
  v=JSON.parse(File.read(ARGV[0]));
  v["firstResumedAt"]="2000-01-01T00:00:00Z";
  File.write(ARGV[0], JSON.generate(v))
' "$work/lifecycle.json"
expect_rejection "lifecycle with resume preceding pause was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["agentInstanceIDAfterRestart"]=v["agentInstanceIDBeforeRestart"]; File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without a changed Agent instance was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["guestBootIDAfterRestart"]=v["guestBootIDBeforeRestart"]; File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without a changed Guest boot ID was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v.delete("firstActiveAfterHostWakeObservedAt"); File.write(ARGV[0], JSON.generate(v))' "$work/lifecycle.json"
expect_rejection "lifecycle without post-wake integration recovery was accepted"

write_observation
ruby -rjson -e '
  v=JSON.parse(File.read(ARGV[0]));
  v["firstHostWakeObservedAt"]="2000-01-01T00:00:00Z";
  File.write(ARGV[0], JSON.generate(v))
' "$work/lifecycle.json"
expect_rejection "lifecycle with wake preceding sleep was accepted"

write_observation
verify=("$project_root/scripts/verify-omarchy-lifecycle-observation.sh" \
  "$work/lifecycle.json" wrong-agent "$revision")
expect_rejection "lifecycle from a different Guest Agent was accepted"

write_observation
verify=("$project_root/scripts/verify-omarchy-lifecycle-observation.sh" \
  "$work/lifecycle.json" "$agent" 0000000000000000000000000000000000000000)
expect_rejection "lifecycle from a different Host revision was accepted"

echo "Verified lifecycle observation validation and rejection gates."
