#!/bin/bash

set -euo pipefail

app_path="${1:-}"
expected_version="${2:-}"
expected_revision="${3:-}"
expected_tree_state="${4:-clean}"

fail() {
  echo "verify-release-metadata: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "usage: $0 <EZVM.app> [version] [revision] [tree-state]"
info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" && ! -L "$info_plist" ]] || fail "application Info.plist is missing or untrusted"

actual_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")" \
  || fail "application version is missing"
actual_revision="$(plutil -extract EZVMSourceRevision raw "$info_plist")" \
  || fail "source revision is missing"
actual_tree_state="$(plutil -extract EZVMSourceTreeState raw "$info_plist")" \
  || fail "source tree state is missing"

[[ "$actual_revision" =~ ^[0-9a-f]{40}$ ]] || fail "source revision is not a full Git commit"
[[ "$actual_tree_state" == "clean" || "$actual_tree_state" == "dirty" ]] \
  || fail "source tree state is invalid"
[[ -z "$expected_version" || "$actual_version" == "$expected_version" ]] \
  || fail "version is $actual_version, expected $expected_version"
[[ -z "$expected_revision" || "$actual_revision" == "$expected_revision" ]] \
  || fail "source revision does not match the expected commit"
[[ "$actual_tree_state" == "$expected_tree_state" ]] \
  || fail "source tree state is $actual_tree_state, expected $expected_tree_state"

echo "Verified EZVM $actual_version source revision $actual_revision ($actual_tree_state)."
