#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-soak.XXXXXX")
updater_pid=
cleanup() {
  if [[ -n $updater_pid ]]; then kill "$updater_pid" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
revision=0123456789abcdef0123456789abcdef01234567
mkdir -p "$work/Diagnostics"

swift build --package-path "$project_root" --product omarchy-soak-acceptance-tool >/dev/null
bin_dir=$(swift build --package-path "$project_root" --show-bin-path)
tool="$bin_dir/omarchy-soak-acceptance-tool"

ruby -rjson -rtime -e '
  root, revision = ARGV
  8.times do |index|
    value = {
      schemaVersion: 1, observedAt: Time.now.utc.iso8601,
      sourceRevision: revision, guestAgentVersion: "agent-test",
      agentInstanceID: "instance-test", bootID: "boot-test",
      uptimeSeconds: 100 + index, desktopSessionActive: true,
      provisioningPending: false
    }
    temporary = File.join(root, "Diagnostics", "soak-heartbeat.next")
    File.write(temporary, JSON.generate(value))
    File.rename(temporary, File.join(root, "Diagnostics", "soak-heartbeat.json"))
    sleep 0.7
  end
' "$work" "$revision" &
updater_pid=$!
sleep 0.2
EZVM_OMARCHY_SOAK_INTERVAL_SECONDS=1 "$tool" \
  "$work" "$revision" 3 "$work/soak-observation.json"
wait "$updater_pid"
updater_pid=

ruby -rjson -rtime -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong schema" unless value["schemaVersion"] == 1
  abort "short smoke interval" unless value["continuousOperationSeconds"] >= 3
  abort "insufficient samples" unless value["sampleCount"] >= 2
  abort "wrong boot identity" unless value["bootID"] == "boot-test"
  abort "desktop continuity missing" unless value["desktopContinuouslyActive"] == true
  abort "provisioning continuity missing" unless value["provisioningContinuouslyComplete"] == true
' "$work/soak-observation.json"

ruby -rjson -rtime -e '
  value = {
    schemaVersion: 1, observedAt: Time.now.utc.iso8601,
    sourceRevision: ARGV.fetch(1), guestAgentVersion: "agent-test",
    agentInstanceID: "instance-test", bootID: "boot-test", uptimeSeconds: 200,
    desktopSessionActive: false, provisioningPending: false
  }
  File.write(File.join(ARGV.fetch(0), "Diagnostics", "soak-heartbeat.json"), JSON.generate(value))
' "$work" "$revision"
if EZVM_OMARCHY_SOAK_INTERVAL_SECONDS=1 "$tool" \
  "$work" "$revision" 1 "$work/rejected.json" >/dev/null 2>&1; then
  echo 'soak monitor accepted an inactive desktop' >&2
  exit 1
fi

echo 'Verified continuous authenticated Guest soak monitoring and rejection.'
