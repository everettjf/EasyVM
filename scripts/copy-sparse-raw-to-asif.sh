#!/bin/bash

set -euo pipefail

source_disk=${1:-}
destination=${2:-}
project_root="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf 'copy-sparse-raw-to-asif: %s\n' "$*" >&2; exit 1; }

[[ -f $source_disk && ! -L $source_disk ]] || fail "source raw disk is missing or unsafe"
[[ -n $destination && ! -e $destination ]] || fail "destination must not already exist"
[[ ${destination##*.} == asif ]] || fail "destination must end in .asif"

source_size=$(stat -f %z "$source_disk")
[[ $source_size =~ ^[0-9]+$ && $source_size -gt 0 ]] || fail "source disk has an invalid size"

attach_plist=$(mktemp "${TMPDIR:-/tmp}/ezvm-asif-attach.XXXXXX")
attached_device=
completed=0
cleanup() {
  if [[ -n $attached_device ]]; then
    /usr/sbin/diskutil eject "$attached_device" >/dev/null 2>&1 || true
  fi
  rm -f "$attach_plist"
  if ((completed == 0)); then rm -f "$destination"; fi
}
trap cleanup EXIT

/usr/sbin/diskutil image create blank \
  --format ASIF \
  --size "$source_size" \
  --fs None \
  "$destination"

attach() {
  local mode=${1:-writable}
  local options=(image attach --plist --noMount)
  if [[ $mode == readonly ]]; then options+=(--readOnly); fi
  /usr/sbin/diskutil "${options[@]}" "$destination" >"$attach_plist"
  attached_device=$(plutil -extract system-entities.0.dev-entry raw "$attach_plist")
  [[ $attached_device =~ ^disk[0-9]+$ ]] || fail "could not identify the attached ASIF device"
  local attached_size
  attached_size=$(plutil -extract system-entities.0.size raw "$attach_plist")
  [[ $attached_size == "$source_size" ]] || fail "attached ASIF size does not match the raw disk"
}

detach() {
  [[ -n $attached_device ]] || return 0
  /usr/sbin/diskutil eject "$attached_device" >/dev/null
  attached_device=
}

attach writable
raw_device="/dev/r$attached_device"

# APFS exposes allocated ranges through SEEK_DATA/SEEK_HOLE. Writing only those
# ranges preserves holes in the destination ASIF instead of materializing a
# logical 64 GiB disk. The destination is a newly created blank device, so all
# skipped ranges already read as zero.
perl - "$source_disk" "$raw_device" "$source_size" <<'PERL'
use strict;
use warnings;
use Errno qw(ENXIO);
use Fcntl qw(SEEK_SET);

my ($source_path, $destination_path, $logical_size) = @ARGV;
open my $source, '<', $source_path or die "open source: $!\n";
open my $destination, '+<', $destination_path or die "open destination: $!\n";
binmode $source;
binmode $destination;

my $SEEK_DATA = 4;
my $SEEK_HOLE = 3;
my $offset = 0;
while ($offset < $logical_size) {
    my $data = sysseek($source, $offset, $SEEK_DATA);
    if (!defined $data) {
        last if $! == ENXIO;
        die "find sparse extent start: $!\n";
    }
    my $hole = sysseek($source, $data, $SEEK_HOLE);
    defined $hole or die "find sparse extent end: $!\n";
    $hole = $logical_size if $hole > $logical_size;
    sysseek($source, $data, SEEK_SET) == $data or die "seek source: $!\n";
    sysseek($destination, $data, SEEK_SET) == $data or die "seek destination: $!\n";
    my $remaining = $hole - $data;
    while ($remaining > 0) {
        my $wanted = $remaining > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : $remaining;
        my $read = sysread($source, my $buffer, $wanted);
        defined($read) && $read > 0 or die "read source extent: $!\n";
        my $written = 0;
        while ($written < $read) {
            my $count = syswrite($destination, $buffer, $read - $written, $written);
            defined($count) && $count > 0 or die "write ASIF extent: $!\n";
            $written += $count;
        }
        $remaining -= $read;
    }
    $offset = $hole;
}

close $destination or die "close destination: $!\n";
close $source or die "close source: $!\n";
PERL

detach
attach readonly
raw_device="/dev/r$attached_device"
"$project_root/scripts/verify-raw-device-bytes.pl" "$source_disk" "$raw_device" "$source_size"
detach

completed=1
printf 'Created and byte-verified sparse ASIF: %s\n' "$destination"
