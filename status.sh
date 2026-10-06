#!/bin/bash
# status.sh -- show container state, resource use, and X11 reachability.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
NAME="${CONTAINER_NAME:-qq}"

echo "=== container service ==="
container system status 2>&1 | grep -E 'status|host.arch|containers' || true

echo
echo "=== containers ==="
container list -a 2>&1 || true

echo
echo "=== X11 on host ==="
if nc -z 127.0.0.1 "${X11_PORT:-6000}" 2>/dev/null; then
    echo "127.0.0.1:${X11_PORT:-6000} is listening (XQuartz up)"
else
    echo "127.0.0.1:${X11_PORT:-6000} NOT listening -- run ./x11-setup.sh"
fi

echo
echo "=== QQ processes inside container ==="
container exec "$NAME" /bin/bash -c \
  "ps -eo pid,comm,args --sort=-%mem | grep -E 'qq|fcitx' | grep -v grep | head -15" \
  2>/dev/null || echo "(container not running)"
