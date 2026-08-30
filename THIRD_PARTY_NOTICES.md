# Third-party notices

EZVM's original code is licensed separately from the runtime components it
redistributes. The Custom VirGL graphics backend bundles the following
components under their upstream licenses:

| Component | Runtime version | Pinned build recipe | License |
| --- | --- | --- | --- |
| virglrenderer | `960bd6674a25a438da2aac8a0af8c6d6e2b3a77e` | `startergo/homebrew-virglrenderer@20828ebf629191f4d48993ada3e631e6f92532c1` | MIT |
| libepoxy | `1b6d7db184bb1a0d9af0e200e06a0331028eaaae` | `startergo/homebrew-libepoxy@eeb72845c15eeb9a57635fc54467234b2e38f51a` | MIT |
| ANGLE (`libEGL`, `libGLESv2`) | `2d91f554ab55bd1bef6998ab4094f60ae3e7feb5` | `startergo/homebrew-angle@b010ac372569747a4b265e75eaa72868c6849f62` | BSD-3-Clause |

Exact source and bootstrap binary inputs, archive URLs, SHA-256 values, build
recipe commits, and upstream commits are defined in
`scripts/virgl-runtime-pins.sh`. `scripts/prepare-virgl-sources.sh` verifies and
applies the pinned macOS patches without consulting a moving branch or tag.
The current release packager still consumes the checksum-pinned bootstrap
binaries while the source compiler is being qualified; public release remains
gated on producing and comparing the bundled dylibs from these prepared
sources. Release artifacts must retain this notice and the complete license
texts under `ThirdPartyLicenses/`.

Upstream source repositories:

- virglrenderer: <https://gitlab.freedesktop.org/virgl/virglrenderer>
- libepoxy: <https://github.com/anholt/libepoxy>
- ANGLE: <https://chromium.googlesource.com/angle/angle>
