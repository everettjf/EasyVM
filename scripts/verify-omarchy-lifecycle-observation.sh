#!/bin/bash

set -euo pipefail

observation=${1:-}
expected_agent_version=${2:-}

fail() { echo "verify-omarchy-lifecycle-observation: $*" >&2; exit 1; }

[[ -f $observation && ! -L $observation ]] || fail "observation is missing or unsafe"
[[ -n $expected_agent_version ]] || fail "expected Guest Agent version is required"

ruby -rjson -rtime -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong lifecycle schema" unless value["schemaVersion"] == 4
  abort "wrong Guest Agent version" unless value["guestAgentVersion"] == ARGV.fetch(1)

  locked = Time.iso8601(value.fetch("firstLockedObservedAt"))
  recovered = Time.iso8601(value.fetch("firstActiveAfterLockedObservedAt"))
  pause_requested = Time.iso8601(value.fetch("firstPauseRequestedAt"))
  paused = Time.iso8601(value.fetch("firstPausedAt"))
  resumed = Time.iso8601(value.fetch("firstResumedAt"))
  active_after_resume = Time.iso8601(value.fetch("firstActiveAfterResumeObservedAt"))
  host_sleep = Time.iso8601(value.fetch("firstHostSleepObservedAt"))
  host_wake = Time.iso8601(value.fetch("firstHostWakeObservedAt"))
  active_after_wake = Time.iso8601(value.fetch("firstActiveAfterHostWakeObservedAt"))
  abort "desktop recovery predates lock observation" unless recovered >= locked
  abort "pause request predates desktop recovery" unless pause_requested >= recovered
  abort "pause confirmation predates request" unless paused >= pause_requested
  abort "resume confirmation predates pause" unless resumed >= paused
  abort "integration recovery predates resume" unless active_after_resume >= resumed
  abort "host sleep predates pause/resume recovery" unless host_sleep >= active_after_resume
  abort "host wake predates host sleep" unless host_wake >= host_sleep
  abort "integration recovery predates host wake" unless active_after_wake >= host_wake
  abort "lock observation is in the future" if locked > Time.now.utc + 300
  abort "desktop recovery is in the future" if recovered > Time.now.utc + 300
  abort "desktop recovery is older than 24 hours" if Time.now.utc - recovered > 86_400
  abort "pause/resume recovery is older than 24 hours" if Time.now.utc - active_after_resume > 86_400
  abort "host wake recovery is older than 24 hours" if Time.now.utc - active_after_wake > 86_400
  abort "desktop is not active after recovery" unless value["lastDesktopSessionActive"] == true
  abort "owner provisioning is still pending" unless value["lastProvisioningPending"] == false
' "$observation" "$expected_agent_version"

echo "Verified EZVM Omarchy lock-to-active lifecycle observation."
