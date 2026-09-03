#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-release-metadata.sh"
test_root="$(mktemp -d /tmp/ezvm-release-metadata-test.XXXXXX)"
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

app="$test_root/EZVM.app"
info="$app/Contents/Info.plist"
revision="0123456789abcdef0123456789abcdef01234567"
mkdir -p "$app/Contents"
plutil -create xml1 "$info"
plutil -insert CFBundleShortVersionString -string 2.0.0 "$info"
plutil -insert EZVMSourceRevision -string "$revision" "$info"
plutil -insert EZVMSourceTreeState -string clean "$info"

"$verifier" "$app" 2.0.0 "$revision" clean >/dev/null

if "$verifier" "$app" 2.0.0 ffffffffffffffffffffffffffffffffffffffff clean >/dev/null 2>&1; then
  echo "release metadata verifier accepted the wrong commit" >&2
  exit 1
fi

plutil -replace EZVMSourceTreeState -string dirty "$info"
if "$verifier" "$app" 2.0.0 "$revision" clean >/dev/null 2>&1; then
  echo "release metadata verifier accepted a dirty candidate as clean" >&2
  exit 1
fi

plutil -replace EZVMSourceRevision -string short "$info"
if "$verifier" "$app" 2.0.0 short dirty >/dev/null 2>&1; then
  echo "release metadata verifier accepted a shortened commit" >&2
  exit 1
fi

echo "Verified release source metadata checks."
