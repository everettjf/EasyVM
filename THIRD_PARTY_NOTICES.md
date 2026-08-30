# Third-party notices

EZVM's original code is licensed separately from the runtime components it
redistributes. The Custom VirGL graphics backend bundles the following
components under their upstream licenses:

| Component | Runtime version | Pinned build recipe | License |
| --- | --- | --- | --- |
| virglrenderer | 1.0.33 | `startergo/homebrew-virglrenderer@20828ebf629191f4d48993ada3e631e6f92532c1` | MIT |
| libepoxy | 1.0.4 | `startergo/homebrew-libepoxy@eeb72845c15eeb9a57635fc54467234b2e38f51a` | MIT |
| ANGLE (`libEGL`, `libGLESv2`) | 1.0.15 | `startergo/homebrew-angle@b010ac372569747a4b265e75eaa72868c6849f62` | BSD-3-Clause |

Exact redistributed binary inputs, archive URLs, SHA-256 values, and build
recipe commits are defined in `scripts/virgl-runtime-pins.sh`. The libepoxy
recipe additionally pins upstream commit
`1b6d7db184bb1a0d9af0e200e06a0331028eaaae`. The current virglrenderer and
ANGLE recipes did not record their downloaded upstream revisions; their
archive checksums make the binary input reproducible but are not sufficient
source provenance. EZVM must replace those two inputs with builds from explicit
upstream commits before a public release. Release artifacts must retain this
notice and the complete license texts under `ThirdPartyLicenses/`.

Upstream source repositories:

- virglrenderer: <https://gitlab.freedesktop.org/virgl/virglrenderer>
- libepoxy: <https://github.com/anholt/libepoxy>
- ANGLE: <https://chromium.googlesource.com/angle/angle>
