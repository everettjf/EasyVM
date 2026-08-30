#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
pins="$project_root/scripts/virgl-runtime-pins.sh"
runtime_dir="${1:-}"

fail() {
  echo "verify-virgl-runtime: $*" >&2
  exit 1
}

[[ -n $runtime_dir ]] || fail "usage: $0 <runtime-directory-or-app>"
[[ -f $pins && ! -L $pins ]] || fail "missing pin manifest"
# shellcheck source=scripts/virgl-runtime-pins.sh
source "$pins"

if [[ $runtime_dir == *.app ]]; then
  runtime_dir="$runtime_dir/Contents/Frameworks/VirGLRuntime"
fi
[[ $runtime_dir == /* ]] || runtime_dir="$(cd "$(dirname "$runtime_dir")" && pwd -P)/$(basename "$runtime_dir")"
[[ -d $runtime_dir && ! -L $runtime_dir ]] || fail "unsafe or missing runtime directory: $runtime_dir"

expected="$(ezvm_virgl_runtime_files | sort)"
actual="$(find "$runtime_dir" -mindepth 1 -maxdepth 1 -type f -print | sed 's|.*/||' | sort)"
[[ $actual == "$expected" ]] || fail "runtime file set differs from the pinned manifest"
if find "$runtime_dir" -mindepth 1 -maxdepth 1 -type l | grep -q .; then
  fail "runtime contains symbolic links"
fi

for library_name in $(ezvm_virgl_runtime_files); do
  library="$runtime_dir/$library_name"
  file "$library" | grep -q 'Mach-O 64-bit.*arm64' || fail "non-arm64 image: $library_name"
  codesign --verify --strict --verbose=2 "$library"
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*) ;;
      *) fail "$library_name has an external dependency: $dependency" ;;
    esac
  done < <(otool -L "$library" | tail -n +2 | awk '{ print $1 }')
done

otool -L "$runtime_dir/libvirglrenderer.1.dylib" | \
  grep -Fq '@loader_path/libepoxy.0.dylib' || fail "virglrenderer does not resolve bundled libepoxy"
echo "Verified EZVM VirGL runtime at $runtime_dir"
