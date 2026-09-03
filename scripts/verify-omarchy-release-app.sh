#!/bin/bash

set -euo pipefail

app_path=${1:-}
expected_version=${2:-}
expected_revision=${3:-}
expected_tree_state=${4:-clean}

fail() {
  echo "verify-omarchy-release-app: $*" >&2
  exit 1
}

[[ -d $app_path && ! -L $app_path ]] || fail "usage: $0 <EZVM Omarchy.app> [version] [revision] [tree-state]"
info="$app_path/Contents/Info.plist"
[[ -f $info && ! -L $info ]] || fail "Info.plist is missing or unsafe"

bundle_id=$(plutil -extract CFBundleIdentifier raw "$info")
product_name=$(plutil -extract CFBundleName raw "$info")
[[ $bundle_id == com.everettjf.ezvm.omarchy ]] || fail "unexpected bundle identifier: $bundle_id"
[[ $product_name == "EZVM Omarchy" ]] || fail "unexpected product name: $product_name"
factory_public_key=$(plutil -extract EZVMOmarchyFactoryPublicKeyBase64 raw "$info") || \
  fail "factory signing public key is missing"
[[ $factory_public_key =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "factory signing public key is malformed"
decoded_key=$(mktemp "${TMPDIR:-/tmp}/ezvm-omarchy-verify-key.XXXXXX")
trap 'rm -f "$decoded_key"' EXIT
printf '%s' "$factory_public_key" | base64 -D >"$decoded_key" 2>/dev/null || \
  fail "factory signing public key is not base64"
[[ $(wc -c <"$decoded_key" | tr -d ' ') == 32 ]] || fail "factory signing public key is not 32 bytes"
rm -f "$decoded_key"

"$(dirname -- "$0")/verify-release-metadata.sh" \
  "$app_path" "$expected_version" "$expected_revision" "$expected_tree_state" >/dev/null

entitlements=$(mktemp "${TMPDIR:-/tmp}/ezvm-omarchy-entitlements.XXXXXX")
trap 'rm -f "$decoded_key" "$entitlements"' EXIT
codesign --display --entitlements - "$app_path" >"$entitlements" 2>/dev/null
[[ -s $entitlements ]] || fail "codesign returned no entitlements"
team_identifier=$(codesign --display --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')

if grep -q '^\[Dict\]$' "$entitlements"; then
  keys=$(sed -n 's/^[[:space:]]*\[Key\] //p' "$entitlements" | LC_ALL=C sort)
  if [[ -n $team_identifier && $team_identifier != "not set" ]]; then
    expected_keys=$'com.apple.application-identifier\ncom.apple.developer.team-identifier\ncom.apple.security.virtualization'
    [[ $team_identifier == YPV49M8592 ]] || fail "unexpected TeamIdentifier"
    grep -A2 '^[[:space:]]*\[Key\] com.apple.application-identifier$' "$entitlements" | \
      grep -q '^[[:space:]]*\[String\] YPV49M8592.com.everettjf.ezvm.omarchy$' || \
      fail "application identifier does not match the Omarchy App ID"
  else
    expected_keys='com.apple.security.virtualization'
  fi
  [[ $keys == "$expected_keys" ]] || fail "release entitlement set does not match the allowlist"
  grep -A2 '^[[:space:]]*\[Key\] com.apple.security.virtualization$' "$entitlements" | \
    grep -q '^[[:space:]]*\[Bool\] true$' || fail "Virtualization entitlement is disabled"
else
  plutil -lint "$entitlements" >/dev/null
  keys=$(plutil -p "$entitlements" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | LC_ALL=C sort)
  if [[ -n $team_identifier && $team_identifier != "not set" ]]; then
    expected_keys=$'com.apple.application-identifier\ncom.apple.developer.team-identifier\ncom.apple.security.virtualization'
    [[ $(plutil -extract com.apple.application-identifier raw "$entitlements") == \
      YPV49M8592.com.everettjf.ezvm.omarchy ]] || fail "application identifier does not match"
    [[ $(plutil -extract com.apple.developer.team-identifier raw "$entitlements") == YPV49M8592 ]] || \
      fail "embedded team identifier does not match"
  else
    expected_keys='com.apple.security.virtualization'
  fi
  [[ $keys == "$expected_keys" ]] || fail "release entitlement set does not match the allowlist"
  [[ $(plutil -extract com.apple.security.virtualization raw "$entitlements") == true ]] || \
    fail "Virtualization entitlement is disabled"
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Verified EZVM Omarchy release app."
