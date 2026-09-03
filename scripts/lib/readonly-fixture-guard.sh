#!/bin/bash

# This file is sourced by release verification scripts. It deliberately hashes
# metadata rather than VM disk contents: the guard should detect writes to a
# frozen fixture without reading tens of gigabytes before and after every run.

clone_readonly_fixture() {
  local fixture_path="${1:-}"
  local clone_path="${2:-}"
  local fixture_real
  local clone_parent_real

  [[ -d "$fixture_path" && ! -L "$fixture_path" ]] || {
    echo "read-only fixture must be a real directory: $fixture_path" >&2
    return 2
  }
  [[ -n "$clone_path" && ! -e "$clone_path" && ! -L "$clone_path" ]] || {
    echo "fixture clone destination must not already exist: $clone_path" >&2
    return 2
  }
  [[ -d "$(dirname "$clone_path")" ]] || {
    echo "fixture clone parent does not exist: $(dirname "$clone_path")" >&2
    return 2
  }

  fixture_real="$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$fixture_path")" || return 2
  clone_parent_real="$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$(dirname "$clone_path")")" || return 2
  case "$clone_parent_real/$(basename "$clone_path")/" in
    "$fixture_real"/*)
      echo "fixture clone destination must be outside the read-only fixture: $clone_path" >&2
      return 2
      ;;
  esac

  # -c requests APFS copy-on-write cloning. Never fall back to a command that
  # could operate in place or make the source package writable to the test.
  cp -cR "$fixture_real" "$clone_path" || return
  [[ -d "$clone_path" && ! -L "$clone_path" ]] || {
    echo "fixture clone was not created as a real directory: $clone_path" >&2
    return 1
  }
}

fixture_metadata_fingerprint() {
  local fixture_path="${1:-}"
  [[ -d "$fixture_path" && ! -L "$fixture_path" ]] || return 2

  ruby -rdigest -rfind -e '
    root = File.expand_path(ARGV.fetch(0))
    entries = []
    Find.find(root) { |path| entries << path }
    digest = Digest::SHA256.new
    entries.sort.each do |path|
      stat = File.lstat(path)
      relative = path == root ? "." : path.delete_prefix("#{root}/")
      fields = [
        relative,
        stat.ftype,
        stat.mode,
        stat.uid,
        stat.gid,
        stat.size,
        stat.mtime.to_i,
        stat.mtime.nsec,
        stat.ctime.to_i,
        stat.ctime.nsec,
        (File.readlink(path) if stat.symlink?),
      ]
      fields.each { |field| digest.update(field.to_s).update("\0") }
    end
    puts digest.hexdigest
  ' "$fixture_path"
}

assert_fixture_unchanged() {
  local fixture_path="${1:-}"
  local expected_fingerprint="${2:-}"
  local actual_fingerprint
  actual_fingerprint="$(fixture_metadata_fingerprint "$fixture_path")" || {
    echo "read-only fixture disappeared or became invalid: $fixture_path" >&2
    return 1
  }
  if [[ "$actual_fingerprint" != "$expected_fingerprint" ]]; then
    echo "read-only fixture changed during verification: $fixture_path" >&2
    return 1
  fi
}
