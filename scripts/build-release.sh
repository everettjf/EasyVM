#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
output_dir="${2:-$project_root/dist}"
derived_data="${RUNNER_TEMP:-/tmp}/easyvm-release-derived-data"
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

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"
shasum -a 256 "$output_dir/$archive_name" > "$output_dir/$archive_name.sha256"

echo "Created $output_dir/$archive_name"
