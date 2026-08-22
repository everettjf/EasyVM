#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
output_dir="${2:-$project_root/dist}"
derived_data="${EASYVM_DERIVED_DATA:-}"
archive_name="EasyVM-${version}.zip"

if [[ -z "$version" ]]; then
  echo "usage: $0 <version> [output-directory]" >&2
  exit 64
fi

if [[ "$version" == v* ]]; then
  version="${version#v}"
  archive_name="EasyVM-${version}.zip"
fi

mkdir -p "$output_dir"

if [[ -z "$derived_data" ]]; then
  derived_data="$(mktemp -d "${RUNNER_TEMP:-/tmp}/easyvm-release-derived-data.XXXXXX")"
fi

# Never reuse a release build directory. A notarization ticket stapled to a
# previous build lives at Contents/CodeResources; Xcode does not remove it on
# an incremental rebuild, and signing an app containing that stale ticket
# produces an archive that Gatekeeper rejects.
if [[ -e "$derived_data/Build/Products/Release/EasyVM.app" ]]; then
  echo "release derived data must be empty: $derived_data" >&2
  exit 65
fi

mkdir -p "$derived_data"

xcodebuild \
  -project "$project_root/EasyVM/EasyVM.xcodeproj" \
  -scheme EasyVM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" \
  build

app_path="$derived_data/Build/Products/Release/EasyVM.app"
signing_identity="${EASYVM_SIGNING_IDENTITY:--}"
entitlements_path="$project_root/EasyVM/EasyVM/EasyVM.entitlements"

signing_options=(--force --deep --options runtime --entitlements "$entitlements_path" --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  signing_options+=(--timestamp=none)
else
  signing_options+=(--timestamp)
fi

codesign "${signing_options[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --entitlements :- "$app_path"

# Fail before archiving if a restricted or accidental entitlement enters the
# production target. Runtime launch and Gatekeeper checks run after notarization.
"$project_root/scripts/verify-production-entitlements.sh" "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"

# Verify the exact archive users will install, not only the pre-archive app.
roundtrip_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/easyvm-release-roundtrip.XXXXXX")"
trap 'rm -rf "$roundtrip_dir"' EXIT
ditto -x -k "$output_dir/$archive_name" "$roundtrip_dir"
codesign --verify --deep --strict --verbose=2 "$roundtrip_dir/EasyVM.app"
(
  cd "$output_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

echo "Created $output_dir/$archive_name"
