#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output=""
status=0

output="$(
  EASYVM_SIGNING_IDENTITY='Legacy value that must never be ignored' \
    "$project_root/scripts/build-release.sh" 2.0.0 /tmp/ezvm-legacy-signing-test 2>&1
)" || status=$?

if [[ "$status" -ne 64 ]]; then
  echo "expected obsolete signing variable to fail with status 64, got $status" >&2
  exit 1
fi
if [[ "$output" != *"Set EZVM_SIGNING_IDENTITY instead"* ]]; then
  echo "obsolete signing variable did not produce actionable guidance" >&2
  exit 1
fi
if [[ -e /tmp/ezvm-legacy-signing-test ]]; then
  echo "signing preflight mutated the requested output directory" >&2
  exit 1
fi

echo "Verified release signing environment preflight."
