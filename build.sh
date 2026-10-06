#!/bin/bash
# build.sh -- build the QQ image for linux/amd64 (Rosetta).
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-mac-qq-docker:latest}"

[ -f .env ] && { set -a; . ./.env; set +a; : "${IMAGE:=mac-qq-docker:latest}"; }

if ! container system status >/dev/null 2>&1; then
    echo "starting container service..."
    container system start --enable-kernel-install </dev/null
fi

echo "building ${IMAGE} for linux/amd64 (Rosetta-translated)..."
echo "note: linuxqq ships x86_64 only, so this image is not native arm64."
echo

exec container build \
    --arch amd64 \
    --platform linux/amd64 \
    --build-arg "USER_ID=$(id -u)" \
    --build-arg "GROUP_ID=$(id -g)" \
    -t "${IMAGE}" \
    -f Dockerfile \
    .
