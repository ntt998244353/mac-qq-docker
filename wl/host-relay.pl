#!/usr/bin/env perl
#
# Host-side half of the Cocoa-Way transport for an Apple container session.
#
# The guest relay listens on a socket we publish into the container and waits.
# We dial it, send the one-way preamble, and then multiplex frames between the
# guest's waypipe stream and the local waypipe client (which is already
# connected to the Cocoa-Way compositor).
#
# Protocol (see wl/wl-transport.pl for the guest half):
#
#     host  -> guest : "CWV2\x01"                        (preamble)
#     guest -> host : frame(1, stream_id, "")            (stream opened)
#     host  -> guest : frame(2, stream_id, payload)      (data)
#     guest -> host : frame(2, stream_id, payload)       (data)
#     either         : frame(3, stream_id, "")           (stream closed)
#
# Header: Perl pack('CNN') -> 1 byte kind, then two big-endian uint32s.
#
# Usage: host-relay.pl <published_transport_sock> <local_waypipe_sock>
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;
use POSIX qw(WNOHANG);

my ($transport_path, $local_path) = @ARGV;
die "usage: host-relay.pl <transport_sock> <local_waypipe_sock>\n"
    unless defined $transport_path && defined $local_path;

sub log_line { print STDERR "host-relay: $_[0]\n"; }

# The container creates the published socket; wait for it to appear.
my $transport;
for my $attempt (1 .. 300) {
    $transport = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $transport_path);
    last if $transport;
    select undef, undef, undef, 0.1;
}
die "cannot connect to $transport_path: $!\n" unless $transport;
binmode $transport;
$transport->autoflush(1);
log_line("connected to guest transport");

# One-way preamble; the guest reads exactly these 5 bytes and never replies.
print {$transport} "CWV2\x01" or die "preamble: $!\n";

# The waypipe client socket is created by `waypipe client` before we start.
my $local;
for my $attempt (1 .. 300) {
    $local = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $local_path);
    last if $local;
    select undef, undef, undef, 0.1;
}
die "cannot connect to $local_path: $!\n" unless $local;
binmode $local;
log_line("connected to waypipe client");

sub write_all {
    my ($fh, $data) = @_;
    my $offset = 0;
    while ($offset < length $data) {
        my $written = syswrite($fh, $data, length($data) - $offset, $offset);
        return 0 unless defined $written && $written > 0;
        $offset += $written;
    }
    return 1;
}

# Per-socket read buffers. A single shared buffer would interleave leftovers
# from one socket into the other's frame stream.
my %buf;
sub read_exact {
    my ($fh, $n) = @_;
    my $key = fileno($fh);
    $buf{$key} = '' unless defined $buf{$key};
    while (length($buf{$key}) < $n) {
        my $chunk = '';
        my $got = sysread($fh, $chunk, 65536);
        return undef unless defined $got && $got > 0;
        $buf{$key} .= $chunk;
    }
    return substr($buf{$key}, 0, $n, '');
}

# Wait for the guest's OPEN frame so we know the stream id it chose.
my $header = read_exact($transport, 9);
die "no OPEN frame from guest\n" unless defined $header;
my ($kind, $stream_id, $length) = unpack('CNN', $header);
die "unexpected first frame kind=$kind\n" unless $kind == 1;
log_line("stream $stream_id open");

my $select = IO::Select->new($transport);
$select->add($local);
my $running = 1;

while ($running) {
    for my $fh ($select->can_read(1)) {
        if ($fh == $local) {
            my $data = '';
            my $n = sysread($local, $data, 65536);
            if (!defined $n || $n == 0) {
                write_all($transport, pack('CNN', 3, $stream_id, 0));
                $running = 0;
                last;
            }
            unless (write_all($transport, pack('CNN', 2, $stream_id, length $data) . $data)) {
                $running = 0;
                last;
            }
            next;
        }

        # guest -> waypipe client
        my $head = read_exact($transport, 9);
        unless (defined $head) { $running = 0; last; }
        my ($k, $id, $len) = unpack('CNN', $head);
        if ($k == 3) { $running = 0; last; }
        next unless $k == 2 && $len;
        my $payload = read_exact($transport, $len);
        unless (defined $payload && write_all($local, $payload)) {
            $running = 0;
            last;
        }
    }
}

log_line("closing");
close $local;
close $transport;
exit 0;
