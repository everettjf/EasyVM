#!/bin/bash

set -euo pipefail

duration="${1:-30}"
output="${2:-/tmp/ezvm-virgl-performance-$(date +%Y%m%d-%H%M%S).txt}"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 5 || duration > 600 )); then
    echo "Duration must be an integer between 5 and 600 seconds." >&2
    exit 2
fi

pid="$(pgrep -x EZVM | tail -n 1 || true)"
if [[ -z "$pid" ]]; then
    echo "No running EZVM process was found." >&2
    exit 1
fi

samples="$(mktemp /tmp/ezvm-virgl-samples.XXXXXX)"
graphics_logs="$(mktemp /tmp/ezvm-virgl-logs.XXXXXX)"
log_pid=""
cleanup() {
    if [[ -n "$log_pid" ]] && kill -0 "$log_pid" 2>/dev/null; then
        kill "$log_pid" 2>/dev/null || true
        wait "$log_pid" 2>/dev/null || true
    fi
    rm -f "$samples" "$graphics_logs"
}
trap cleanup EXIT
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/bin/log stream --style compact --level info \
    --predicate "processID == $pid AND subsystem == 'com.everettjf.ezvm' AND (category == 'graphics' OR category == 'virtio-gpu')" \
    > "$graphics_logs" &
log_pid=$!

for (( second = 0; second < duration; second++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "EZVM stopped before the capture completed." >&2
        exit 1
    fi
    ps -p "$pid" -o %cpu=,rss= >> "$samples"
    sleep 1
done

kill "$log_pid" 2>/dev/null || true
wait "$log_pid" 2>/dev/null || true
log_pid=""

{
    echo "# EZVM VirGL performance capture"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Started: $started_at"
    echo "Duration: ${duration}s"
    echo "PID: $pid"
    echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "Hardware: $(sysctl -n hw.model)"
    echo
    echo "# Host process summary"
    awk '
        { cpu += $1; if ($1 > max_cpu) max_cpu = $1; rss += $2; if ($2 > max_rss) max_rss = $2; count++ }
        END {
            if (count == 0) exit 1
            printf "Average CPU: %.1f%%\nPeak CPU: %.1f%%\nAverage RSS: %.1f MiB\nPeak RSS: %.1f MiB\n", cpu / count, max_cpu, rss / count / 1024, max_rss / 1024
        }
    ' "$samples"
    echo
    echo "# Per-second samples (%CPU RSS-KiB)"
    cat "$samples"
    echo
    echo "# EZVM graphics and virtio-gpu logs"
    cat "$graphics_logs"
} > "$output"

echo "$output"
