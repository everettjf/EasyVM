#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
publisher="$project_root/scripts/publish-omarchy-release.sh"
state=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-publish-preflight.XXXXXX")
trap 'rm -rf "$state"' EXIT

expect_status() {
  local expected=$1
  shift
  local actual=0
  EZVM_OMARCHY_RELEASE_STATE_DIR="$state/releases" "$publisher" "$@" >/dev/null 2>&1 || actual=$?
  [[ $actual == "$expected" ]] || {
    echo "expected status $expected for '$*', got $actual" >&2
    exit 1
  }
  [[ ! -e "$state/releases" ]] || {
    echo "failed preflight mutated release state" >&2
    exit 1
  }
}

expect_status 64
expect_status 64 prepare
expect_status 64 unknown 1.0.0
expect_status 66 publish 1.0.0 missing-evidence missing-manifest missing-image

echo "Verified two-phase EZVM Omarchy publish preflight."
