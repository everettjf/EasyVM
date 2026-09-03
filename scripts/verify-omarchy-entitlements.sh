#!/bin/bash

set -euo pipefail

entitlements=${1:-}
team_identifier=${2:-not set}

fail() {
  echo "verify-omarchy-entitlements: $*" >&2
  exit 1
}

[[ -f $entitlements && ! -L $entitlements ]] || \
  fail "usage: $0 <codesign-entitlements-output> [TeamIdentifier]"

expected_minimal='com.apple.security.virtualization'
expected_development=$'com.apple.application-identifier\ncom.apple.developer.team-identifier\ncom.apple.security.virtualization'

if grep -q '^\[Dict\]$' "$entitlements"; then
  keys=$(sed -n 's/^[[:space:]]*\[Key\] //p' "$entitlements" | LC_ALL=C sort)
  if grep -q '^[[:space:]]*\[Key\] com.apple.application-identifier$' "$entitlements"; then
    expected_keys=$expected_development
    grep -A2 '^[[:space:]]*\[Key\] com.apple.application-identifier$' "$entitlements" | \
      grep -q '^[[:space:]]*\[String\] YPV49M8592.com.everettjf.ezvm.omarchy$' || \
      fail "application identifier does not match the Omarchy App ID"
    grep -A2 '^[[:space:]]*\[Key\] com.apple.developer.team-identifier$' "$entitlements" | \
      grep -q '^[[:space:]]*\[String\] YPV49M8592$' || \
      fail "embedded team identifier does not match"
  else
    expected_keys=$expected_minimal
  fi
  [[ $keys == "$expected_keys" ]] || fail "release entitlement set does not match the allowlist"
  grep -A2 '^[[:space:]]*\[Key\] com.apple.security.virtualization$' "$entitlements" | \
    grep -q '^[[:space:]]*\[Bool\] true$' || fail "Virtualization entitlement is disabled"
else
  plutil -lint "$entitlements" >/dev/null
  keys=$(plutil -p "$entitlements" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | LC_ALL=C sort)
  if [[ $keys == *com.apple.application-identifier* ]]; then
    expected_keys=$expected_development
    [[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements") == \
      YPV49M8592.com.everettjf.ezvm.omarchy ]] || fail "application identifier does not match"
    [[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements") == YPV49M8592 ]] || \
      fail "embedded team identifier does not match"
  else
    expected_keys=$expected_minimal
  fi
  [[ $keys == "$expected_keys" ]] || fail "release entitlement set does not match the allowlist"
  [[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.virtualization' "$entitlements") == true ]] || \
    fail "Virtualization entitlement is disabled"
fi

if [[ -n $team_identifier && $team_identifier != "not set" ]]; then
  [[ $team_identifier == YPV49M8592 ]] || fail "unexpected TeamIdentifier"
fi
