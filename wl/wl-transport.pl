#!/usr/bin/perl
#
# Guest-side transport for Cocoa-Way waypipe sessions in Apple containers.
#
# Cocoa-Way publishes a host Unix socket into the container. Its host half is a
# frame multiplexer speaking the CWV2 protocol:
#
#     guest -> host : "CWV2\x01"                        (5-byte handshake)
#     guest -> host : frame(1, stream_id, "")           (stream opened)
#     host  -> guest : frame(2, stream_id, payload)     (data)
#     guest -> host : frame(2, stream_id, payload)      (data)
#     either         : frame(3, stream_id, "")          (stream closed)
#
# Header is 9 bytes, as Perl pack('CNN'): one byte of kind, then two big-endian
# uint32s (stream id, payload length). Only one stream is needed: waypipe
# already multiplexes its own channels over a single connection.
#
# QQ only needs one stream, so the multi-stream bookkeeping in Cocoa-Way's
# inline relay is unnecessary here - but the framing must match exactly.
#
# Usage: wl-transport.pl <transport_socket> <local_waypipe_socket> <command...>
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;
use File::Path qw(make_path);
use POSIX qw(WNOHANG);

my ($transport_path, $local_path, @command) = @ARGV;
die "usage: wl-transport.pl <transport_sock> <local_sock> <command...>\n"
    unless defined $transport_path && defined $local_path && @command;

sub prepare_path {
    my ($path) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
    unlink $path;
}

sub log_line {
    print STDERR "wl-transport: $_[0]\n";
}

# XDG_RUNTIME_DIR must exist before the client starts, or GTK/Wayland complains.
if (exists $ENV{XDG_RUNTIME_DIR} && length $ENV{XDG_RUNTIME_DIR} && !-d $ENV{XDG_RUNTIME_DIR}) {
    make_path($ENV{XDG_RUNTIME_DIR});
}

prepare_path($local_path);
prepare_path($transport_path);

# Both sockets are created by us as listeners; Apple's --publish-socket bridges
# the host end. Waypipe and the host frame multiplexer each dial in.
my $listener = IO::Socket::UNIX->new(
    Type   => SOCK_STREAM,
    Local  => $local_path,
    Listen => 8,
) or die "listen $local_path: $!\n";

my $transport_listener = IO::Socket::UNIX->new(
    Type   => SOCK_STREAM,
    Local  => $transport_path,
    Listen => 1,
) or die "listen $transport_path: $!\n";

# Tell the waiting host wrapper that the transport is up. autoflush must be
# set before the print or the wrapper blocks on a buffered line.
$| = 1;
print STDOUT "COCOA_WAY_TRANSPORT_V2_READY\n";
log_line("listening: $local_path (waypipe), $transport_path (host)");

my $transport = $transport_listener->accept()
    or die "accept $transport_path: $!\n";
$transport->autoflush(1);
binmode $transport;

# The host writes a one-way 5-byte preamble and never reads a reply; we only
# consume it. Sending anything back would be interpreted as a frame header.
my $hello = '';
while (length($hello) < 5) {
    my $chunk = '';
    my $got = sysread($transport, $chunk, 5 - length($hello));
    die "transport handshake ended early\n" unless defined $got && $got > 0;
    $hello .= $chunk;
}
die "unsupported transport handshake\n" unless $hello eq "CWV2\x01";
log_line('host channel connected');

my $child = fork();
die "fork: $!\n" unless defined $child;
if ($child == 0) {
    exec @command or die "exec @command: $!\n";
}
log_line("started @command (pid $child)");

my $local = $listener->accept() or die "accept $local_path: $!\n";
binmode $local;
log_line('client connected');

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

my $STREAM_ID = 1;
sub send_frame {
    my ($kind, $data) = @_;
    $data = '' unless defined $data;
    return write_all($transport, pack('CNN', $kind, $STREAM_ID, length($data)) . $data);
}

# Read exactly $n bytes, or return undef on EOF. sysread is not obliged to
# return a whole frame, and a short read here would desynchronise the stream.
my $incoming = '';
sub read_exact {
    my ($n) = @_;
    while (length($incoming) < $n) {
        my $chunk = '';
        my $got = sysread($transport, $chunk, 65536);
        return undef unless defined $got && $got > 0;
        $incoming .= $chunk;
    }
    return substr($incoming, 0, $n, '');
}

die "open stream: transport closed\n" unless send_frame(1, '');

# One blocking reader for host->guest; the child's own exit ends the loop via
# the non-blocking waitpid below (select would otherwise let us sit idle).
my $select = IO::Select->new($transport);
$select->add($local);

my $child_exited = 0;
RELAY: while (1) {
    if (waitpid($child, WNOHANG) == $child) {
        $child_exited = 1;
        last RELAY;
    }

    for my $fh ($select->can_read(0.25)) {
        if ($fh == $local) {
            my $data = '';
            my $n = sysread($local, $data, 65536);
            if (!defined $n || $n == 0) {
                last RELAY unless send_frame(3, '');
                last RELAY;
            }
            last RELAY unless send_frame(2, $data);
            next;
        }

        # transport -> local, reassembling whole frames across reads
        my $header = read_exact(9);
        last RELAY unless defined $header;
        my ($kind, $id, $length) = unpack('CNN', $header);
        last RELAY if $length > 16 * 1024 * 1024;
        if ($kind == 3) {
            last RELAY;
        }
        if ($length) {
            my $payload = $length ? read_exact($length) : '';
            last RELAY unless defined $payload;
            last RELAY unless write_all($local, $payload);
        }
    }
}

send_frame(3, '');
unless ($child_exited) {
    kill 'TERM', $child;
    waitpid($child, 0);
}
close $local;
close $transport;
close $transport_listener;
close $listener;
unlink $local_path;
unlink $transport_path;
exit 0;
