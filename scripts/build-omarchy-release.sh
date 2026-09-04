#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:-}
output_dir=${2:-"$project_root/dist"}
derived_data=${EZVM_OMARCHY_DERIVED_DATA:-}
factory_public_key=${EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64:-}

if [[ -z $version ]]; then
  echo "usage: $0 <version> [output-directory]" >&2
  exit 64
fi
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "invalid release version: $version" >&2
  exit 64
}
[[ $factory_public_key =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  echo "EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64 must contain a 32-byte Ed25519 public key" >&2
  exit 78
}
decoded_key=$(mktemp "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-public-key.XXXXXX")
trap 'rm -f "$decoded_key"' EXIT
printf '%s' "$factory_public_key" | base64 -D >"$decoded_key" 2>/dev/null || {
  echo "EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64 is invalid base64" >&2
  exit 78
}
[[ $(wc -c <"$decoded_key" | tr -d ' ') == 32 ]] || {
  echo "EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64 must decode to 32 bytes" >&2
  exit 78
}

source_revision=$(git -C "$project_root" rev-parse HEAD)
source_tree_state=clean
[[ -z $(git -C "$project_root" status --porcelain) ]] || source_tree_state=dirty
mkdir -p "$output_dir"
if [[ -z $derived_data ]]; then
  derived_data=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-release-derived.XXXXXX")
fi
[[ ! -e "$derived_data/Build/Products/Release/EZVM Omarchy.app" ]] || {
  echo "release derived data must be empty: $derived_data" >&2
  exit 65
}

project_file="$project_root/EZVMOmarchy/EZVMOmarchy.xcodeproj/project.pbxproj"
[[ -f $project_file ]] || { echo "generated EZVM Omarchy project is missing" >&2; exit 65; }
project_hash_before=$(shasum -a 256 "$project_file" | awk '{print $1}')
(cd "$project_root/EZVMOmarchy" && xcodegen generate)
project_hash_after=$(shasum -a 256 "$project_file" | awk '{print $1}')
[[ $project_hash_before == "$project_hash_after" ]] || {
  echo "generated EZVM Omarchy project is stale" >&2
  exit 65
}

if [[ -n ${EZVM_SIGNING_IDENTITY:-} ]]; then
  archive_path="$derived_data/EZVMOmarchy.xcarchive"
  export_path="$derived_data/DeveloperIDExport"
  xcodebuild archive \
    -project "$project_root/EZVMOmarchy/EZVMOmarchy.xcodeproj" \
    -scheme 'EZVM Omarchy' \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    EZVM_SOURCE_REVISION="$source_revision" \
    EZVM_SOURCE_TREE_STATE="$source_tree_state" \
    EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64="$factory_public_key" \
    MARKETING_VERSION="$version"
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$project_root/scripts/developer-id-export-options.plist" \
    -allowProvisioningUpdates
  app_path="$export_path/EZVM Omarchy.app"
  signing_identity=$EZVM_SIGNING_IDENTITY
else
  xcodebuild \
    -project "$project_root/EZVMOmarchy/EZVMOmarchy.xcodeproj" \
    -scheme 'EZVM Omarchy' \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    EZVM_SOURCE_REVISION="$source_revision" \
    EZVM_SOURCE_TREE_STATE="$source_tree_state" \
    EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64="$factory_public_key" \
    MARKETING_VERSION="$version" \
    build
  app_path="$derived_data/Build/Products/Release/EZVM Omarchy.app"
  signing_identity=-
fi

[[ -d $app_path && ! -L $app_path ]] || { echo "application was not built: $app_path" >&2; exit 66; }
mkdir -p "$app_path/Contents/Resources/ThirdPartyLicenses"
ditto "$project_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto "$project_root/ThirdPartyLicenses" "$app_path/Contents/Resources/ThirdPartyLicenses"

signing_options=(--force --deep --sign "$signing_identity")
if [[ $signing_identity == - ]]; then
  signing_options+=(--entitlements "$project_root/EZVMOmarchy/Resources/EZVMOmarchy.entitlements" --timestamp=none)
else
  signing_options+=(--entitlements "$project_root/EZVMOmarchy/Resources/EZVMOmarchy.entitlements" --options runtime --timestamp)
fi
codesign "${signing_options[@]}" "$app_path"

"$project_root/scripts/verify-omarchy-release-app.sh" \
  "$app_path" "$version" "$source_revision" "$source_tree_state"

# A Developer ID timestamp can be accepted while trustd is still resolving its
# chain and fail shortly afterward if that resolution does not complete.  Do a
# delayed second verification before archiving so a transiently valid signature
# can never become the immutable release candidate.  Ad-hoc CI builds have no
# online timestamp chain and do not need this release-only settling interval.
if [[ $signing_identity != - ]]; then
  sleep "${EZVM_OMARCHY_SIGNATURE_SETTLE_SECONDS:-30}"
  "$project_root/scripts/verify-omarchy-release-app.sh" \
    "$app_path" "$version" "$source_revision" "$source_tree_state"
fi

archive="EZVM-Omarchy-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive"
roundtrip=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-release-roundtrip.XXXXXX")
trap 'rm -f "$decoded_key"; rm -rf "$roundtrip"' EXIT
ditto -x -k "$output_dir/$archive" "$roundtrip"
"$project_root/scripts/verify-omarchy-release-app.sh" \
  "$roundtrip/EZVM Omarchy.app" "$version" "$source_revision" "$source_tree_state"
(cd "$output_dir" && shasum -a 256 "$archive" >"$archive.sha256")
echo "Created $output_dir/$archive"
