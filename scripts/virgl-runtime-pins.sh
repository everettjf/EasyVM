#!/bin/bash

# This file is sourced by the VirGL runtime build and verification scripts.
# Archive checksums pin the exact redistributable inputs. Upstream commits
# identify the corresponding source audit points; updating either requires a
# new runtime compatibility and license review.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "virgl-runtime-pins.sh must be sourced" >&2
  exit 64
fi

readonly EZVM_VIRGL_BUILD_RECIPE_COMMIT=20828ebf629191f4d48993ada3e631e6f92532c1
readonly EZVM_ANGLE_BUILD_RECIPE_COMMIT=b010ac372569747a4b265e75eaa72868c6849f62
readonly EZVM_EPOXY_BUILD_RECIPE_COMMIT=eeb72845c15eeb9a57635fc54467234b2e38f51a
readonly EZVM_EPOXY_UPSTREAM_COMMIT=1b6d7db184bb1a0d9af0e200e06a0331028eaaae

readonly EZVM_VIRGL_VERSION=1.0.33
readonly EZVM_VIRGL_ARCHIVE=virglrenderer-1.0.33.arm64_sequoia.bottle.tar.gz
readonly EZVM_VIRGL_URL=https://github.com/startergo/homebrew-virglrenderer/releases/download/v1.0.33/virglrenderer-1.0.33.arm64_sequoia.bottle.tar.gz
readonly EZVM_VIRGL_SHA256=26ad3e927d300587024cd92276d38bf813f6228d130a1800c97f1c18688b34ba
readonly EZVM_VIRGL_MEMBER=virglrenderer/1.0.33/lib/libvirglrenderer.1.dylib

readonly EZVM_ANGLE_VERSION=1.0.15
readonly EZVM_ANGLE_ARCHIVE=angle-1.0.15.arm64_sequoia.bottle.tar.gz
readonly EZVM_ANGLE_URL=https://github.com/startergo/homebrew-angle/releases/download/v1.0.15/angle-1.0.15.arm64_sequoia.bottle.tar.gz
readonly EZVM_ANGLE_SHA256=2b41a696f450a941016adf8b157e754c3223b6032ac9b9f0aac4216e899074c7
readonly EZVM_EGL_MEMBER=angle/1.0.15/lib/libEGL.dylib
readonly EZVM_GLES_MEMBER=angle/1.0.15/lib/libGLESv2.dylib

readonly EZVM_EPOXY_VERSION=1.0.4
readonly EZVM_EPOXY_ARCHIVE=libepoxy-1.0.4.arm64_sequoia.bottle.tar.gz
readonly EZVM_EPOXY_URL=https://github.com/startergo/homebrew-libepoxy/releases/download/v1.0.4/libepoxy-1.0.4.arm64_sequoia.bottle.tar.gz
readonly EZVM_EPOXY_SHA256=8787cc8c34921834665262dff4941216dd6717edddf2c6d5cdfe04f03b24c517
readonly EZVM_EPOXY_MEMBER=libepoxy/1.0.4/lib/libepoxy.0.dylib

ezvm_virgl_runtime_files() {
  printf '%s\n' \
    libvirglrenderer.1.dylib \
    libepoxy.0.dylib \
    libEGL.dylib \
    libGLESv2.dylib
}
