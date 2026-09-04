#!/bin/bash

set -euo pipefail

evidence=${1:-}
app_archive=${2:-}
factory_manifest=${3:-}
factory_image=${4:-}
expected_revision=${5:-}
integration_observation=${6:-}
lifecycle_observation=${7:-}
command_super_observation=${8:-}
rollback_observation=${9:-}
full_screen_observation=${10:-}
notification_observation=${11:-}
soak_observation=${12:-}

fail() { echo "verify-omarchy-release-evidence: $*" >&2; exit 1; }

for path in "$evidence" "$app_archive" "$factory_manifest" "$factory_image" \
  "$integration_observation" "$lifecycle_observation" "$command_super_observation" \
  "$rollback_observation" "$full_screen_observation" "$notification_observation" \
  "$soak_observation"; do
  [[ -f $path && ! -L $path ]] || fail "required input is missing or unsafe: ${path:-<empty>}"
done
[[ $expected_revision =~ ^[0-9a-f]{40}$ ]] || fail "expected revision must be a full Git commit"

app_sha=$(shasum -a 256 "$app_archive" | awk '{print $1}')
manifest_sha=$(shasum -a 256 "$factory_manifest" | awk '{print $1}')
image_sha=$(shasum -a 256 "$factory_image" | awk '{print $1}')
integration_sha=$(shasum -a 256 "$integration_observation" | awk '{print $1}')
lifecycle_sha=$(shasum -a 256 "$lifecycle_observation" | awk '{print $1}')
command_super_sha=$(shasum -a 256 "$command_super_observation" | awk '{print $1}')
rollback_sha=$(shasum -a 256 "$rollback_observation" | awk '{print $1}')
full_screen_sha=$(shasum -a 256 "$full_screen_observation" | awk '{print $1}')
notification_sha=$(shasum -a 256 "$notification_observation" | awk '{print $1}')
soak_sha=$(shasum -a 256 "$soak_observation" | awk '{print $1}')
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
  "$lifecycle_observation" "$agent_version" "$expected_revision" >/dev/null
"$(dirname "$0")/verify-omarchy-notification-observation.sh" \
  "$notification_observation" "$expected_revision" >/dev/null

