# VirGL performance validation

For architecture, invariants, known failure modes, and the maintained test
checklist, read [Custom VirGL architecture and engineering notes](CUSTOM_VIRGL_ARCHITECTURE.md)
first.

EZVM records two low-overhead graphics streams while a Custom VirGL virtual
machine is running on macOS 27:

- `graphics`: five-second FPS, Metal presentation time, missing drawables,
  presentation failures, requested display size, and drawable size.
- `virtio-gpu`: submitted/delivered/coalesced frames and the complete dynamic
  display handshake, including every guest `GET_DISPLAY_INFO` request.

## Capture a repeatable sample

Start the same workload in EZVM, leave it visible, and identify the workload in
the capture so incompatible samples cannot be compared accidentally:

```sh
EZVM_VIRGL_BACKEND=custom-virgl \
EZVM_VIRGL_WORKLOAD=hyprland-idle-1920x1080 \
scripts/capture-virgl-performance.sh 30 /tmp/virgl.txt
```

The command prints the path of a text report in `/tmp`. It includes per-second
host CPU/RSS samples, percentile summaries, aggregated five-second VirGL frame
windows, and the graphics logs for that exact interval. Use the same VM CPU,
memory, window size, display scaling, workload, and capture length when
comparing runs.

Only one EZVM process may be running by default. When deliberately comparing
multiple concurrent VMs, identify the exact app process instead of relying on
process order:

```sh
EZVM_VIRGL_PID=12345 \
EZVM_VIRGL_BACKEND=custom-virgl \
EZVM_VIRGL_WORKLOAD=browser-scroll-1920x1080 \
scripts/capture-virgl-performance.sh 30 /tmp/virgl.txt
```

The capture rejects a missing, exited, non-EZVM, or ambiguous process before
collecting metrics.

Capture the same VM and workload after selecting Apple Virtio graphics:

```sh
EZVM_VIRGL_BACKEND=apple-virtio \
EZVM_VIRGL_WORKLOAD=hyprland-idle-1920x1080 \
scripts/capture-virgl-performance.sh 30 /tmp/apple-virtio.txt
```

Then apply the checked-in health and regression budgets:

```sh
scripts/verify-virgl-performance.sh /tmp/virgl.txt /tmp/apple-virtio.txt
```

The gate rejects presentation failures, excessive drawable misses, excessive
average or per-window P95 latency, and pathological single-frame stalls. P95 is
the primary smoothness signal; the absolute maximum remains a wider hard-stop
guard so one scheduler spike does not misclassify an otherwise stable run.
It also rejects large host CPU/RSS regressions and refuses to compare reports whose
duration, workload, hardware, or macOS build differ. Thresholds can be tightened
for a release matrix through the documented `EZVM_VIRGL_MAX_*` environment
variables in the verifier; loosening them requires recording the reason with
the release evidence.

For a useful first comparison, capture separate 30-second samples for:

1. an idle Hyprland desktop;
2. continuous terminal scrolling;
3. repeated workspace switching and window movement;
4. browser scrolling or video playback.

The signed release gate can automate the first, idle-desktop comparison without
editing the source VM. It makes independent copy-on-write fixture clones, waits
for Guest Agent transfer verification, holds each VM for the bounded capture,
forces the requested graphics backend, and applies the same verifier:

```sh
scripts/verify-release-virgl-idle-performance.sh \
  /path/to/EZVM.app \
  /path/to/Omarchy.ezvm \
  /path/to/Omarchy.ezvm/.EZVMAgent/config.json \
  /tmp/ezvm-virgl-idle
```

This closes the repeatability gap for the idle baseline only. Interactive
scrolling, workspace movement, and video remain human-driven representative
workloads and must not be inferred from this result.

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

## August 31–September 1, 2026 reference run

The final Omarchy/Hyprland validation established a useful local baseline:

- approximately 60 FPS in windowed and full-screen operation;
- typical presentation time around 0.4–0.8 ms;
- zero drawable misses and zero presentation failures in the final sample;
- one observed transition peak of 5.23 ms;
- full-screen geometry `bounds=1920x1080 guest=1920x1080
  layer=1920x1080 drawable=3840x2160`;
