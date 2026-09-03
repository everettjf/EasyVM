#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
verifier="$project_root/scripts/verify-virgl-performance.sh"
temporary_directory="$(mktemp -d /tmp/ezvm-virgl-gate-tests.XXXXXX)"
trap 'rm -rf "$temporary_directory"' EXIT

write_report() {
    local path="$1"
    local backend="$2"
    local failures="$3"
    local misses="$4"
    local average_present="$5"
    local p95_present="$6"
    local peak_present="$7"
    local cpu="$8"
    local rss="$9"
    printf '%s\n' \
        'Format-Version: 2' \
        'Duration: 30s' \
        "Backend: $backend" \
        'Workload: hyprland-idle-1920x1080' \
        'macOS: 27.0 (26A123)' \
        'Hardware: Mac16,1' \
        "Host-Average-CPU-Percent: $cpu" \
        "Host-Average-RSS-MiB: $rss" \
        'VirGL-Window-Count: 5' \
        "VirGL-Drawable-Misses: $misses" \
        "VirGL-Presentation-Failures: $failures" \
        "VirGL-Average-Present-Ms: $average_present" \
        "VirGL-Maximum-Window-P95-Present-Ms: $p95_present" \
        "VirGL-Maximum-Present-Ms: $peak_present" > "$path"
}

candidate="$temporary_directory/candidate.txt"
baseline="$temporary_directory/baseline.txt"
write_report "$candidate" custom-virgl 0 1 0.7 2.2 25.0 35 900
write_report "$baseline" apple-virtio 0 0 unavailable unavailable unavailable 20 700
sed -i '' 's/VirGL-Window-Count: 5/VirGL-Window-Count: 0/' "$baseline"
"$verifier" "$candidate" "$baseline" >/dev/null

write_report "$candidate" custom-virgl 1 1 0.7 2.2 25.0 35 900
if "$verifier" "$candidate" "$baseline" >/dev/null 2>&1; then
    echo "A report with presentation failures passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 1 0.7 2.2 25.0 50.1 900
if "$verifier" "$candidate" "$baseline" >/dev/null 2>&1; then
    echo "A report over the CPU regression budget passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 1 0.7 2.2 25.0 35 900
sed 's/hyprland-idle-1920x1080/browser-scroll/' "$baseline" > "$temporary_directory/wrong-workload.txt"
if "$verifier" "$candidate" "$temporary_directory/wrong-workload.txt" >/dev/null 2>&1; then
    echo "Reports with different workloads were compared unexpectedly." >&2
    exit 1
fi

write_report "$temporary_directory/mislabeled-baseline.txt" apple-virtio 0 0 unavailable unavailable unavailable 20 700
if "$verifier" "$candidate" "$temporary_directory/mislabeled-baseline.txt" >/dev/null 2>&1; then
    echo "An Apple Virtio baseline containing VirGL windows passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 1 0.7 8.1 25.0 35 900
if "$verifier" "$candidate" "$baseline" >/dev/null 2>&1; then
    echo "A report over the P95 presentation budget passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 1 0.7 2.2 50.1 35 900
if "$verifier" "$candidate" "$baseline" >/dev/null 2>&1; then
    echo "A report over the absolute presentation budget passed unexpectedly." >&2
    exit 1
fi

echo "VirGL performance gate tests passed."
