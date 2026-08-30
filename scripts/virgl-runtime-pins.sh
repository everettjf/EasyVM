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

# Immutable source inputs. GitHub and GitLab commit archives are used instead
# of mutable tag or branch archives. These hashes were verified independently
# from the bottle payloads before enabling the production backend.
readonly EZVM_VIRGL_UPSTREAM_COMMIT=960bd6674a25a438da2aac8a0af8c6d6e2b3a77e
readonly EZVM_VIRGL_SOURCE_ARCHIVE=virglrenderer-$EZVM_VIRGL_UPSTREAM_COMMIT.tar.gz
readonly EZVM_VIRGL_SOURCE_URL=https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/$EZVM_VIRGL_UPSTREAM_COMMIT/$EZVM_VIRGL_SOURCE_ARCHIVE
readonly EZVM_VIRGL_SOURCE_SHA256=b7b9aaa05b10765c244790b2f2580e34e7cee383b4419ce5dd0c111d59e464a3

readonly EZVM_ANGLE_UPSTREAM_COMMIT=2d91f554ab55bd1bef6998ab4094f60ae3e7feb5
readonly EZVM_ANGLE_SOURCE_ARCHIVE=angle-$EZVM_ANGLE_UPSTREAM_COMMIT.tar.gz
readonly EZVM_ANGLE_SOURCE_URL=https://github.com/google/angle/archive/$EZVM_ANGLE_UPSTREAM_COMMIT.tar.gz
readonly EZVM_ANGLE_SOURCE_SHA256=c24c4e7bc464a63069b67a9f663717b6e0f4a5ff4b6404215a7dc98ea83c6ba7

readonly EZVM_EPOXY_SOURCE_ARCHIVE=libepoxy-$EZVM_EPOXY_UPSTREAM_COMMIT.tar.gz
readonly EZVM_EPOXY_SOURCE_URL=https://github.com/anholt/libepoxy/archive/$EZVM_EPOXY_UPSTREAM_COMMIT.tar.gz
readonly EZVM_EPOXY_SOURCE_SHA256=15f769a8f24c361c8de28d72625daf07d0107b683fa0a5118d0aa8b0c5fc9eab

readonly EZVM_VIRGL_RECIPE_ARCHIVE=homebrew-virglrenderer-$EZVM_VIRGL_BUILD_RECIPE_COMMIT.tar.gz
readonly EZVM_VIRGL_RECIPE_URL=https://github.com/startergo/homebrew-virglrenderer/archive/$EZVM_VIRGL_BUILD_RECIPE_COMMIT.tar.gz
readonly EZVM_VIRGL_RECIPE_SHA256=afb58a118a11cabf381b1e53e155b0bb07d995ffb3cbfeb09decfb723cd41e1a
readonly EZVM_ANGLE_RECIPE_ARCHIVE=homebrew-angle-$EZVM_ANGLE_BUILD_RECIPE_COMMIT.tar.gz
readonly EZVM_ANGLE_RECIPE_URL=https://github.com/startergo/homebrew-angle/archive/$EZVM_ANGLE_BUILD_RECIPE_COMMIT.tar.gz
readonly EZVM_ANGLE_RECIPE_SHA256=076df85af0f3bcd5d1232be7285bdb0bc305f28df155bc5ac6d19e83e27e3195
readonly EZVM_EPOXY_RECIPE_ARCHIVE=homebrew-libepoxy-$EZVM_EPOXY_BUILD_RECIPE_COMMIT.tar.gz
readonly EZVM_EPOXY_RECIPE_URL=https://github.com/startergo/homebrew-libepoxy/archive/$EZVM_EPOXY_BUILD_RECIPE_COMMIT.tar.gz
readonly EZVM_EPOXY_RECIPE_SHA256=2385e015283816237615c3933b58c174ca8fd55be351a56799cdfeb656b6f789

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
