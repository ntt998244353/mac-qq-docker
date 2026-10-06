#!/bin/bash
# Follow the Wayland session's logs.
set -uo pipefail
D=/tmp/cocoa-way-qq

if [ -n "${1:-}" ]; then
    tail -n "${1}" -f "$D/container.log"
else
    echo "=== waypipe client ==="; tail -n 20 "$D/waypipe-client.log" 2>/dev/null || echo "(none)"
    echo
    echo "=== container (follow) ==="; tail -n 50 -f "$D/container.log"
fi
