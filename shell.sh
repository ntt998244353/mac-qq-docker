#!/bin/bash
# shell.sh -- open a shell inside the running QQ container (for debugging).
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
exec container exec -it "${CONTAINER_NAME:-qq}" /bin/bash
