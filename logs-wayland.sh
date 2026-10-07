#!/bin/bash
# Show the Wayland session's logs.
#
# Cocoa-Way owns the session now, so its logs are the interesting ones; they
# are served by `cocoa-wayctl logs` rather than by a file under /tmp. The old
# container.log is still printed when present, because it holds the guest-side
# output from runs made before the session was delegated.
set -uo pipefail

NAME="${QQ_SESSION_NAME:-${CONTAINER_NAME:-qq-wayland}}"
LEGACY_LOG=/tmp/cocoa-way-qq/container.log

usage() {
    cat <<'EOF'
usage: logs-wayland.sh [-f] [-n LINES] [SESSION]

  -n LINES   how many lines of each log to show (default 50)
  -f         follow the legacy container log (Cocoa-Way logs cannot be followed)

  SESSION    Cocoa-Way session name (default: qq-wayland)
EOF
}

lines=50
follow=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n) lines="$2"; shift 2 ;;
        -f) follow=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *) NAME="$1"; shift ;;
    esac
done

if command -v cocoa-wayctl >/dev/null 2>&1; then
    echo "=== cocoa-way session '$NAME' (via cocoa-wayctl logs) ==="
    cocoa-wayctl logs "$NAME" 2>/dev/null | tail -n "$lines" \
        || echo "(no Cocoa-Way session named $NAME)"
    echo
else
    echo "cocoa-wayctl not found; skipping Cocoa-Way logs" >&2
fi

if [ -f "$LEGACY_LOG" ]; then
    echo "=== guest container log (legacy path, $LEGACY_LOG) ==="
    if [ "$follow" = "1" ]; then
        tail -n "$lines" -f "$LEGACY_LOG"
    else
        tail -n "$lines" "$LEGACY_LOG"
    fi
fi
