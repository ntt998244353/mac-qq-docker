#!/bin/bash
# view.sh -- attach Qt/Electron debug output for troubleshooting.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
exec container exec -it "${CONTAINER_NAME:-qq}" /home/user/qq-wrapper.sh
