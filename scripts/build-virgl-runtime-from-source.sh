#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
pins="$project_root/scripts/virgl-runtime-pins.sh"
output_dir="${1:-$project_root/.build/virgl-runtime-source}"
work_root="${EZVM_VIRGL_SOURCE_WORK_DIR:-$project_root/.build/virgl-source-work}"
archive_dir="${EZVM_VIRGL_SOURCE_ARCHIVE_DIR:-$project_root/.build/virgl-source-archives}"
python_bin="${VIRGL_PYTHON:-/usr/bin/python3}"

fail() {
  echo "build-virgl-runtime-from-source: $*" >&2
  exit 1
}

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail "requires Apple Silicon macOS"
[[ -f $pins && ! -L $pins ]] || fail "missing pin manifest: $pins"
# shellcheck source=scripts/virgl-runtime-pins.sh
source "$pins"
for tool in codesign curl git install install_name_tool meson otool patch pkg-config shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
for path in "$output_dir" "$work_root" "$archive_dir"; do
  case "$path" in
    /*) ;;
    *) fail "path must be absolute: $path" ;;
  esac
done
[[ $python_bin == /* && -x $python_bin ]] || fail "Python must be an executable absolute path: $python_bin"

mkdir -p "$work_root" "$archive_dir" "$(dirname "$output_dir")"
prepared="$work_root/prepared"
EZVM_VIRGL_SOURCE_ARCHIVE_DIR="$archive_dir" \
  "$project_root/scripts/prepare-virgl-sources.sh" "$prepared"

download() {
  local label=$1 url=$2 expected=$3 destination=$4 actual
  if [[ ! -f $destination ]]; then
    curl --fail --location --silent --show-error \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 3 --connect-timeout 20 "$url" -o "$destination"
  fi
  actual="$(shasum -a 256 "$destination" | awk '{ print $1 }')"
  [[ $actual == "$expected" ]] || fail "$label checksum mismatch: $actual"
}

angle_recipe_archive="$archive_dir/$EZVM_ANGLE_RECIPE_ARCHIVE"
download ANGLE-recipe "$EZVM_ANGLE_RECIPE_URL" "$EZVM_ANGLE_RECIPE_SHA256" "$angle_recipe_archive"
recipe_extract="$work_root/angle-recipe"
rm -rf "$recipe_extract"
mkdir -p "$recipe_extract"
tar -xzf "$angle_recipe_archive" -C "$recipe_extract" --strip-components=1
angle_patch="$recipe_extract/patches/angle-changes-main.patch"
[[ -f $angle_patch ]] || fail "ANGLE recipe is missing its macOS patch"

depot_tools="$work_root/depot_tools"
if [[ ! -d $depot_tools/.git ]]; then
  git clone --no-checkout https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_tools"
fi
git -C "$depot_tools" fetch --depth=1 origin "$EZVM_DEPOT_TOOLS_COMMIT"
git -C "$depot_tools" checkout --detach FETCH_HEAD
[[ $(git -C "$depot_tools" rev-parse HEAD) == "$EZVM_DEPOT_TOOLS_COMMIT" ]] || \
  fail "depot_tools checkout drifted"

angle="$work_root/angle"
if [[ ! -d $angle/.git ]]; then
  mkdir -p "$angle"
  git -C "$angle" init
  git -C "$angle" remote add origin https://chromium.googlesource.com/angle/angle
fi
git -C "$angle" fetch --depth=1 origin "$EZVM_ANGLE_UPSTREAM_COMMIT"
# A previous successful build leaves the pinned macOS patch applied in this
# reusable checkout. A plain checkout of the same commit preserves those
# tracked modifications, so the next build tries to reverse/repair a working
# tree that gclient may also have refreshed. Force the pinned source tree back
# to its authoritative commit before dependency synchronization instead.
git -C "$angle" checkout --force --detach FETCH_HEAD
[[ $(git -C "$angle" rev-parse HEAD) == "$EZVM_ANGLE_UPSTREAM_COMMIT" ]] || fail "ANGLE checkout drifted"

depot_path="$depot_tools:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ ! -f $angle/.gclient ]]; then
  (cd "$angle" && env DEPOT_TOOLS_UPDATE=0 PATH="$depot_path" /usr/bin/python3 scripts/bootstrap.py)
fi
(cd "$angle" && env DEPOT_TOOLS_UPDATE=0 PATH="$depot_path" \
  gclient sync --no-history --shallow --jobs "${EZVM_GCLIENT_JOBS:-4}")
[[ $(git -C "$angle" rev-parse HEAD) == "$EZVM_ANGLE_UPSTREAM_COMMIT" ]] || \
  fail "gclient changed the pinned ANGLE checkout"
if git -C "$angle" apply --check "$angle_patch"; then
  git -C "$angle" apply "$angle_patch"
elif ! git -C "$angle" apply --reverse --check "$angle_patch"; then
  fail "ANGLE macOS patch neither applies nor is already applied"
fi

shopt -s nullglob
metal_candidates=(
  /var/run/com.apple.security.cryptexd/mnt/*/Metal.xctoolchain/usr/bin/metal
  "$HOME"/Library/Developer/DVTDownloads/MetalToolchain/mounts/*/Metal.xctoolchain/usr/bin/metal
)
shopt -u nullglob
metal_bin=
for metal_candidate in "${metal_candidates[@]}"; do
  candidate_bin="$(dirname "$metal_candidate")"
  if [[ -x $candidate_bin/metal && -x $candidate_bin/metallib ]]; then
    metal_bin=$candidate_bin
    break
  fi
done
[[ -n $metal_bin ]] || fail "Metal Toolchain is not installed or is incomplete"
tool_wrappers="$work_root/tool-wrappers"
mkdir -p "$tool_wrappers"
sed "s|@@METAL_BIN@@|$metal_bin|g" >"$tool_wrappers/xcrun" <<'EOF'
#!/bin/sh
case "${1:-}" in
  metal|metallib)
    tool=$1
    shift
    exec "@@METAL_BIN@@/$tool" "$@"
    ;;
  *) exec /usr/bin/xcrun "$@" ;;
esac
EOF
chmod +x "$tool_wrappers/xcrun"

angle_out="$angle/out/ezvm-release"
gn_args='target_cpu="arm64" angle_build_all=false is_debug=false symbol_level=0 angle_has_frame_capture=false angle_enable_gl=false angle_enable_vulkan=false angle_enable_swiftshader=false angle_enable_wgpu=false angle_enable_metal=true angle_enable_null=false angle_enable_abseil=false use_siso=false use_system_xcode=true use_custom_libcxx=false use_lld=false is_component_build=false treat_warnings_as_errors=false fatal_linker_warnings=false'
(cd "$angle" && buildtools/mac/gn gen out/ezvm-release --args="$gn_args")
env PATH="$tool_wrappers:$PATH" "$angle/third_party/ninja/ninja" -C "$angle_out" libEGL libGLESv2

pc_dir="$work_root/pkgconfig"
mkdir -p "$pc_dir"
cat >"$pc_dir/egl.pc" <<EOF
prefix=$angle_out
includedir=$angle/include
libdir=\${prefix}
Name: EGL
Description: EZVM pinned ANGLE EGL
Version: 1.5
Libs: -L\${libdir} -lEGL
Cflags: -I\${includedir}
EOF
cat >"$pc_dir/glesv2.pc" <<EOF
prefix=$angle_out
includedir=$angle/include
libdir=\${prefix}
Name: GLESv2
Description: EZVM pinned ANGLE GLESv2
Version: 3.0
Libs: -L\${libdir} -lGLESv2
Cflags: -I\${includedir}
EOF

prefix="$work_root/prefix"
epoxy_build="$work_root/libepoxy-build"
virgl_build="$work_root/virglrenderer-build"
rm -rf "$prefix" "$epoxy_build" "$virgl_build"
env PKG_CONFIG_PATH="$pc_dir" meson setup "$epoxy_build" "$prepared/libepoxy" \
  --prefix="$prefix" -Degl=yes -Dx11=false -Dtests=false
meson compile -C "$epoxy_build"
meson install -C "$epoxy_build"

native_file="$work_root/virgl-native.ini"
printf "[binaries]\npython = '%s'\n" "$python_bin" >"$native_file"
env PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$pc_dir" meson setup \
  --native-file "$native_file" "$virgl_build" "$prepared/virglrenderer" \
  --prefix="$prefix" -Dc_args="-I$angle/include" -Dcpp_args="-I$angle/include" \
  '-Ddrm-renderers=[]' -Dvenus=true -Dtests=false -Dvideo=false -Dtracing=none
meson compile -C "$virgl_build"
meson install -C "$virgl_build"

publish_dir="$(mktemp -d "$(dirname "$output_dir")/.virgl-source-publish.XXXXXX")"
cleanup_publish() { rm -rf "$publish_dir"; }
trap cleanup_publish EXIT
install -m 0755 "$prefix/lib/libvirglrenderer.1.dylib" "$publish_dir/libvirglrenderer.1.dylib"
install -m 0755 "$prefix/lib/libepoxy.0.dylib" "$publish_dir/libepoxy.0.dylib"
install -m 0755 "$angle_out/libEGL.dylib" "$publish_dir/libEGL.dylib"
install -m 0755 "$angle_out/libGLESv2.dylib" "$publish_dir/libGLESv2.dylib"
install_name_tool -id @rpath/libvirglrenderer.1.dylib "$publish_dir/libvirglrenderer.1.dylib"
install_name_tool -change "$prefix/lib/libepoxy.0.dylib" @loader_path/libepoxy.0.dylib \
  "$publish_dir/libvirglrenderer.1.dylib"
install_name_tool -id @rpath/libepoxy.0.dylib "$publish_dir/libepoxy.0.dylib"
install_name_tool -id @rpath/libEGL.dylib "$publish_dir/libEGL.dylib"
install_name_tool -id @rpath/libGLESv2.dylib "$publish_dir/libGLESv2.dylib"
for library in "$publish_dir"/*.dylib; do
  codesign --force --sign - --timestamp=none "$library" >/dev/null
done
"$project_root/scripts/verify-virgl-runtime.sh" "$publish_dir"
grep -aFq "${EZVM_ANGLE_UPSTREAM_COMMIT:0:12}" "$publish_dir/libGLESv2.dylib" || \
  fail "ANGLE binary does not contain the pinned commit identity"

if [[ -e $output_dir || -L $output_dir ]]; then
  [[ -d $output_dir && ! -L $output_dir ]] || fail "unsafe output target: $output_dir"
  rm -rf "$output_dir"
fi
mv "$publish_dir" "$output_dir"
trap - EXIT
echo "Built source-qualified EZVM VirGL runtime at $output_dir"
