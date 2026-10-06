#!/bin/bash
# run.sh -- start Linux QQ in a hardened Apple `container` VM.
#
# This is the docker-compose.yml equivalent. Everything upstream mounted from
# the host is either unnecessary on macOS (X11 sockets, dbus, pulse sockets)
# or actively harmful to isolation, so what remains is deliberately small:
#
#   QQ/     -> /home/user/.config/QQ   chat history / login state
#   shared/ -> /home/user/shared       file sharing
#
# Both are plain bind mounts of directories inside this project folder.
set -euo pipefail

cd "$(dirname "$0")"

# ---- backend dispatch -----------------------------------------------------
# Wayland is the safer backend: an X11 client can read every other client's
# input, while a Wayland client is confined to its own surfaces. It is opt-in
# because it needs a running Cocoa-Way compositor on the host.
if [ "${QQ_MODE:-x11}" = "wayland" ]; then
    exec "$(dirname "$0")/wayland-launch.sh" "$@"
fi

# ---- config ---------------------------------------------------------------
[ -f .env ] || { echo "no .env -- run ./init.sh first" >&2; exit 1; }
set -a; . ./.env; set +a
: "${IMAGE:=mac-qq-docker:latest}"
: "${CONTAINER_NAME:=qq}"
: "${HOST_GATEWAY:=192.168.64.1}"
: "${X11_PORT:=6000}"
: "${USER_ID:=$(id -u)}"
: "${GROUP_ID:=$(id -g)}"
: "${QQ_ENABLE_IME:=0}"

mkdir -p QQ shared

# ---- preflight: container service ----------------------------------------
if ! container system status >/dev/null 2>&1; then
    echo "container service not running; starting it..."
    container system start --enable-kernel-install </dev/null
fi

if ! container image list 2>/dev/null | grep -q "${IMAGE%%:*}"; then
    echo "image ${IMAGE} not found. Build it with:"
    echo "  ./build.sh"
    exit 1
fi

# ---- preflight: X server --------------------------------------------------
if ! nc -z 127.0.0.1 "${X11_PORT}" 2>/dev/null; then
    echo "ERROR: no X server listening on 127.0.0.1:${X11_PORT}." >&2
    echo "       Run:  ./x11-setup.sh" >&2
    exit 1
fi

# ---- preflight: X11 cookie ------------------------------------------------
# x11-setup.sh writes .x11-cookie; the entrypoint installs it inside the
# container so XQuartz will accept the connection without resorting to the
# world-readable `xhost +`.
X11_AUTH_DIR="$(pwd)/.x11-auth"
mkdir -p "$X11_AUTH_DIR"
if [ -f .x11-cookie ]; then
    cp .x11-cookie "$X11_AUTH_DIR/.x11-cookie"
else
    echo "WARNING: .x11-cookie not found; run ./x11-setup.sh for authenticated X11." >&2
    echo "         Without it XQuartz will reject the connection." >&2
fi

# ---- restart policy -------------------------------------------------------
if container list -a 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
    echo "removing previous container '${CONTAINER_NAME}'..."
    container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container delete "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# ---- resource limits ------------------------------------------------------
# Upstream sets shm_size: 2gb because Chromium uses /dev/shm heavily. We pass
# the same idea through --shm-size and additionally cap memory/CPU, which
# upstream could not do.
CPUS="${QQ_CPUS:-4}"
MEMORY="${QQ_MEMORY:-4g}"

echo "starting QQ container..."
echo "  image      : ${IMAGE}"
echo "  display    : ${HOST_GATEWAY}:${X11_PORT}"
echo "  QQ dir     : $(pwd)/QQ"
echo "  shared dir : $(pwd)/shared"
echo

container run \
    --name "${CONTAINER_NAME}" \
    --arch amd64 \
    --platform linux/amd64 \
    --rosetta \
    --detach \
    --cpus "${CPUS}" \
    --memory "${MEMORY}" \
    --shm-size 2g \
    --uid "${USER_ID}" \
    --gid "${GROUP_ID}" \
    --env HOST_GATEWAY="${HOST_GATEWAY}" \
    --env X11_PORT="${X11_PORT}" \
    --env QQ_X11_HOST="${HOST_GATEWAY}" \
    --env QQ_ENABLE_IME="${QQ_ENABLE_IME}" \
    --env QQ_EXTRA_ARGS="${QQ_EXTRA_ARGS:-}" \
    --env TZ="${TZ:-Asia/Shanghai}" \
    --env LANG=zh_CN.UTF-8 \
    --env GTK_IM_MODULE=fcitx \
    --env XMODIFIERS=@im=fcitx \
    --mount "type=bind,source=$(pwd)/QQ,target=/home/user/.config/QQ" \
    --mount "type=bind,source=$(pwd)/shared,target=/home/user/shared" \
    --mount "type=bind,source=${X11_AUTH_DIR},target=/home/user/.x11-auth,readonly" \
    --cap-drop ALL \
    --cap-add CHOWN \
    --cap-add DAC_OVERRIDE \
    --cap-add FOWNER \
    --cap-add SETUID \
    --cap-add SETGID \
    --cap-add KILL \
    "${IMAGE}"

echo
echo "QQ started. Logs:  ./logs.sh"
echo "Stop:              ./stop.sh"
