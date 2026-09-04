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
if [[ -n ${EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64:-} ]]; then
  [[ $factory_public_key == "$EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64" ]] || \
    fail "embedded factory signing key does not match the selected release channel"
fi
decoded_key=$(mktemp "${TMPDIR:-/tmp}/ezvm-omarchy-verify-key.XXXXXX")
icon_probe=$(mktemp -d "${TMPDIR:-/tmp}/ezvm-omarchy-verify-icon.XXXXXX")
trap 'rm -f "$decoded_key"; rm -rf "$icon_probe"' EXIT
printf '%s' "$factory_public_key" | base64 -D >"$decoded_key" 2>/dev/null || \
  fail "factory signing public key is not base64"
[[ $(wc -c <"$decoded_key" | tr -d ' ') == 32 ]] || fail "factory signing public key is not 32 bytes"
rm -f "$decoded_key"

# Do not let an otherwise valid release silently fall back to a generic app
# icon. Checking the compiled ICNS (rather than only the source asset catalog)
# proves that the icon survived Xcode export and archive extraction.
icon_name=$(plutil -extract CFBundleIconName raw "$info") || \
  fail "application icon name is missing"
icon_file=$(plutil -extract CFBundleIconFile raw "$info") || \
  fail "application icon file is missing"
[[ $icon_name == AppIcon && $icon_file == AppIcon ]] || \
  fail "unexpected application icon declaration: name=$icon_name file=$icon_file"
compiled_icon="$app_path/Contents/Resources/AppIcon.icns"
[[ -f $compiled_icon && ! -L $compiled_icon ]] || fail "compiled AppIcon.icns is missing or unsafe"
iconutil -c iconset "$compiled_icon" -o "$icon_probe/AppIcon.iconset" 2>/dev/null || \
  fail "compiled AppIcon.icns is invalid"
for representation in icon_16x16.png icon_16x16@2x.png icon_128x128.png icon_128x128@2x.png; do
  [[ -s "$icon_probe/AppIcon.iconset/$representation" ]] || \
    fail "compiled AppIcon.icns is missing $representation"
done
compiled_assets="$app_path/Contents/Resources/Assets.car"
[[ -f $compiled_assets && ! -L $compiled_assets ]] || fail "compiled Assets.car is missing or unsafe"
xcrun assetutil --info "$compiled_assets" >"$icon_probe/assets.json" 2>/dev/null || \
  fail "compiled Assets.car is invalid"
ruby -rjson -e '
  assets = JSON.parse(File.read(ARGV.fetch(0)))
  widths = assets.each_with_object([]) do |asset, values|
    values << asset["PixelWidth"] if asset["Name"] == "AppIcon" && asset["AssetType"] == "Icon Image"
  end.compact.uniq
  expected = [16, 32, 64, 128, 256, 512, 1024]
  abort "compiled AppIcon lacks full-resolution representations" unless (expected - widths).empty?
' "$icon_probe/assets.json" || fail "compiled AppIcon lacks a complete 16–1024 px asset set"

"$(dirname -- "$0")/verify-release-metadata.sh" \
  "$app_path" "$expected_version" "$expected_revision" "$expected_tree_state" >/dev/null

entitlements=$(mktemp "${TMPDIR:-/tmp}/ezvm-omarchy-entitlements.XXXXXX")
trap 'rm -f "$decoded_key" "$entitlements"; rm -rf "$icon_probe"' EXIT
codesign --display --entitlements - "$app_path" >"$entitlements" 2>/dev/null
[[ -s $entitlements ]] || fail "codesign returned no entitlements"
team_identifier=$(codesign --display --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')
"$(dirname -- "$0")/verify-omarchy-entitlements.sh" "$entitlements" "${team_identifier:-not set}"

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Verified EZVM Omarchy release app."
