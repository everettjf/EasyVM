# VirGL performance validation

EZVM records two low-overhead graphics streams while a Custom VirGL virtual
machine is running on macOS 27:

- `graphics`: five-second FPS, Metal presentation time, missing drawables,
  presentation failures, requested display size, and drawable size.
- `virtio-gpu`: submitted/delivered/coalesced frames and the complete dynamic
  display handshake, including every guest `GET_DISPLAY_INFO` request.

## Capture a repeatable sample

Start the same workload in EZVM, leave it visible, and run:

```sh
scripts/capture-virgl-performance.sh 30
```

The command prints the path of a text report in `/tmp`. It includes per-second
host CPU/RSS samples plus the graphics logs for that exact interval. Use the
same VM CPU, memory, window size, display scaling, workload, and capture length
when comparing runs.

For a useful first comparison, capture separate 30-second samples for:

1. an idle Hyprland desktop;
2. continuous terminal scrolling;
3. repeated workspace switching and window movement;
4. browser scrolling or video playback.

Healthy runs should report zero presentation failures, few or no drawable
misses, bounded frame coalescing, and a stable FPS appropriate for the guest
workload. Coalescing is intentional: EZVM keeps at most one pending frame so it
can discard stale work instead of increasing visible latency.

## Validate dynamic resolution

Enter full screen, wait a few seconds, exit full screen, and capture a report.
For each size transition, the logs should contain this sequence:

1. `VirGL display refresh` with the final logical and requested pixel size;
2. `publishing display configuration`;
3. `interrupt delivered`;
4. a later guest `GET_DISPLAY_INFO` with the same generation and size;
5. `event cleared`.

The setup console may keep a fixed mode even when this handshake succeeds.
Final visual validation therefore needs the real Hyprland desktop.
