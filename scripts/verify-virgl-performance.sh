#!/bin/bash

set -euo pipefail

candidate="${1:-}"
baseline="${2:-}"

fail() {
    echo "verify-virgl-performance: $*" >&2
    exit 1
}

metric() {
    local report="$1"
    local name="$2"
    awk -F ': ' -v name="$name" '$1 == name { print substr($0, length($1) + 3); exit }' "$report"
}

number_le() {
    awk -v actual="$1" -v limit="$2" 'BEGIN { exit !(actual + 0 <= limit + 0) }'
}

number_ge() {
    awk -v actual="$1" -v limit="$2" 'BEGIN { exit !(actual + 0 >= limit + 0) }'
}

require_number() {
    local value="$1"
    local description="$2"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "$description is not a nonnegative number: $value"
}

[[ -n "$candidate" ]] || fail "usage: $0 <custom-virgl-report> [apple-virtio-baseline-report]"
[[ -f "$candidate" && ! -L "$candidate" ]] || fail "missing or unsafe candidate report: $candidate"
[[ "$(metric "$candidate" Format-Version)" == "2" ]] || fail "candidate is not a version 2 capture"
[[ "$(metric "$candidate" Backend)" == "custom-virgl" ]] || fail "candidate backend must be custom-virgl"

minimum_windows="${EZVM_VIRGL_MIN_WINDOWS:-4}"
maximum_misses="${EZVM_VIRGL_MAX_DRAWABLE_MISSES:-2}"
maximum_average_present="${EZVM_VIRGL_MAX_AVERAGE_PRESENT_MS:-2.0}"
maximum_p95_present="${EZVM_VIRGL_MAX_P95_PRESENT_MS:-8.0}"
maximum_present="${EZVM_VIRGL_MAX_PRESENT_MS:-50.0}"
maximum_cpu_delta="${EZVM_VIRGL_MAX_CPU_DELTA_PERCENT:-25.0}"
maximum_rss_delta="${EZVM_VIRGL_MAX_RSS_DELTA_MIB:-512.0}"

[[ "$minimum_windows" =~ ^[0-9]+$ ]] || fail "minimum window budget must be an integer"
for budget in "$maximum_misses" "$maximum_average_present" "$maximum_p95_present" "$maximum_present" "$maximum_cpu_delta" "$maximum_rss_delta"; do
    require_number "$budget" "performance budget"
done

windows="$(metric "$candidate" VirGL-Window-Count)"
failures="$(metric "$candidate" VirGL-Presentation-Failures)"
misses="$(metric "$candidate" VirGL-Drawable-Misses)"
average_present="$(metric "$candidate" VirGL-Average-Present-Ms)"
p95_present="$(metric "$candidate" VirGL-Maximum-Window-P95-Present-Ms)"
peak_present="$(metric "$candidate" VirGL-Maximum-Present-Ms)"

[[ "$windows" =~ ^[0-9]+$ ]] || fail "candidate has no valid VirGL window count"
require_number "$failures" "presentation failure count"
require_number "$misses" "drawable miss count"
number_ge "$windows" "$minimum_windows" || fail "only $windows VirGL windows were captured; require at least $minimum_windows"
[[ "$failures" == "0" ]] || fail "$failures presentation failures were recorded"
number_le "$misses" "$maximum_misses" || fail "$misses drawable misses exceed the budget of $maximum_misses"
[[ "$average_present" != "unavailable" ]] || fail "average presentation latency is unavailable"
require_number "$average_present" "average presentation latency"
require_number "$p95_present" "maximum window P95 presentation latency"
require_number "$peak_present" "peak presentation latency"
number_le "$average_present" "$maximum_average_present" || fail "average presentation latency ${average_present}ms exceeds ${maximum_average_present}ms"
number_le "$p95_present" "$maximum_p95_present" || fail "maximum window P95 presentation latency ${p95_present}ms exceeds ${maximum_p95_present}ms"
number_le "$peak_present" "$maximum_present" || fail "peak presentation latency ${peak_present}ms exceeds ${maximum_present}ms"

if [[ -n "$baseline" ]]; then
    [[ -f "$baseline" && ! -L "$baseline" ]] || fail "missing or unsafe baseline report: $baseline"
    [[ "$(metric "$baseline" Format-Version)" == "2" ]] || fail "baseline is not a version 2 capture"
    [[ "$(metric "$baseline" Backend)" == "apple-virtio" ]] || fail "baseline backend must be apple-virtio"
    [[ "$(metric "$baseline" VirGL-Window-Count)" == "0" ]] || fail "baseline contains VirGL frame windows and is mislabeled"
    [[ "$(metric "$candidate" Workload)" != "unspecified" ]] || fail "A/B reports require an explicit workload label"
    for field in Duration Workload Hardware macOS; do
        [[ "$(metric "$candidate" "$field")" == "$(metric "$baseline" "$field")" ]] || \
            fail "$field differs between candidate and baseline"
    done

    candidate_cpu="$(metric "$candidate" Host-Average-CPU-Percent)"
    baseline_cpu="$(metric "$baseline" Host-Average-CPU-Percent)"
    candidate_rss="$(metric "$candidate" Host-Average-RSS-MiB)"
    baseline_rss="$(metric "$baseline" Host-Average-RSS-MiB)"
    require_number "$candidate_cpu" "candidate average CPU"
    require_number "$baseline_cpu" "baseline average CPU"
    require_number "$candidate_rss" "candidate average RSS"
    require_number "$baseline_rss" "baseline average RSS"
    cpu_delta="$(awk -v candidate="$candidate_cpu" -v baseline="$baseline_cpu" 'BEGIN { printf "%.1f", candidate - baseline }')"
    rss_delta="$(awk -v candidate="$candidate_rss" -v baseline="$baseline_rss" 'BEGIN { printf "%.1f", candidate - baseline }')"
    number_le "$cpu_delta" "$maximum_cpu_delta" || fail "average host CPU regression ${cpu_delta} points exceeds ${maximum_cpu_delta}"
    number_le "$rss_delta" "$maximum_rss_delta" || fail "average host RSS regression ${rss_delta} MiB exceeds ${maximum_rss_delta} MiB"
fi

echo "VirGL performance gate passed: windows=$windows failures=$failures misses=$misses average=${average_present}ms p95=${p95_present}ms peak=${peak_present}ms"
