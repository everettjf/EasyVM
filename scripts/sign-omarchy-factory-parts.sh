#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
factory=${1:-}
image_version=${2:-}
omarchy_revision=${3:-}
agent_version=${4:-}
private_key=${5:-}
release_base_url=${EZVM_OMARCHY_FACTORY_RELEASE_BASE_URL:-}
key_id=${EZVM_OMARCHY_FACTORY_KEY_ID:-ezvm-omarchy-factory-2026}
part_bytes=${EZVM_OMARCHY_FACTORY_PART_BYTES:-1992294400}

fail() { printf 'sign-omarchy-factory-parts: %s\n' "$*" >&2; exit 1; }

[[ -f $factory && ! -L $factory ]] || fail "Factory ASIF is missing or unsafe"
[[ -n $image_version && -n $omarchy_revision && -n $agent_version ]] || \
  fail "usage: $0 <factory.asif> <image-version> <omarchy-revision> <agent-version> <private-key>"
[[ -f $private_key && ! -L $private_key ]] || fail "private signing key is missing or unsafe"
[[ $release_base_url == https://* && $release_base_url != */ ]] || \
  fail "EZVM_OMARCHY_FACTORY_RELEASE_BASE_URL must be an HTTPS URL without a trailing slash"
[[ $key_id =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid signing key id"
[[ $part_bytes =~ ^[0-9]+$ && $part_bytes -gt 0 && $part_bytes -le 1992294400 ]] || \
  fail "EZVM_OMARCHY_FACTORY_PART_BYTES must be between 1 and 1992294400"

output_dir=$(cd "$(dirname "$factory")" && pwd)
factory="$output_dir/$(basename "$factory")"
manifest="$output_dir/ezvm-omarchy-factory-manifest.json"
checksum="$output_dir/EZVM_FACTORY_SHA256SUMS"
[[ ! -e $manifest && ! -e $checksum ]] || fail "signed Factory metadata already exists"
if find "$output_dir" -mindepth 1 -maxdepth 1 -name 'Omarchy-Factory.asif.part-*' -print -quit | grep -q .; then
  fail "Factory release parts already exist"
fi

completed=0
cleanup() {
  if ((completed == 0)); then
    rm -f "$manifest" "$checksum" "$output_dir"/Omarchy-Factory.asif.part-*
  fi
}
trap cleanup EXIT

split -d -a 2 -b "$part_bytes" "$factory" "$output_dir/Omarchy-Factory.asif.part-"
parts=("$output_dir"/Omarchy-Factory.asif.part-*)
[[ ${#parts[@]} -ge 2 && ${#parts[@]} -le 32 ]] || \
  fail "Factory image must produce between 2 and 32 release parts"

sign_arguments=(
  sign-parts "$factory" "$image_version" "$omarchy_revision" "$agent_version"
  "$key_id" "$private_key" "$manifest"
)
for part in "${parts[@]}"; do
  sign_arguments+=("$release_base_url/$(basename "$part")" "$part")
done
swift run --package-path "$project_root" -c release omarchy-factory-tool "${sign_arguments[@]}"

(cd "$output_dir" && shasum -a 256 \
  Omarchy-Factory.asif.part-* ezvm-omarchy-factory-manifest.json > EZVM_FACTORY_SHA256SUMS)
completed=1
printf 'Created signed multipart Omarchy Factory assets in %s\n' "$output_dir"
