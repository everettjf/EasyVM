#!/bin/bash

set -euo pipefail

evidence=${1:-}
app_archive=${2:-}
factory_manifest=${3:-}
factory_image=${4:-}
expected_revision=${5:-}
integration_observation=${6:-}
lifecycle_observation=${7:-}

fail() { echo "verify-omarchy-release-evidence: $*" >&2; exit 1; }

for path in "$evidence" "$app_archive" "$factory_manifest" "$factory_image" \
  "$integration_observation" "$lifecycle_observation"; do
  [[ -f $path && ! -L $path ]] || fail "required input is missing or unsafe: ${path:-<empty>}"
done
[[ $expected_revision =~ ^[0-9a-f]{40}$ ]] || fail "expected revision must be a full Git commit"

app_sha=$(shasum -a 256 "$app_archive" | awk '{print $1}')
manifest_sha=$(shasum -a 256 "$factory_manifest" | awk '{print $1}')
image_sha=$(shasum -a 256 "$factory_image" | awk '{print $1}')
integration_sha=$(shasum -a 256 "$integration_observation" | awk '{print $1}')
lifecycle_sha=$(shasum -a 256 "$lifecycle_observation" | awk '{print $1}')
manifest_image_sha=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("payload").fetch("imageSHA256")' "$factory_manifest") || \
  fail "factory manifest is not valid JSON"
factory_version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("payload").fetch("imageVersion")' "$factory_manifest") || \
  fail "factory manifest has no image version"
agent_version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("payload").fetch("guestAgentVersion")' "$factory_manifest") || \
  fail "factory manifest has no Guest Agent version"
manifest_image_sha=$(printf '%s' "$manifest_image_sha" | tr '[:upper:]' '[:lower:]')
[[ $manifest_image_sha == "$image_sha" ]] || fail "factory image does not match its manifest"

"$(dirname "$0")/verify-omarchy-integration-observation.sh" \
  "$integration_observation" "$expected_revision" "$factory_version" "$agent_version" >/dev/null
"$(dirname "$0")/verify-omarchy-lifecycle-observation.sh" \
  "$lifecycle_observation" "$agent_version" >/dev/null

ruby -rjson -rtime -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong evidence schema" unless value["schemaVersion"] == 2
  abort "acceptance did not pass" unless value["result"] == "passed"
  abort "wrong source revision" unless value["sourceRevision"] == ARGV.fetch(1)
  abort "wrong app archive digest" unless value["appArchiveSHA256"] == ARGV.fetch(2)
  abort "wrong factory manifest digest" unless value["factoryManifestSHA256"] == ARGV.fetch(3)
  abort "wrong factory image digest" unless value["factoryImageSHA256"] == ARGV.fetch(4)
  abort "wrong integration observation digest" unless value["integrationObservationSHA256"] == ARGV.fetch(5)
  abort "wrong lifecycle observation digest" unless value["lifecycleObservationSHA256"] == ARGV.fetch(6)
  abort "wrong host architecture" unless value["hostArchitecture"] == "arm64"
  abort "host OS build is missing" unless value["hostOSBuild"].is_a?(String) && !value["hostOSBuild"].empty?
  started = Time.iso8601(value.fetch("startedAt"))
  ended = Time.iso8601(value.fetch("endedAt"))
  abort "invalid acceptance interval" unless ended >= started
  abort "acceptance evidence is older than 14 days" if Time.now.utc - ended > 14 * 24 * 60 * 60
  required = %w[
    cleanInstall ownerProvisioning commandSuper clipboardText clipboardImage
    fileImport guestRestart agentRestart
    updateRollback continuousOperation
  ]
  scenarios = value.fetch("scenarios")
  missing = required.reject { |name| scenarios[name] == true }
  abort "required scenarios did not pass: #{missing.join(", ")}" unless missing.empty?
  duration = value["continuousOperationSeconds"]
  abort "continuous operation was shorter than 24 hours" unless duration.is_a?(Integer) && duration >= 86_400
' "$evidence" "$expected_revision" "$app_sha" "$manifest_sha" "$image_sha" \
  "$integration_sha" "$lifecycle_sha"

echo "Verified EZVM Omarchy real-guest release evidence."
