#!/bin/bash
# logs.sh -- follow QQ's stdout/stderr.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
exec container logs --follow "${CONTAINER_NAME:-qq}"
