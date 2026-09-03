#!/bin/bash

select_virgl_capture_pid() {
    local explicit_pid="${1:-}"
    local discovered_pids="${2:-}"
    local pid=""
    local count=0

    if [[ -n "$explicit_pid" ]]; then
        [[ "$explicit_pid" =~ ^[1-9][0-9]*$ ]] || {
            echo "EZVM_VIRGL_PID must be a positive process ID." >&2
            return 2
        }
        printf '%s\n' "$explicit_pid"
        return 0
    fi

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        count=$((count + 1))
        explicit_pid="$pid"
    done <<< "$discovered_pids"

    case "$count" in
        0)
            echo "No running EZVM process was found." >&2
            return 1
            ;;
        1)
            printf '%s\n' "$explicit_pid"
            ;;
        *)
            echo "Multiple EZVM processes are running. Set EZVM_VIRGL_PID to the VM window being measured." >&2
            return 1
            ;;
    esac
}
