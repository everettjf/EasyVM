#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/virgl-capture-preflight.sh
source "$script_dir/lib/virgl-capture-preflight.sh"

duration="${1:-30}"
output="${2:-/tmp/ezvm-virgl-performance-$(date +%Y%m%d-%H%M%S).txt}"
backend="${EZVM_VIRGL_BACKEND:-custom-virgl}"
workload="${EZVM_VIRGL_WORKLOAD:-unspecified}"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 5 || duration > 600 )); then
    echo "Duration must be an integer between 5 and 600 seconds." >&2
    exit 2
fi

case "$backend" in
    custom-virgl|apple-virtio) ;;
    *)
        echo "EZVM_VIRGL_BACKEND must be custom-virgl or apple-virtio." >&2
        exit 2
        ;;
esac

if [[ "$workload" == *$'\n'* || "$workload" == *$'\r'* ]]; then
    echo "EZVM_VIRGL_WORKLOAD must be a single line." >&2
    exit 2
fi

discovered_pids="$(pgrep -x EZVM || true)"
pid="$(select_virgl_capture_pid "${EZVM_VIRGL_PID:-}" "$discovered_pids")" || exit $?
if ! kill -0 "$pid" 2>/dev/null; then
    echo "EZVM process $pid is no longer running." >&2
    exit 1
fi
process_name="$(ps -p "$pid" -o comm= | awk -F/ '{ print $NF }')"
if [[ "$process_name" != "EZVM" ]]; then
    echo "Process $pid is $process_name, not EZVM." >&2
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

percentile() {
    local column="$1"
    local percentile="$2"
    awk -v column="$column" '{ print $column }' "$samples" | \
        LC_ALL=C sort -n | \
        awk -v percentile="$percentile" '
            { values[NR] = $1 }
            END {
                if (NR == 0) exit 1
                index = int((NR - 1) * percentile) + 1
                printf "%.1f", values[index]
            }
        '
}

virgl_summary() {
    awk '
        /VirGL performance: fps=/ {
            for (index = 1; index <= NF; index++) {
                field = $index
                gsub(/,$/, "", field)
                split(field, pair, "=")
                if (pair[1] == "fps") { fps += pair[2]; if (windows == 0 || pair[2] < min_fps) min_fps = pair[2] }
                if (pair[1] == "requested") requested += pair[2]
                if (pair[1] == "presented") presented += pair[2]
                if (pair[1] == "drawableMisses") misses += pair[2]
                if (pair[1] == "failures") failures += pair[2]
                if (pair[1] == "avgPresentMs") average_present += pair[2]
                if (pair[1] == "maxPresentMs" && pair[2] > maximum_present) maximum_present = pair[2]
            }
            windows++
        }
        END {
            printf "VirGL-Window-Count: %d\n", windows
            if (windows == 0) {
                print "VirGL-Average-FPS: unavailable"
                print "VirGL-Minimum-FPS: unavailable"
                print "VirGL-Requested-Frames: 0"
                print "VirGL-Presented-Frames: 0"
                print "VirGL-Drawable-Misses: 0"
                print "VirGL-Presentation-Failures: 0"
                print "VirGL-Average-Present-Ms: unavailable"
                print "VirGL-Maximum-Present-Ms: unavailable"
            } else {
                printf "VirGL-Average-FPS: %.1f\n", fps / windows
                printf "VirGL-Minimum-FPS: %.1f\n", min_fps
                printf "VirGL-Requested-Frames: %.0f\n", requested
                printf "VirGL-Presented-Frames: %.0f\n", presented
                printf "VirGL-Drawable-Misses: %.0f\n", misses
                printf "VirGL-Presentation-Failures: %.0f\n", failures
                printf "VirGL-Average-Present-Ms: %.2f\n", average_present / windows
                printf "VirGL-Maximum-Present-Ms: %.2f\n", maximum_present
            }
        }
    ' "$graphics_logs"
}

{
    echo "# EZVM VirGL performance capture"
    echo "Format-Version: 2"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Started: $started_at"
    echo "Duration: ${duration}s"
    echo "Backend: $backend"
    echo "Workload: $workload"
    echo "PID: $pid"
    echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "Hardware: $(sysctl -n hw.model)"
    echo
    echo "# Machine-readable summary"
    awk '
        { cpu += $1; if ($1 > max_cpu) max_cpu = $1; rss += $2; if ($2 > max_rss) max_rss = $2; count++ }
        END {
            if (count == 0) exit 1
            printf "Sample-Count: %d\nHost-Average-CPU-Percent: %.1f\nHost-Peak-CPU-Percent: %.1f\nHost-Average-RSS-MiB: %.1f\nHost-Peak-RSS-MiB: %.1f\n", count, cpu / count, max_cpu, rss / count / 1024, max_rss / 1024
        }
    ' "$samples"
    echo "Host-P50-CPU-Percent: $(percentile 1 0.50)"
    echo "Host-P95-CPU-Percent: $(percentile 1 0.95)"
    echo "Host-P50-RSS-MiB: $(awk '{ print $2 / 1024 }' "$samples" | LC_ALL=C sort -n | awk '{ values[NR] = $1 } END { index = int((NR - 1) * 0.50) + 1; printf "%.1f", values[index] }')"
    echo "Host-P95-RSS-MiB: $(awk '{ print $2 / 1024 }' "$samples" | LC_ALL=C sort -n | awk '{ values[NR] = $1 } END { index = int((NR - 1) * 0.95) + 1; printf "%.1f", values[index] }')"
    virgl_summary
    echo
    echo "# Per-second samples (%CPU RSS-KiB)"
    cat "$samples"
    echo
    echo "# EZVM graphics and virtio-gpu logs"
    cat "$graphics_logs"
} > "$output"

echo "$output"
