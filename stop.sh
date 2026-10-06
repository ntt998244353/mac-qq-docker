#!/bin/bash
# stop.sh -- stop and remove the QQ container.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
NAME="${CONTAINER_NAME:-qq}"
container stop "$NAME" 2>/dev/null || true
container delete "$NAME" 2>/dev/null || true
echo "stopped and removed '${NAME}'"
