#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-evidence.XXXXXX")
trap 'rm -rf "$work"' EXIT
revision=0123456789abcdef0123456789abcdef01234567
printf app >"$work/app.zip"
printf image >"$work/factory.asif"
image_sha=$(shasum -a 256 "$work/factory.asif" | awk '{print $1}')
factory_version=factory-test-1
agent_version=agent-test-1
printf '{"payload":{"imageSHA256":"%s","imageVersion":"%s","guestAgentVersion":"%s"}}\n' \
  "$image_sha" "$factory_version" "$agent_version" >"$work/manifest.json"
app_sha=$(shasum -a 256 "$work/app.zip" | awk '{print $1}')
manifest_sha=$(shasum -a 256 "$work/manifest.json" | awk '{print $1}')
started=$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')
ended=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

ruby -rjson -e '
  capabilities = %w[
    agent-restart-v1 clipboard-image-v1 clipboard-text-v1 desktop-input-v1 dynamic-display-v1
    shared-folders-v1 shutdown-v1
  ]
  value = {
    schemaVersion: 5, observedAt: ARGV.fetch(0), sourceRevision: ARGV.fetch(1),
    factoryImageVersion: ARGV.fetch(2), omarchyRevision: "omarchy-test-1",
    guestAgentVersion: ARGV.fetch(3), guestHostName: "omarchy",
    guestAddresses: ["192.0.2.2"], guestCapabilities: capabilities,
    requiredCapabilities: capabilities, desktopSessionActive: true,
    provisioningPending: false, sharedFolderCapabilityAdvertised: true,
    clipboardTextCapabilityAdvertised: true, clipboardImageCapabilityAdvertised: true,
    dynamicDisplayCapabilityAdvertised: true, sharedFolderRoundTripPassed: true,
    sharedFolderRoundTripObservedAt: ARGV.fetch(0), hostToGuestSHA256: "a" * 64,
    guestToHostSHA256: "b" * 64, clipboardRoundTripPassed: true,
    fileImportPassed: true, fileImportObservedAt: ARGV.fetch(0), importedFileSHA256: "c" * 64,
    clipboardRoundTripObservedAt: ARGV.fetch(0), hostToGuestTextSHA256: "c" * 64,
    guestToHostTextSHA256: "d" * 64, hostToGuestImageSHA256: "e" * 64,
    guestToHostImageSHA256: "f" * 64, dynamicDisplayRoundTripPassed: true,
    dynamicDisplayRoundTripObservedAt: ARGV.fetch(0),
    guestDisplayBefore: {width: 1920, height: 1200},
    guestDisplayAfter: {width: 880, height: 560}, hostViewAfter: {width: 880, height: 560}
  }
  File.write(ARGV.fetch(4), JSON.generate(value))
' "$ended" "$revision" "$factory_version" "$agent_version" "$work/integration.json"

ruby -rjson -e '
  value = {
    schemaVersion: 5, firstProvisioningPendingObservedAt: ARGV.fetch(0),
    firstLockedObservedAt: ARGV.fetch(0),
    firstActiveObservedAt: ARGV.fetch(0), firstActiveAfterLockedObservedAt: ARGV.fetch(0),
    firstPauseRequestedAt: ARGV.fetch(0), firstPausedAt: ARGV.fetch(0),
    firstResumedAt: ARGV.fetch(0), firstActiveAfterResumeObservedAt: ARGV.fetch(0),
    firstAgentRestartRequestedAt: ARGV.fetch(0), firstAgentDisconnectedAfterRestartAt: ARGV.fetch(0),
    firstAgentRecoveredAt: ARGV.fetch(0), agentBootIDBeforeRestart: "boot-before", agentBootIDAfterRestart: "boot-before",
    agentInstanceIDBeforeRestart: "instance-before", agentInstanceIDAfterRestart: "instance-after",
    firstGuestRestartRequestedAt: ARGV.fetch(0), firstGuestDisconnectedAfterRestartAt: ARGV.fetch(0),
    firstGuestRecoveredAt: ARGV.fetch(0), guestBootIDBeforeRestart: "boot-before",
    guestBootIDAfterRestart: "boot-after",
    firstHostSleepObservedAt: ARGV.fetch(0), firstHostWakeObservedAt: ARGV.fetch(0),
    firstActiveAfterHostWakeObservedAt: ARGV.fetch(0),
    lastObservedAt: ARGV.fetch(0), lastDesktopSessionActive: true,
    lastProvisioningPending: false, guestAgentVersion: ARGV.fetch(1)
  }
  File.write(ARGV.fetch(2), JSON.generate(value))
' "$ended" "$agent_version" "$work/lifecycle.json"
integration_sha=$(shasum -a 256 "$work/integration.json" | awk '{print $1}')
lifecycle_sha=$(shasum -a 256 "$work/lifecycle.json" | awk '{print $1}')
cp "$work/integration.json" "$work/integration.valid.json"
cp "$work/lifecycle.json" "$work/lifecycle.valid.json"

write_evidence() {
  local result=${1:-passed}
  ruby -rjson -e '
    scenarios = %w[
      cleanInstall commandSuper
      updateRollback continuousOperation
    ].to_h { |name| [name, true] }
    value = {
      schemaVersion: 2, result: ARGV.fetch(0), sourceRevision: ARGV.fetch(1),
      appArchiveSHA256: ARGV.fetch(2), factoryManifestSHA256: ARGV.fetch(3),
      factoryImageSHA256: ARGV.fetch(4), hostArchitecture: "arm64",
      integrationObservationSHA256: ARGV.fetch(5), lifecycleObservationSHA256: ARGV.fetch(6),
      hostOSBuild: "test-build", startedAt: ARGV.fetch(7), endedAt: ARGV.fetch(8),
      continuousOperationSeconds: 86_400, scenarios: scenarios
    }
    File.write(ARGV.fetch(9), JSON.pretty_generate(value))
  ' "$result" "$revision" "$app_sha" "$manifest_sha" "$image_sha" \
    "$integration_sha" "$lifecycle_sha" "$started" "$ended" "$work/evidence.json"
}

verify=("$project_root/scripts/verify-omarchy-release-evidence.sh" "$work/evidence.json" \
  "$work/app.zip" "$work/manifest.json" "$work/factory.asif" "$revision" \
  "$work/integration.json" "$work/lifecycle.json")
write_evidence
"${verify[@]}" >/dev/null

write_evidence failed
if "${verify[@]}" >/dev/null 2>&1; then
  echo "failed acceptance evidence was accepted" >&2
  exit 1
fi

write_evidence
printf tampered >>"$work/app.zip"
if "${verify[@]}" >/dev/null 2>&1; then
  echo "evidence for a different application archive was accepted" >&2
  exit 1
fi

printf app >"$work/app.zip"
printf tampered >>"$work/integration.json"
if "${verify[@]}" >/dev/null 2>&1; then
  echo "evidence with a tampered integration observation was accepted" >&2
  exit 1
fi

cp "$work/integration.valid.json" "$work/integration.json"
printf tampered >>"$work/lifecycle.json"
if "${verify[@]}" >/dev/null 2>&1; then
  echo "evidence with a tampered lifecycle observation was accepted" >&2
  exit 1
fi

echo "Verified EZVM Omarchy release evidence binding and rejection gates."
