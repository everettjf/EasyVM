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

echo 'Verified Omarchy factory key generation, manifest signing, and tamper rejection.'
