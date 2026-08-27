#!/bin/bash

set -euo pipefail

app_path="${1:-}"

fail() {
  echo "verify-production-entitlements: $*" >&2
  exit 1
}

[[ -n "$app_path" ]] || fail "usage: $0 <EZVM.app>"
[[ -d "$app_path" ]] || fail "application not found: $app_path"

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/ezvm-entitlements.XXXXXX")"
cleanup() {
  rm -f "$entitlements_file"
}
trap cleanup EXIT

# Xcode 27's codesign prints a structured [Dict]/[Key]/[Bool] representation
# for `--entitlements -`; older toolchains print an XML plist. Support both so
# the release gate also runs on every supported build host.
codesign --display --entitlements - "$app_path" >"$entitlements_file" 2>/dev/null
[[ -s "$entitlements_file" ]] || fail "codesign returned no entitlements"

if grep -q '^\[Dict\]$' "$entitlements_file"; then
  entitlement_keys="$(sed -n 's/^[[:space:]]*\[Key\] //p' "$entitlements_file")"
  [[ "$entitlement_keys" == "com.apple.security.virtualization" ]] || {
    cat "$entitlements_file" >&2
    fail "the release entitlement set does not match the allowlist"
  }
  grep -A2 '^[[:space:]]*\[Key\] com.apple.security.virtualization$' "$entitlements_file" | \
    grep -q '^[[:space:]]*\[Bool\] true$' || fail "virtualization entitlement is not enabled"
else
  plutil -lint "$entitlements_file" >/dev/null
  entitlement_keys="$(plutil -p "$entitlements_file" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p')"
  [[ "$entitlement_keys" == "com.apple.security.virtualization" ]] || {
    plutil -p "$entitlements_file" >&2
    fail "the release entitlement set does not match the allowlist"
  }
  virtualization_value="$(plutil -extract com.apple.security.virtualization raw "$entitlements_file")"
  [[ "$virtualization_value" == "true" ]] || fail "virtualization entitlement is not enabled"
fi

echo "Verified production entitlement allowlist."
