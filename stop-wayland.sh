#!/bin/bash
# Stop the Wayland session started by ./wayland-launch.sh
set -uo pipefail
NAME="${CONTAINER_NAME:-qq-wayland}"

container stop "$NAME" >/dev/null 2>&1 || true
sleep 1
container delete "$NAME" >/dev/null 2>&1 || true

# The waypipe client is a child of the launcher; kill any that outlived it.
pkill -f "waypipe --socket /tmp/cocoa-way-qq" 2>/dev/null || true
rm -f /tmp/cocoa-way-qq/transport.sock /tmp/cocoa-way-qq/waypipe.sock 2>/dev/null || true

echo "stopped $NAME"
