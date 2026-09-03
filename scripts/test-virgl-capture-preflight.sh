#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/virgl-capture-preflight.sh
source "$script_dir/lib/virgl-capture-preflight.sh"

fail() {
    echo "test-virgl-capture-preflight: $*" >&2
    exit 1
}

[[ "$(select_virgl_capture_pid "" $'101\n')" == "101" ]] || fail "one process was not selected"
[[ "$(select_virgl_capture_pid 202 $'101\n303\n')" == "202" ]] || fail "explicit PID did not override discovery"

if select_virgl_capture_pid "" "" >/dev/null 2>&1; then
    fail "empty process list was accepted"
fi
if select_virgl_capture_pid "" $'101\n303\n' >/dev/null 2>&1; then
    fail "multiple processes were accepted without an explicit PID"
fi
if select_virgl_capture_pid invalid $'101\n' >/dev/null 2>&1; then
    fail "invalid explicit PID was accepted"
fi

echo "Verified VirGL capture process selection."
