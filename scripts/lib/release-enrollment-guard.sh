#!/bin/bash

# Validate a release-smoke enrollment without ever printing its token.
validate_release_enrollment() {
  local vm_path="${1:-}"
  local enrollment_path="${2:-}"
  local permissions

  [[ -d "$vm_path" && ! -L "$vm_path" && -f "$vm_path/MachineIdentifier" ]] || {
    echo "release fixture has no trustworthy MachineIdentifier: $vm_path" >&2
    return 2
  }
  [[ -f "$enrollment_path" && ! -L "$enrollment_path" ]] || {
    echo "release enrollment must be a regular, non-symbolic-link file" >&2
    return 2
  }
  permissions="$(stat -f '%Lp' "$enrollment_path")" || return 2
  [[ "$permissions" == "600" ]] || {
    echo "release enrollment must have mode 600 (found $permissions)" >&2
    return 2
  }

  ruby -rbase64 -rdigest -rjson -e '
    identifier_path, enrollment_path = ARGV
    expected_machine_id = Digest::SHA256.file(identifier_path).hexdigest
    enrollment = JSON.parse(File.read(enrollment_path))
    abort "release enrollment has an unsupported schema" unless enrollment["schemaVersion"] == 1
    abort "release enrollment has an unexpected service port" unless enrollment["port"] == 10_240
    abort "release enrollment belongs to a different virtual machine" unless enrollment["machineID"] == expected_machine_id
    token = Base64.strict_decode64(enrollment.fetch("token"))
    abort "release enrollment token has an invalid length" unless token.bytesize == 32
  ' "$vm_path/MachineIdentifier" "$enrollment_path" || return 2
}
