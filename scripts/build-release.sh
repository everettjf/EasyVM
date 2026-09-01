#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
output_dir="${2:-$project_root/dist}"
derived_data="${EZVM_DERIVED_DATA:-}"
archive_name="EZVM-${version}.zip"

if [[ -z "$version" ]]; then
  echo "usage: $0 <version> [output-directory]" >&2
  exit 64
fi

if [[ "$version" == v* ]]; then
  version="${version#v}"
  archive_name="EZVM-${version}.zip"
fi

mkdir -p "$output_dir"

if [[ -z "$derived_data" ]]; then
  derived_data="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-release-derived-data.XXXXXX")"
fi

# Never reuse a release build directory. A notarization ticket stapled to a
# previous build lives at Contents/CodeResources; Xcode does not remove it on
# an incremental rebuild, and signing an app containing that stale ticket
# produces an archive that Gatekeeper rejects.
if [[ -e "$derived_data/Build/Products/Release/EZVM.app" ]]; then
  echo "release derived data must be empty: $derived_data" >&2
  exit 65
fi

mkdir -p "$derived_data"

if [[ -n "${EZVM_VIRGL_RUNTIME_SOURCE:-}" ]]; then
  virgl_runtime_source="$EZVM_VIRGL_RUNTIME_SOURCE"
  case "$virgl_runtime_source" in
    /*) ;;
    *) echo "EZVM_VIRGL_RUNTIME_SOURCE must be an absolute path" >&2; exit 67 ;;
  esac
  [[ -d "$virgl_runtime_source" && ! -L "$virgl_runtime_source" ]] || {
    echo "invalid source-qualified VirGL runtime: $virgl_runtime_source" >&2
    exit 67
  }
else
  virgl_runtime_source="$project_root/.build/virgl-runtime-source"
fi

xcodebuild \
  -project "$project_root/EZVM/EZVM.xcodeproj" \
  -scheme EZVM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" \
  build

app_path="$derived_data/Build/Products/Release/EZVM.app"
if [[ -z "${EZVM_VIRGL_RUNTIME_SOURCE:-}" ]]; then
  (cd "$project_root" && \
    "$project_root/scripts/build-virgl-runtime-from-source.sh" "$virgl_runtime_source")
fi
virgl_runtime_destination="$app_path/Contents/Frameworks/VirGLRuntime"
mkdir -p "$virgl_runtime_destination"
ditto "$virgl_runtime_source" "$virgl_runtime_destination"
"$project_root/scripts/verify-virgl-runtime.sh" "$virgl_runtime_destination"
mkdir -p "$app_path/Contents/Resources/ThirdPartyLicenses"
ditto "$project_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto "$project_root/ThirdPartyLicenses" "$app_path/Contents/Resources/ThirdPartyLicenses"
(cd "$project_root" && swift build -c release --product ezvm --disable-sandbox)
cli_bin_dir="$(cd "$project_root" && swift build -c release --disable-sandbox --show-bin-path)"
cli_path="$cli_bin_dir/ezvm"
[[ -x "$cli_path" ]] || { echo "CLI executable not found: $cli_path" >&2; exit 66; }
mkdir -p "$app_path/Contents/Helpers"
cp "$cli_path" "$app_path/Contents/Helpers/ezvm"
chmod 755 "$app_path/Contents/Helpers/ezvm"

if [[ -n "${EZVM_SIGNING_IDENTITY:-}" ]]; then
  signing_identity="$EZVM_SIGNING_IDENTITY"
elif [[ -n "${EASYVM_SIGNING_IDENTITY:-}" ]]; then
  signing_identity="$EASYVM_SIGNING_IDENTITY"
  echo "warning: EASYVM_SIGNING_IDENTITY is deprecated; use EZVM_SIGNING_IDENTITY" >&2
else
  signing_identity="-"
fi
entitlements_path="$project_root/EZVM/EZVM/EZVM.entitlements"

signing_options=(--force --deep --entitlements "$entitlements_path" --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  signing_options+=(--timestamp=none)
else
  signing_options+=(--options runtime --timestamp)
fi

virgl_signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  virgl_signing_options+=(--timestamp=none)
else
  virgl_signing_options+=(--options runtime --timestamp)
fi
for library in "$virgl_runtime_destination"/*.dylib; do
  codesign "${virgl_signing_options[@]}" "$library"
done
"$project_root/scripts/verify-virgl-runtime.sh" "$virgl_runtime_destination"
codesign "${signing_options[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --entitlements :- "$app_path"

if [[ "$signing_identity" != "-" ]]; then
  app_team_id="$(codesign --display --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$app_team_id" ]] || {
    echo "Developer ID build has no TeamIdentifier: $app_path" >&2
    exit 68
  }
  for signed_code in "$app_path/Contents/Helpers/ezvm" "$virgl_runtime_destination"/*.dylib; do
    nested_team_id="$(codesign --display --verbose=4 "$signed_code" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$nested_team_id" == "$app_team_id" ]] || {
      echo "TeamIdentifier mismatch: app=$app_team_id nested=${nested_team_id:-missing} path=$signed_code" >&2
      exit 68
    }
  done
  echo "Verified Developer ID TeamIdentifier $app_team_id across app, CLI, and VirGL runtime."
fi

# Fail before archiving if a restricted or accidental entitlement enters the
# production target. Runtime launch and Gatekeeper checks run after notarization.
"$project_root/scripts/verify-production-entitlements.sh" "$app_path"
"$project_root/scripts/verify-virgl-runtime.sh" "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"

# Verify the exact archive users will install, not only the pre-archive app.
roundtrip_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-release-roundtrip.XXXXXX")"
trap 'rm -rf "$roundtrip_dir"' EXIT
ditto -x -k "$output_dir/$archive_name" "$roundtrip_dir"
codesign --verify --deep --strict --verbose=2 "$roundtrip_dir/EZVM.app"
(
  cd "$output_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

echo "Created $output_dir/$archive_name"
