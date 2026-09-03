#!/bin/bash

set -euo pipefail

observation=${1:-}
expected_revision=${2:-}
expected_factory_version=${3:-}
expected_agent_version=${4:-}

fail() { echo "verify-omarchy-integration-observation: $*" >&2; exit 1; }

[[ -f $observation && ! -L $observation ]] || fail "observation is missing or unsafe"
[[ $expected_revision =~ ^[0-9a-f]{40}$ ]] || fail "expected revision must be a full Git commit"
[[ -n $expected_factory_version ]] || fail "expected factory version is required"

ruby -rjson -rtime -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong observation schema" unless value["schemaVersion"] == 2
  abort "wrong source revision" unless value["sourceRevision"] == ARGV.fetch(1)
  abort "wrong factory image version" unless value["factoryImageVersion"] == ARGV.fetch(2)
  expected_agent = ARGV.fetch(3)
  unless expected_agent.empty?
    abort "wrong Guest Agent version" unless value["guestAgentVersion"] == expected_agent
  end

  observed = Time.iso8601(value.fetch("observedAt"))
  age = Time.now.utc - observed
  abort "observation timestamp is in the future" if age < -300
  abort "observation is older than 24 hours" if age > 86_400
  abort "guest hostname is missing" unless value["guestHostName"].is_a?(String) && !value["guestHostName"].empty?
  abort "guest address is missing" unless value["guestAddresses"].is_a?(Array) && !value["guestAddresses"].empty?
  abort "desktop session is not active" unless value["desktopSessionActive"] == true
  abort "owner provisioning is still pending" unless value["provisioningPending"] == false

  capabilities = value.fetch("guestCapabilities")
  required = value.fetch("requiredCapabilities")
  abort "guest capabilities are malformed" unless capabilities.is_a?(Array) && capabilities.all? { |item| item.is_a?(String) }
  abort "required capabilities are malformed" unless required.is_a?(Array) && required.all? { |item| item.is_a?(String) }
  missing = required - capabilities
  abort "required capabilities are missing: #{missing.join(", ")}" unless missing.empty?

  advertised = {
    "sharedFolderCapabilityAdvertised" => "shared-folders-v1",
    "clipboardTextCapabilityAdvertised" => "clipboard-text-v1",
    "clipboardImageCapabilityAdvertised" => "clipboard-image-v1",
    "dynamicDisplayCapabilityAdvertised" => "dynamic-display-v1"
  }
  advertised.each do |field, capability|
    abort "#{field} was not advertised" unless value[field] == true
    abort "#{field} lacks #{capability}" unless capabilities.include?(capability)
  end
  abort "shared-folder round trip did not pass" unless value["sharedFolderRoundTripPassed"] == true
  round_trip_at = Time.iso8601(value.fetch("sharedFolderRoundTripObservedAt"))
  abort "shared-folder result predates observation window" if round_trip_at < observed - 300
  abort "shared-folder result is in the future" if round_trip_at > Time.now.utc + 300
  %w[hostToGuestSHA256 guestToHostSHA256].each do |field|
    abort "invalid #{field}" unless value[field].is_a?(String) && value[field].match?(/\A[0-9a-f]{64}\z/)
  end
' "$observation" "$expected_revision" "$expected_factory_version" "$expected_agent_version"

echo "Verified EZVM Omarchy integration readiness observation."