- display generation 2 was read through `GET_EDID` and acknowledged through
  `GET_DISPLAY_INFO` before the event cleared.
- a clean 64 GiB sparse Omarchy image completed first-run setup without the
  keyboard/timezone loop, reached Hyprland, adapted to full screen after the
  compositor watcher became ready, accepted continuous text immediately, and
  passed human browser-wheel verification;
- a signed 1.0.64 rebuild accepted synthesized uppercase and shifted
  punctuation, obtained a NAT lease and default route, resolved public names,
  completed TLS 1.3/HTTP/2 to `archlinux.org`, and fetched live package update
  metadata through `checkupdates`.

## September 2, 2026 signed idle A/B

The automated COW-clone gate passed with the Developer ID-signed EZVM 2.0.0
candidate on macOS 27.0 (26A5425a), Mac15,6, using the same Omarchy fixture and
30-second `hyprland-idle` workload for both backends:

| Metric | Custom VirGL | Apple Virtio |
| --- | ---: | ---: |
| Average host CPU | 8.7% | 0.5% |
| Average host RSS | 180.8 MiB | 153.2 MiB |
| Average FPS | 60.7 | Not exposed |
| Minimum five-second FPS | 59.4 | Not exposed |
| Average presentation | 0.71 ms | Not exposed |
| Worst-window P95 presentation | 1.15 ms | Not exposed |
| Absolute peak presentation | 2.80 ms | Not exposed |
| Drawable misses / presentation failures | 0 / 0 | 0 / 0 |

The 8.2 percentage-point CPU and 27.6 MiB RSS costs are within the checked-in
idle budgets. This proves a repeatable idle baseline, not interactive browser,
video, scrolling, or workspace-switching performance.

Do not use a terminal scrollback result as the sole wheel acceptance test.
Terminal alternate-screen mode, selection state, and application bindings can
consume or ignore wheel events. Validate at least one ordinary scroll view
(the browser was used for the reference run) and correlate it with bounded
Agent wheel delivery.

Treat this as a regression reference, not a universal performance claim. A
comparison with another VM product is valid only when host, guest image,
CPU/memory allocation, resolution, scale, workload, and capture duration match.

## September 3, 2026 signed idle A/B

The current EZVM 2.0.0 Developer ID candidate passed two more same-fixture
`hyprland-idle` comparisons on macOS 27.0 (26A5425a), Mac15,6. The first
30-second capture reported 15.0% average host CPU and 186.3 MiB average RSS for
Custom VirGL versus 0.7% and 158.6 MiB for Apple Virtio. Custom VirGL sustained
60.8 FPS with zero drawable misses or presentation failures; average, worst-
window P95, and absolute-peak presentation were 1.12 ms, 1.52 ms, and 3.34 ms.

A 60-second repeat reduced the Custom VirGL average to 11.5% CPU while Apple
Virtio measured 0.5%; average RSS was 190.7 MiB versus 162.6 MiB. Across 12
VirGL windows it sustained 60.4 FPS, zero misses, and zero failures, with
0.84 ms average and 1.31 ms worst-window P95 presentation. One 34.58 ms sample
occurred in the first warm-up window; every later window peaked at or below
3.32 ms. Both runs passed the checked-in CPU, memory, cadence, and latency
budgets. The CPU spread between repeated idle captures reinforces that this is
a regression gate, not a substitute for controlled interactive browser,
scrolling, video, and workspace-switching workloads.

## Symptom routing

| Symptom | Inspect first |
| --- | --- |
| Typed text appears after pointer movement | submitted/delivered frames, display cadence, Agent acknowledgement; do not assume key loss |
| Full screen uses the old mode | generation publish → interrupt → EDID/display-info → event clear sequence |
| Vertical stretch or huge UI | guest scanout size vs logical bounds; do not stretch the fallback framebuffer |
| Black desktop with `DRAW_VBO` errors | target-aware resource validation, especially `PIPE_BUFFER` byte widths |
| Super shortcut is ignored | first responder, AppKit local monitor, full down/up chord, Agent desktop-ready ownership |
| Scroll jumps too far | bounded wheel delta and high-resolution trackpad conversion |
