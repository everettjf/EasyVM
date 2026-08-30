# EZVM VirGL runtime dependencies

EZVM does not redistribute the host libraries copied from Try Omarchy. That
installation is a development oracle only. Release artifacts must come from a
reproducible EZVM-owned build and be placed in:

`EZVM.app/Contents/Frameworks/VirGLRuntime/`

The runtime ABI currently requires exactly these arm64 files:

| File | Upstream | License | Purpose |
| --- | --- | --- | --- |
| `libvirglrenderer.1.dylib` | virglrenderer | MIT | VirGL command decoder and renderer |
| `libepoxy.0.dylib` | libepoxy | MIT | GL/EGL dispatch used by virglrenderer |
| `libEGL.dylib` | ANGLE | BSD-3-Clause | EGL with the Metal backend |
| `libGLESv2.dylib` | ANGLE | BSD-3-Clause | OpenGL ES implementation over Metal |

Bootstrap packaging is implemented by `scripts/build-virgl-runtime.sh` and
`scripts/verify-virgl-runtime.sh`. Exact source commits, archive hashes,
build-recipe commits, and the depot_tools commit live in
`scripts/virgl-runtime-pins.sh`. The bootstrap runtime builder
downloads only the three pinned archives, extracts exactly the four declared
Mach-O members, rewrites their install identities, rejects non-arm64 or
externally linked artifacts, and publishes the result atomically. The release
builder embeds and signs every dylib before signing the outer app.

The local source-qualified path is:

```sh
scripts/build-virgl-runtime-from-source.sh /tmp/ezvm-source-runtime
EZVM_VIRGL_RUNTIME_DIRECTORY=/tmp/ezvm-source-runtime \
  path/to/EZVM.app/Contents/MacOS/EZVM
```

It verifies immutable source and recipe archives, checks out ANGLE and
depot_tools at their declared commits, synchronizes the ANGLE commit's DEPS,
builds a Metal-only ANGLE, builds patched libepoxy and virglrenderer, rewrites
Mach-O identities, signs the local products, and runs the common runtime
verifier. Xcode 27 with its separately installed Metal Toolchain, Meson,
pkg-config, and network access are required. The first ANGLE DEPS sync uses
about 11 GB; subsequent local builds reuse that cache through
`.build/virgl-source-work`.

This source path was validated locally on macOS 27 by booting the Omarchy guest
through VirGL contexts and the zero-copy Metal scanout. The pinned bottles
remain a bootstrap supply chain for the existing release script; changing the
release pipeline is intentionally a separate decision. Any distributed build
must retain the license texts and notices for virglrenderer, libepoxy, and
ANGLE. The verifier and app packaging contract are independent of how those
four inputs were produced.

For local development only, set `EZVM_VIRGL_RUNTIME_DIRECTORY` to a directory
containing all four files. There is deliberately no production fallback to a
third-party app bundle.

## Reference oracle captured 2026-08-30

The validated Try Omarchy runtime had these SHA-256 hashes. They identify the
prototype oracle; they are not approved EZVM release inputs.

| File | SHA-256 |
| --- | --- |
| `libvirglrenderer.1.dylib` | `9cbf31c67a2053de7935f1229c5fd7f064eb67ce9ba45afd455abf08dbf4bad8` |
| `libepoxy.0.dylib` | `03c1d8fe2abc519e0234ee3666773b6311b19d9afb6501fb4db6658427d1a44a` |
| `libEGL.dylib` | `8172cbc7886c55dae1dda0efaf19fe6e4ef0a8f21447a74e1b3bea2cb6afc9f8` |
| `libGLESv2.dylib` | `40470b9e5279bed4fbe1d5b75805516737cc9be88ef1ce27203fd7753a124d00` |
