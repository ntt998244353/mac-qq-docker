#!/bin/bash
# Stop the Wayland session started by ./wayland-launch.sh
#
# Since the launcher hands the session to Cocoa-Way, Cocoa-Way owns the
# container and the waypipe pair -- so the session must be stopped through
# cocoa-wayctl. Killing the container by hand would leave Cocoa-Way believing
# the session is still running.
set -uo pipefail

# Matches the default Cocoa-Way derives; override with QQ_SESSION_NAME or
# CONTAINER_NAME the same way wayland-launch.sh does.
NAME="${QQ_SESSION_NAME:-${CONTAINER_NAME:-qq-wayland}}"

stopped=0
if command -v cocoa-wayctl >/dev/null 2>&1; then
    if cocoa-wayctl --json applications 2>/dev/null | grep -q "\"name\":\"$NAME\""; then
        cocoa-wayctl --json stop "$NAME" >/dev/null 2>&1 && stopped=1
    fi
fi

# Belt and braces: if Cocoa-Way is gone, or never tracked it, clean up the
# container it would have named this way.
container stop "cocoa-way-$NAME" >/dev/null 2>&1 || true
sleep 1
container delete "cocoa-way-$NAME" >/dev/null 2>&1 || true

# Leftovers from the days when this script built its own transport.
pkill -f "waypipe --socket /tmp/cocoa-way-qq" 2>/dev/null || true
rm -f /tmp/cocoa-way-qq/transport.sock /tmp/cocoa-way-qq/waypipe.sock 2>/dev/null || true

if [ "$stopped" = "1" ]; then
    echo "stopped session $NAME"
else
    echo "no Cocoa-Way session named $NAME; cleaned up any container named cocoa-way-$NAME"
fi
