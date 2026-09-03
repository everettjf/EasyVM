#!/bin/bash

set -euo pipefail

observation=${1:-}
expected_agent_version=${2:-}

fail() { echo "verify-omarchy-lifecycle-observation: $*" >&2; exit 1; }

[[ -f $observation && ! -L $observation ]] || fail "observation is missing or unsafe"
[[ -n $expected_agent_version ]] || fail "expected Guest Agent version is required"

ruby -rjson -rtime -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong lifecycle schema" unless value["schemaVersion"] == 2
  abort "wrong Guest Agent version" unless value["guestAgentVersion"] == ARGV.fetch(1)

  locked = Time.iso8601(value.fetch("firstLockedObservedAt"))
  recovered = Time.iso8601(value.fetch("firstActiveAfterLockedObservedAt"))
  abort "desktop recovery predates lock observation" unless recovered >= locked
  abort "lock observation is in the future" if locked > Time.now.utc + 300
  abort "desktop recovery is in the future" if recovered > Time.now.utc + 300
  abort "desktop recovery is older than 24 hours" if Time.now.utc - recovered > 86_400
  abort "desktop is not active after recovery" unless value["lastDesktopSessionActive"] == true
  abort "owner provisioning is still pending" unless value["lastProvisioningPending"] == false
' "$observation" "$expected_agent_version"

echo "Verified EZVM Omarchy lock-to-active lifecycle observation."
