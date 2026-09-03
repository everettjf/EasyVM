#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-factory-tool-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

swift build --package-path "$project_root" --product omarchy-factory-tool >/dev/null
bin_dir="$(swift build --package-path "$project_root" --show-bin-path)"
tool="$bin_dir/omarchy-factory-tool"

printf 'test factory bytes' > "$work/factory.asif"
"$tool" generate-key "$work/private.key" "$work/public.key"
[[ $(stat -f '%Lp' "$work/private.key") == 600 ]]
"$tool" sign \
  "$work/factory.asif" \
  https://example.test/Omarchy-Factory.asif \
  test-version test-revision test-agent test-key \
  "$work/private.key" "$work/manifest.json"
"$tool" verify "$work/manifest.json" "$work/factory.asif" "$work/public.key"

printf 'tamper' >> "$work/factory.asif"
if "$tool" verify "$work/manifest.json" "$work/factory.asif" "$work/public.key" 2>/dev/null; then
  echo 'tampered factory unexpectedly verified' >&2
  exit 1
fi

echo 'Verified Omarchy factory key generation, manifest signing, and tamper rejection.'
