#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/readonly-fixture-guard.sh
source "$project_root/scripts/lib/readonly-fixture-guard.sh"

test_root="$(mktemp -d /tmp/ezvm-readonly-fixture-test.XXXXXX)"
fixture="$test_root/Original.ezvm"
clone="$test_root/Clone.ezvm"
mkdir "$fixture"
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

mkdir "$fixture/nested"
printf 'configuration\n' >"$fixture/config.json"
ln -s config.json "$fixture/config-link"

fingerprint="$(fixture_metadata_fingerprint "$fixture")"
assert_fixture_unchanged "$fixture" "$fingerprint"

clone_readonly_fixture "$fixture" "$clone"
printf 'clone only\n' >>"$clone/config.json"
assert_fixture_unchanged "$fixture" "$fingerprint"
[[ "$(cat "$fixture/config.json")" == "configuration" ]] || {
  echo "writing the clone changed the read-only fixture" >&2
  exit 1
}
if clone_readonly_fixture "$fixture" "$clone" >/dev/null 2>&1; then
  echo "fixture clone guard accepted an existing destination" >&2
  exit 1
fi
if clone_readonly_fixture "$fixture" "$fixture/nested/Clone.ezvm" >/dev/null 2>&1; then
  echo "fixture clone guard accepted a destination inside the source" >&2
  exit 1
fi

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
