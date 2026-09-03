#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-observation.XXXXXX")
trap 'rm -rf "$work"' EXIT
revision=0123456789abcdef0123456789abcdef01234567
factory_version=factory-test-1
agent_version=agent-test-1
observed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

write_observation() {
  ruby -rjson -e '
    capabilities = %w[
      clipboard-image-v1 clipboard-text-v1 desktop-input-v1 dynamic-display-v1
      shared-folders-v1 shutdown-v1
    ]
    value = {
      schemaVersion: 1, observedAt: ARGV.fetch(0), sourceRevision: ARGV.fetch(1),
      factoryImageVersion: ARGV.fetch(2), omarchyRevision: "omarchy-test-1",
      guestAgentVersion: ARGV.fetch(3), guestHostName: "omarchy",
      guestAddresses: ["192.0.2.2"], guestCapabilities: capabilities,
      requiredCapabilities: capabilities, desktopSessionActive: true,
      provisioningPending: false, sharedFolderCapabilityAdvertised: true,
      clipboardTextCapabilityAdvertised: true,
      clipboardImageCapabilityAdvertised: true,
      dynamicDisplayCapabilityAdvertised: true
    }
    File.write(ARGV.fetch(4), JSON.pretty_generate(value))
  ' "$observed" "$revision" "$factory_version" "$agent_version" "$work/observation.json"
}

verify=("$project_root/scripts/verify-omarchy-integration-observation.sh" \
  "$work/observation.json" "$revision" "$factory_version" "$agent_version")

expect_rejection() {
  local message=$1
  if "${verify[@]}" >/dev/null 2>&1; then
    echo "$message" >&2
    exit 1
  fi
}

write_observation
"${verify[@]}" >/dev/null

ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["sharedFolderCapabilityAdvertised"]=false; File.write(ARGV[0], JSON.generate(v))' "$work/observation.json"
expect_rejection "observation without shared-folder readiness was accepted"

write_observation
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["guestCapabilities"].delete("clipboard-image-v1"); File.write(ARGV[0], JSON.generate(v))' "$work/observation.json"
expect_rejection "observation with a missing capability was accepted"

write_observation
old_observed=$(date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')
ruby -rjson -e 'v=JSON.parse(File.read(ARGV[0])); v["observedAt"]=ARGV[1]; File.write(ARGV[0], JSON.generate(v))' "$work/observation.json" "$old_observed"
expect_rejection "stale observation was accepted"

write_observation
verify=("$project_root/scripts/verify-omarchy-integration-observation.sh" \
  "$work/observation.json" "$revision" wrong-factory "$agent_version")
expect_rejection "observation for a different factory image was accepted"

echo "Verified integration observation validation and rejection gates."
