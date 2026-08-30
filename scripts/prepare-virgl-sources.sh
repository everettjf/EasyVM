#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
pins="$project_root/scripts/virgl-runtime-pins.sh"
archive_dir="${EZVM_VIRGL_SOURCE_ARCHIVE_DIR:-$project_root/.build/virgl-source-archives}"
output_dir="${1:-$project_root/.build/virgl-sources}"

fail() {
  echo "prepare-virgl-sources: $*" >&2
  exit 1
}

[[ -f $pins && ! -L $pins ]] || fail "missing pin manifest: $pins"
# shellcheck source=scripts/virgl-runtime-pins.sh
source "$pins"

for tool in curl patch shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
for path in "$archive_dir" "$output_dir"; do
  case "$path" in
    /*) ;;
    *) fail "path must be absolute: $path" ;;
  esac
done

mkdir -p "$archive_dir" "$(dirname "$output_dir")"
work_dir="$(mktemp -d /tmp/ezvm-virgl-sources.XXXXXX)"
publish_dir="$(mktemp -d "$(dirname "$output_dir")/.virgl-sources-publish.XXXXXX")"
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
  [[ $actual == "$expected" ]] || fail "$label checksum mismatch: $actual"
}

fetch() {
  local label=$1 archive=$2 url=$3 sha=$4
  download "$label" "$url" "$sha" "$archive_dir/$archive"
  tar -xzf "$archive_dir/$archive" -C "$work_dir"
}

fetch "virglrenderer source" "$EZVM_VIRGL_SOURCE_ARCHIVE" "$EZVM_VIRGL_SOURCE_URL" "$EZVM_VIRGL_SOURCE_SHA256"
fetch "ANGLE source" "$EZVM_ANGLE_SOURCE_ARCHIVE" "$EZVM_ANGLE_SOURCE_URL" "$EZVM_ANGLE_SOURCE_SHA256"
fetch "libepoxy source" "$EZVM_EPOXY_SOURCE_ARCHIVE" "$EZVM_EPOXY_SOURCE_URL" "$EZVM_EPOXY_SOURCE_SHA256"
fetch "virglrenderer recipe" "$EZVM_VIRGL_RECIPE_ARCHIVE" "$EZVM_VIRGL_RECIPE_URL" "$EZVM_VIRGL_RECIPE_SHA256"
fetch "ANGLE recipe" "$EZVM_ANGLE_RECIPE_ARCHIVE" "$EZVM_ANGLE_RECIPE_URL" "$EZVM_ANGLE_RECIPE_SHA256"
fetch "libepoxy recipe" "$EZVM_EPOXY_RECIPE_ARCHIVE" "$EZVM_EPOXY_RECIPE_URL" "$EZVM_EPOXY_RECIPE_SHA256"

virgl="$work_dir/virglrenderer-$EZVM_VIRGL_UPSTREAM_COMMIT"
angle="$work_dir/angle-$EZVM_ANGLE_UPSTREAM_COMMIT"
epoxy="$work_dir/libepoxy-$EZVM_EPOXY_UPSTREAM_COMMIT"
virgl_recipe="$work_dir/homebrew-virglrenderer-$EZVM_VIRGL_BUILD_RECIPE_COMMIT"
angle_recipe="$work_dir/homebrew-angle-$EZVM_ANGLE_BUILD_RECIPE_COMMIT"
epoxy_recipe="$work_dir/homebrew-libepoxy-$EZVM_EPOXY_BUILD_RECIPE_COMMIT"

[[ -d $virgl && -d $angle && -d $epoxy ]] || fail "an upstream archive has an unexpected root"
patch -d "$virgl" -p1 --batch -i "$virgl_recipe/patches/virglrenderer-macos-unified.patch"
patch -d "$angle" -p1 --batch -i "$angle_recipe/patches/angle-changes-main.patch"
# This mailbox contains consecutive changes to gen_dispatch.py, so it must be
# applied for real rather than checked with a single non-mutating dry run.
patch -d "$epoxy" -p1 --batch -i "$epoxy_recipe/patches/libepoxy-akihikodaki-egl15.patch"

for reject in "$virgl" "$angle" "$epoxy"; do
  if find "$reject" -name '*.rej' -print -quit | grep -q .; then
    fail "a pinned patch produced a reject under $reject"
  fi
done

mv "$virgl" "$publish_dir/virglrenderer"
mv "$angle" "$publish_dir/angle"
mv "$epoxy" "$publish_dir/libepoxy"
cat >"$publish_dir/SOURCE-PINS.txt" <<EOF
virglrenderer $EZVM_VIRGL_UPSTREAM_COMMIT $EZVM_VIRGL_SOURCE_SHA256
ANGLE $EZVM_ANGLE_UPSTREAM_COMMIT $EZVM_ANGLE_SOURCE_SHA256
libepoxy $EZVM_EPOXY_UPSTREAM_COMMIT $EZVM_EPOXY_SOURCE_SHA256
EOF

if [[ -e $output_dir || -L $output_dir ]]; then
  [[ -d $output_dir && ! -L $output_dir ]] || fail "unsafe output target: $output_dir"
  rm -rf "$output_dir"
fi
mv "$publish_dir" "$output_dir"
echo "Prepared pinned and patched sources at $output_dir"
