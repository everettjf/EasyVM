#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/readonly-fixture-guard.sh
source "$project_root/scripts/lib/readonly-fixture-guard.sh"

fixture="$(mktemp -d /tmp/ezvm-readonly-fixture-test.XXXXXX)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

mkdir "$fixture/nested"
printf 'configuration\n' >"$fixture/config.json"
ln -s config.json "$fixture/config-link"

fingerprint="$(fixture_metadata_fingerprint "$fixture")"
assert_fixture_unchanged "$fixture" "$fingerprint"

chmod 600 "$fixture/config.json"
if assert_fixture_unchanged "$fixture" "$fingerprint" >/dev/null 2>&1; then
  echo "fixture guard ignored a permission change" >&2
  exit 1
fi

fingerprint="$(fixture_metadata_fingerprint "$fixture")"
printf 'changed\n' >>"$fixture/config.json"
if assert_fixture_unchanged "$fixture" "$fingerprint" >/dev/null 2>&1; then
  echo "fixture guard ignored a content write" >&2
  exit 1
fi

fingerprint="$(fixture_metadata_fingerprint "$fixture")"
touch "$fixture/new-file"
if assert_fixture_unchanged "$fixture" "$fingerprint" >/dev/null 2>&1; then
  echo "fixture guard ignored a new file" >&2
  exit 1
fi

echo "Verified read-only fixture mutation detection."
