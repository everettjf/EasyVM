#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-release-gates.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
app="$fixture/EZVM Omarchy.app"
info="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/EZVM Omarchy"
revision=0123456789abcdef0123456789abcdef01234567
public_key='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='

make_fixture() {
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp /usr/bin/true "$executable"
  plutil -create xml1 "$info"
  plutil -insert CFBundleExecutable -string 'EZVM Omarchy' "$info"
  plutil -insert CFBundleIdentifier -string com.everettjf.ezvm.omarchy "$info"
  plutil -insert CFBundleName -string 'EZVM Omarchy' "$info"
  plutil -insert CFBundlePackageType -string APPL "$info"
  plutil -insert CFBundleShortVersionString -string 0.1.0 "$info"
  plutil -insert CFBundleVersion -string 1 "$info"
  plutil -insert EZVMOmarchyFactoryPublicKeyBase64 -string "$public_key" "$info"
  plutil -insert EZVMSourceRevision -string "$revision" "$info"
  plutil -insert EZVMSourceTreeState -string clean "$info"
  codesign --force --deep --sign - \
    --entitlements "$project_root/EZVMOmarchy/Resources/EZVMOmarchy.entitlements" \
    --timestamp=none "$app" >/dev/null
}

expect_rejection() {
  local label=$1
  if "$project_root/scripts/verify-omarchy-release-app.sh" \
    "$app" 0.1.0 "$revision" clean >/dev/null 2>&1; then
    echo "release verifier accepted $label" >&2
    exit 1
  fi
}

make_fixture
"$project_root/scripts/verify-omarchy-release-app.sh" \
  "$app" 0.1.0 "$revision" clean >/dev/null

if EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
  "$project_root/scripts/verify-omarchy-release-app.sh" \
    "$app" 0.1.0 "$revision" clean >/dev/null 2>&1; then
  echo "release verifier accepted a candidate from another factory trust root" >&2
  exit 1
fi

plutil -replace CFBundleIdentifier -string com.everettjf.ezvm "$info"
expect_rejection 'the general EZVM bundle identifier'

make_fixture
plutil -replace EZVMOmarchyFactoryPublicKeyBase64 -string invalid "$info"
expect_rejection 'a malformed factory public key'

make_fixture
extra_entitlements="$fixture/extra.entitlements"
cp "$project_root/EZVMOmarchy/Resources/EZVMOmarchy.entitlements" "$extra_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.developer.networking.vmnet bool true' "$extra_entitlements"
codesign --force --deep --sign - --entitlements "$extra_entitlements" --timestamp=none "$app" >/dev/null
expect_rejection 'an undeclared VMNet entitlement'
