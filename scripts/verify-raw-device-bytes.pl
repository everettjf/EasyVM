#!/usr/bin/perl

use strict;
use warnings;

my ($source_path, $destination_path, $logical_size) = @ARGV;
defined $logical_size && $logical_size =~ /^\d+$/
    or die "usage: verify-raw-device-bytes.pl SOURCE_RAW DESTINATION_DEVICE LOGICAL_SIZE\n";
open my $source, '<', $source_path or die "open source for verification: $!\n";
open my $destination, '<', $destination_path or die "open ASIF for verification: $!\n";
binmode $source;
binmode $destination;

sub read_exact {
    my ($handle, $wanted, $label, $offset) = @_;
    my $buffer = '';
    while (length($buffer) < $wanted) {
        my $read = sysread($handle, my $chunk, $wanted - length($buffer));
        defined($read) && $read > 0
            or die "short read from $label at offset $offset\n";
        $buffer .= $chunk;
    }
    return $buffer;
}

my $offset = 0;
while ($offset < $logical_size) {
    my $wanted = $logical_size - $offset;
    $wanted = 4 * 1024 * 1024 if $wanted > 4 * 1024 * 1024;
    my $source_buffer = read_exact($source, $wanted, 'source', $offset);
    my $destination_buffer = read_exact($destination, $wanted, 'ASIF', $offset);
    $source_buffer eq $destination_buffer
        or die "ASIF differs from source at or after offset $offset\n";
    $offset += $wanted;
}

close $destination or die "close ASIF after verification: $!\n";
close $source or die "close source after verification: $!\n";
