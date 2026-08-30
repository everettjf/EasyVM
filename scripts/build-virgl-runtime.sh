#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
pins="$project_root/scripts/virgl-runtime-pins.sh"
output_dir="${1:-$project_root/.build/virgl-runtime}"
archive_dir="${EZVM_VIRGL_ARCHIVE_DIR:-$project_root/.build/virgl-archives}"

fail() {
  echo "build-virgl-runtime: $*" >&2
  exit 1
}

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || \
  fail "the runtime build requires Apple Silicon macOS"
[[ -f $pins && ! -L $pins ]] || fail "missing pin manifest: $pins"
# shellcheck source=scripts/virgl-runtime-pins.sh
source "$pins"

for tool in codesign curl file install install_name_tool mktemp otool shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

case "$output_dir" in
  /*) ;;
  *) fail "output directory must be absolute: $output_dir" ;;
esac
case "$archive_dir" in
  /*) ;;
  *) fail "archive directory must be absolute: $archive_dir" ;;
esac

mkdir -p "$archive_dir" "$(dirname "$output_dir")"
work_dir="$(mktemp -d /tmp/ezvm-virgl-runtime.XXXXXX)"
publish_dir="$(mktemp -d "$(dirname "$output_dir")/.virgl-runtime-publish.XXXXXX")"
cleanup() {
  rm -rf "$work_dir" "$publish_dir"
}
trap cleanup EXIT

download() {
  local label=$1 url=$2 expected=$3 destination=$4 actual
  if [[ ! -f $destination ]]; then
    echo "Downloading $label"
    curl --fail --location --silent --show-error \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 3 --connect-timeout 20 "$url" -o "$destination"
  fi
  actual="$(shasum -a 256 "$destination" | awk '{ print $1 }')"
  [[ $actual == "$expected" ]] || fail "$label checksum mismatch"
}

require_member() {
  local label=$1 archive=$2 member=$3
  tar -tzf "$archive" -- "$member" | grep -Fxq "$member" || \
    fail "$label archive is missing $member"
}

virgl_archive="$archive_dir/$EZVM_VIRGL_ARCHIVE"
angle_archive="$archive_dir/$EZVM_ANGLE_ARCHIVE"
epoxy_archive="$archive_dir/$EZVM_EPOXY_ARCHIVE"
download "virglrenderer $EZVM_VIRGL_VERSION" "$EZVM_VIRGL_URL" "$EZVM_VIRGL_SHA256" "$virgl_archive"
download "ANGLE $EZVM_ANGLE_VERSION" "$EZVM_ANGLE_URL" "$EZVM_ANGLE_SHA256" "$angle_archive"
download "libepoxy $EZVM_EPOXY_VERSION" "$EZVM_EPOXY_URL" "$EZVM_EPOXY_SHA256" "$epoxy_archive"

require_member virglrenderer "$virgl_archive" "$EZVM_VIRGL_MEMBER"
require_member ANGLE "$angle_archive" "$EZVM_EGL_MEMBER"
require_member ANGLE "$angle_archive" "$EZVM_GLES_MEMBER"
require_member libepoxy "$epoxy_archive" "$EZVM_EPOXY_MEMBER"
tar -xzf "$virgl_archive" -C "$work_dir" "$EZVM_VIRGL_MEMBER"
tar -xzf "$angle_archive" -C "$work_dir" "$EZVM_EGL_MEMBER" "$EZVM_GLES_MEMBER"
tar -xzf "$epoxy_archive" -C "$work_dir" "$EZVM_EPOXY_MEMBER"

install -m 0755 "$work_dir/$EZVM_VIRGL_MEMBER" "$publish_dir/libvirglrenderer.1.dylib"
install -m 0755 "$work_dir/$EZVM_EPOXY_MEMBER" "$publish_dir/libepoxy.0.dylib"
install -m 0755 "$work_dir/$EZVM_EGL_MEMBER" "$publish_dir/libEGL.dylib"
install -m 0755 "$work_dir/$EZVM_GLES_MEMBER" "$publish_dir/libGLESv2.dylib"

install_name_tool -id @rpath/libvirglrenderer.1.dylib "$publish_dir/libvirglrenderer.1.dylib"
install_name_tool -change "@@HOMEBREW_PREFIX@@/opt/libepoxy/lib/libepoxy.0.dylib" \
  @loader_path/libepoxy.0.dylib "$publish_dir/libvirglrenderer.1.dylib" 2>/dev/null || true
install_name_tool -id @rpath/libepoxy.0.dylib "$publish_dir/libepoxy.0.dylib"
install_name_tool -id @rpath/libEGL.dylib "$publish_dir/libEGL.dylib"
install_name_tool -id @rpath/libGLESv2.dylib "$publish_dir/libGLESv2.dylib"

for library in "$publish_dir"/*.dylib; do
  file "$library" | grep -q 'Mach-O 64-bit.*arm64' || fail "non-arm64 runtime image: $library"
  codesign --force --sign - --timestamp=none "$library" >/dev/null
done

"$project_root/scripts/verify-virgl-runtime.sh" "$publish_dir"

if [[ -e $output_dir || -L $output_dir ]]; then
  [[ -d $output_dir && ! -L $output_dir ]] || fail "unsafe output target: $output_dir"
  rm -rf "$output_dir"
fi
mv "$publish_dir" "$output_dir"
echo "Prepared $output_dir"