ruby -rjson -rtime -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong evidence schema" unless value["schemaVersion"] == 7
  abort "acceptance did not pass" unless value["result"] == "passed"
  abort "wrong source revision" unless value["sourceRevision"] == ARGV.fetch(1)
  abort "wrong app archive digest" unless value["appArchiveSHA256"] == ARGV.fetch(2)
  abort "wrong factory manifest digest" unless value["factoryManifestSHA256"] == ARGV.fetch(3)
  abort "wrong factory image digest" unless value["factoryImageSHA256"] == ARGV.fetch(4)
  abort "wrong integration observation digest" unless value["integrationObservationSHA256"] == ARGV.fetch(5)
  abort "wrong lifecycle observation digest" unless value["lifecycleObservationSHA256"] == ARGV.fetch(6)
  abort "wrong Command/Super observation digest" unless value["commandSuperObservationSHA256"] == ARGV.fetch(7)
  abort "wrong rollback observation digest" unless value["rollbackObservationSHA256"] == ARGV.fetch(8)
  abort "wrong full-screen observation digest" unless value["fullScreenObservationSHA256"] == ARGV.fetch(9)
  abort "wrong notification observation digest" unless value["notificationObservationSHA256"] == ARGV.fetch(10)
  abort "wrong soak observation digest" unless value["soakObservationSHA256"] == ARGV.fetch(11)
  abort "wrong host architecture" unless value["hostArchitecture"] == "arm64"
  abort "host OS build is missing" unless value["hostOSBuild"].is_a?(String) && !value["hostOSBuild"].empty?
  started = Time.iso8601(value.fetch("startedAt"))
  ended = Time.iso8601(value.fetch("endedAt"))
  abort "invalid acceptance interval" unless ended >= started
  abort "acceptance evidence is older than 14 days" if Time.now.utc - ended > 14 * 24 * 60 * 60
  integration = JSON.parse(File.read(ARGV.fetch(12)))
  lifecycle = JSON.parse(File.read(ARGV.fetch(13)))
  command_super = JSON.parse(File.read(ARGV.fetch(14)))
  rollback = JSON.parse(File.read(ARGV.fetch(15)))
  full_screen = JSON.parse(File.read(ARGV.fetch(16)))
  notification = JSON.parse(File.read(ARGV.fetch(17)))
  soak = JSON.parse(File.read(ARGV.fetch(18)))
  abort "wrong Command/Super schema" unless command_super["schemaVersion"] == 1
  abort "wrong Command/Super source revision" unless command_super["sourceRevision"] == ARGV.fetch(1)
  abort "Command event tap was not enabled" unless command_super["eventTapEnabled"] == true
  abort "Command+Space down/up was not captured" unless command_super["commandSpaceKeyDownAndUpCaptured"] == true
  abort "Host app lost focus after Command+Space" unless command_super["applicationActiveAfterCapture"] == true
  abort "VM window lost key status after Command+Space" unless command_super["virtualMachineWindowKeyAfterCapture"] == true
  command_observed = Time.iso8601(command_super.fetch("observedAt"))
  abort "wrong rollback schema" unless rollback["schemaVersion"] == 1
  abort "wrong rollback source revision" unless rollback["sourceRevision"] == ARGV.fetch(1)
  abort "rollback snapshot was not protected" unless rollback["snapshotProtected"] == true
  abort "rollback did not restore snapshot bytes" unless rollback["restoredMatchesSnapshot"] == true
  abort "workspace was not ready after rollback" unless rollback["workspaceReadyAfterRestore"] == true
  digest_pattern = /\A[0-9a-f]{64}\z/
  before_digest = rollback["beforeSHA256"]
  update_digest = rollback["simulatedUpdateSHA256"]
  restored_digest = rollback["restoredSHA256"]
  abort "rollback digests are malformed" unless [before_digest, update_digest, restored_digest].all? { |digest| digest_pattern.match?(digest) }
  abort "rollback digests do not prove reversal" unless before_digest == restored_digest && before_digest != update_digest
  rollback_observed = Time.iso8601(rollback.fetch("observedAt"))
  abort "wrong full-screen schema" unless full_screen["schemaVersion"] == 1
  abort "wrong full-screen source revision" unless full_screen["sourceRevision"] == ARGV.fetch(1)
  abort "full-screen entry and exit were not observed" unless full_screen["enteredAndExitedFullScreen"] == true
  abort "Host app lost focus after full-screen" unless full_screen["applicationActiveAfterExit"] == true
  abort "VM window lost key status after full-screen" unless full_screen["virtualMachineWindowKeyAfterExit"] == true
  abort "VM view lost focus after full-screen" unless full_screen["virtualMachineViewFocusedAfterExit"] == true
  full_screen_entered = Time.iso8601(full_screen.fetch("enteredAt"))
  full_screen_exited = Time.iso8601(full_screen.fetch("exitedAt"))
  abort "full-screen exit did not follow entry" unless full_screen_exited >= full_screen_entered
  notification_observed = Time.iso8601(notification.fetch("observedAt"))
  abort "wrong soak schema" unless soak["schemaVersion"] == 1
  abort "wrong soak source revision" unless soak["sourceRevision"] == ARGV.fetch(1)
  abort "desktop was not continuously active" unless soak["desktopContinuouslyActive"] == true
  abort "provisioning was not continuously complete" unless soak["provisioningContinuouslyComplete"] == true
  soak_started = Time.iso8601(soak.fetch("startedAt"))
  soak_ended = Time.iso8601(soak.fetch("endedAt"))
  soak_duration = soak["continuousOperationSeconds"]
  abort "continuous operation was shorter than 24 hours" unless soak_duration.is_a?(Integer) && soak_duration >= 86_400
  abort "soak interval does not match timestamps" unless soak_ended - soak_started >= soak_duration
  max_gap = soak["maximumSampleGapSeconds"]
  abort "soak heartbeat gap exceeded 120 seconds" unless max_gap.is_a?(Integer) && max_gap >= 0 && max_gap <= 120
  sample_count = soak["sampleCount"]
  abort "soak has too few independent heartbeat samples" unless sample_count.is_a?(Integer) && sample_count >= (soak_duration / 120)
  first_uptime = soak["firstGuestUptimeSeconds"]
  last_uptime = soak["lastGuestUptimeSeconds"]
  abort "Guest uptime did not cover the soak" unless first_uptime.is_a?(Integer) && last_uptime.is_a?(Integer) && last_uptime >= first_uptime && last_uptime - first_uptime >= soak_duration - 120
  workspace_created = Time.iso8601(integration.fetch("workspaceCreatedAt"))
  provisioning = Time.iso8601(lifecycle.fetch("firstProvisioningPendingObservedAt"))
  integration_observed = Time.iso8601(integration.fetch("observedAt"))
  abort "workspace predates the acceptance interval" if workspace_created < started - 300
  abort "owner provisioning predates workspace creation" if provisioning < workspace_created
  abort "integration observation exceeds acceptance interval" if integration_observed > ended + 300
  abort "Command/Super observation predates acceptance" if command_observed < started - 300
  abort "Command/Super observation exceeds acceptance interval" if command_observed > ended + 300
  abort "rollback observation predates acceptance" if rollback_observed < started - 300
  abort "rollback observation exceeds acceptance interval" if rollback_observed > ended + 300
  abort "full-screen observation predates acceptance" if full_screen_entered < started - 300
  abort "full-screen observation exceeds acceptance interval" if full_screen_exited > ended + 300
  abort "notification observation predates acceptance" if notification_observed < started - 300
  abort "notification observation exceeds acceptance interval" if notification_observed > ended + 300
  abort "soak predates acceptance" if soak_started < started - 300
  abort "soak exceeds acceptance interval" if soak_ended > ended + 300
  abort "legacy hand-authored scenarios remain" unless value["scenarios"] == {}
' "$evidence" "$expected_revision" "$app_sha" "$manifest_sha" "$image_sha" \
  "$integration_sha" "$lifecycle_sha" "$command_super_sha" "$rollback_sha" "$full_screen_sha" \
  "$notification_sha" "$soak_sha" \
  "$integration_observation" "$lifecycle_observation" "$command_super_observation" \
  "$rollback_observation" "$full_screen_observation" "$notification_observation" "$soak_observation"

echo "Verified EZVM Omarchy real-guest release evidence."
