#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-factory-tool-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

swift build --package-path "$project_root" --product omarchy-factory-tool >/dev/null
bin_dir="$(swift build --package-path "$project_root" --show-bin-path)"
tool="$bin_dir/omarchy-factory-tool"

printf 'EZVM-SPARSE-1\n8\n2 3\nabc\nEND\n' | gzip -c > "$work/image.sparse.gz"
"$tool" decode-sparse-gzip "$work/image.sparse.gz" 8 "$work/image.raw"
[[ $(stat -f '%z' "$work/image.raw") == 8 ]]
[[ $(dd if="$work/image.raw" bs=1 skip=2 count=3 2>/dev/null) == abc ]]
if "$tool" decode-sparse-gzip "$work/image.sparse.gz" 8 "$work/image.raw" 2>/dev/null; then
  echo 'sparse decoder unexpectedly overwrote an existing output' >&2
  exit 1
fi

printf 'test factory bytes' > "$work/factory.asif"
"$tool" generate-key "$work/private.key" "$work/public.key"
[[ $(stat -f '%Lp' "$work/private.key") == 600 ]]
"$tool" sign \
  "$work/factory.asif" \
  https://example.test/Omarchy-Factory.asif \
  test-version test-revision test-agent test-key \
  "$work/private.key" "$work/manifest.json"
"$tool" verify "$work/manifest.json" "$work/factory.asif" "$work/public.key"

printf 'test ' > "$work/factory.part-00"
printf 'factory bytes' > "$work/factory.part-01"
"$tool" sign-parts \
  "$work/factory.asif" \
  test-version test-revision test-agent test-key \
  "$work/private.key" "$work/multipart-manifest.json" \
  https://example.test/Omarchy-Factory.asif.part-00 "$work/factory.part-00" \
  https://example.test/Omarchy-Factory.asif.part-01 "$work/factory.part-01"
"$tool" verify "$work/multipart-manifest.json" "$work/factory.asif" "$work/public.key"
ruby -rjson -e '
  manifest = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong multipart schema" unless manifest.dig("payload", "schemaVersion") == 2
  abort "legacy URL leaked into multipart manifest" if manifest.dig("payload", "imageURL")
  abort "wrong part count" unless manifest.dig("payload", "imageParts").length == 2
' "$work/multipart-manifest.json"

printf X >> "$work/factory.part-01"
if "$tool" sign-parts \
  "$work/factory.asif" \
  test-version test-revision test-agent test-key \
  "$work/private.key" "$work/rejected-manifest.json" \
  https://example.test/Omarchy-Factory.asif.part-00 "$work/factory.part-00" \
  https://example.test/Omarchy-Factory.asif.part-01 "$work/factory.part-01" 2>/dev/null; then
  echo 'mismatched Factory parts unexpectedly produced a manifest' >&2
  exit 1
fi
[[ ! -e "$work/rejected-manifest.json" ]]

mkdir "$work/release-assets"
cp "$work/factory.asif" "$work/release-assets/Omarchy-Factory.asif"
EZVM_OMARCHY_FACTORY_RELEASE_BASE_URL=https://github.com/example/test/releases/download/test \
EZVM_OMARCHY_FACTORY_PART_BYTES=8 \
  "$project_root/scripts/sign-omarchy-factory-parts.sh" \
    "$work/release-assets/Omarchy-Factory.asif" \
    test-version test-revision test-agent "$work/private.key"
[[ -f "$work/release-assets/Omarchy-Factory.asif.part-00" ]]
[[ -f "$work/release-assets/Omarchy-Factory.asif.part-01" ]]
(cd "$work/release-assets" && shasum -a 256 -c EZVM_FACTORY_SHA256SUMS)
"$tool" verify \
  "$work/release-assets/ezvm-omarchy-factory-manifest.json" \
  "$work/release-assets/Omarchy-Factory.asif" "$work/public.key"
ruby -rjson -e '
  parts = JSON.parse(File.read(ARGV.fetch(0))).dig("payload", "imageParts")
  abort "wrong release URL" unless parts.first.fetch("url") ==
    "https://github.com/example/test/releases/download/test/Omarchy-Factory.asif.part-00"
' "$work/release-assets/ezvm-omarchy-factory-manifest.json"
EZVM_OMARCHY_IMAGE_REPOSITORY=example/test \
  "$project_root/scripts/publish-omarchy-factory-assets.sh" verify \
    test "$work/release-assets" "$work/public.key"
cp -R "$work/release-assets" "$work/unsafe-checksum-assets"
printf '%064d  ../../outside\n' 0 >> "$work/unsafe-checksum-assets/EZVM_FACTORY_SHA256SUMS"
if EZVM_OMARCHY_IMAGE_REPOSITORY=example/test \
    "$project_root/scripts/publish-omarchy-factory-assets.sh" verify \
      test "$work/unsafe-checksum-assets" "$work/public.key" 2>/dev/null; then
  echo 'unsafe Factory checksum entry unexpectedly passed publication preflight' >&2
  exit 1
fi

mkdir "$work/rejected-assets"
cp "$work/factory.asif" "$work/rejected-assets/Omarchy-Factory.asif"
if EZVM_OMARCHY_FACTORY_RELEASE_BASE_URL=http://example.test/releases/test \
   EZVM_OMARCHY_FACTORY_PART_BYTES=8 \
    "$project_root/scripts/sign-omarchy-factory-parts.sh" \
      "$work/rejected-assets/Omarchy-Factory.asif" \
      test-version test-revision test-agent "$work/private.key" 2>/dev/null; then
  echo 'insecure Factory release URL unexpectedly produced assets' >&2
  exit 1
fi
[[ ! -e "$work/rejected-assets/ezvm-omarchy-factory-manifest.json" ]]
[[ ! -e "$work/rejected-assets/EZVM_FACTORY_SHA256SUMS" ]]
[[ -z $(find "$work/rejected-assets" -name 'Omarchy-Factory.asif.part-*' -print -quit) ]]

"$tool" prepare-workspace \
  "$work/manifest.json" "$work/factory.asif" "$work/public.key" "$work/application-support"
[[ -f "$work/application-support/Workspace/Disk.asif" ]]
[[ -f "$work/application-support/Workspace/Configuration.json" ]]
[[ -f "$work/application-support/Workspace/MachineIdentifier" ]]
[[ -f "$work/application-support/Enrollment/config.json" ]]
if "$tool" prepare-workspace \
  "$work/manifest.json" "$work/factory.asif" "$work/public.key" "$work/application-support" 2>/dev/null; then
  echo 'existing acceptance workspace was unexpectedly overwritten' >&2
  exit 1
fi

printf 'tamper' >> "$work/factory.asif"
if "$tool" verify "$work/manifest.json" "$work/factory.asif" "$work/public.key" 2>/dev/null; then
  echo 'tampered factory unexpectedly verified' >&2
  exit 1
fi

echo 'Verified Omarchy factory key generation, single/multipart signing, and tamper rejection.'
