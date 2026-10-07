#!/bin/bash
# Container entrypoint: wires up the display, then hands off to the command.
#
# Two display backends are supported, chosen by QQ_DISPLAY_BACKEND:
#
#   x11      (default) X11 over TCP to XQuartz on the host.
#            Upstream bind-mounts /tmp/.X11-unix; macOS has no X11 socket
#            directory at all, so we speak the wire protocol over TCP instead.
#            Apple `container` puts the host on the vmnet gateway
#            (192.168.64.1 by default), reachable from inside the container.
#
#   wayland  Native Wayland via Cocoa-Way, transported by waypipe over a
#            Unix socket that Cocoa-Way publishes into this container.
#            No X server is involved, so there is no X11 keylogging surface.
#            Requires the host-side launcher (see wayland-launch.sh).
set -uo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

HOST_GATEWAY="${HOST_GATEWAY:-192.168.64.1}"
X11_PORT="${X11_PORT:-6000}"
BACKEND="${QQ_DISPLAY_BACKEND:-x11}"
# TCP 6000 -> display :0, 6001 -> :1, ...
# Strip the leading "6" and the trailing "0" (6000 -> "0", 6010 -> "1").
_port="${X11_PORT#6}"
DISPLAY_NUM="${_port%0}"
[ -n "${DISPLAY_NUM}" ] || DISPLAY_NUM=0

# ---------------------------------------------------------------------------
# 1. Display
# ---------------------------------------------------------------------------
if [ "${BACKEND}" = "wayland" ]; then
    # Cocoa-Way's relay owns the transport socket and starts us as its child.
    # waypipe creates the client socket a moment after we start, so the socket
    # is not necessarily present yet -- that is expected, not an error.
    wl_sock="${QQ_WAYLAND_SOCKET:-${WAYLAND_DISPLAY:-waypipe.sock}}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/wayland-runtime}"
    export WAYLAND_DISPLAY="$wl_sock"
    unset DISPLAY
    log "WAYLAND_DISPLAY=$wl_sock (Cocoa-Way)"

    # Native Wayland is the whole point: never let Electron fall back to X11.
    export ELECTRON_OZONE_PLATFORM_HINT=wayland
    export GDK_BACKEND=wayland
    export QT_QPA_PLATFORM=wayland
    # Text-input-v3 is what Cocoa-Way surfaces to the host IME.
    export QT_IM_MODULE=fcitx
    export XMODIFIERS=@im=fcitx
    # fcitx5's GTK3 immodule is linked into this image (fcitx5-frontend-gtk3),
    # so GTK_IM_MODULE=fcitx makes GTK load im-fcitx5.so during init. That
    # module fails when fcitx is not running, and the failure surfaces as the
    # opaque "Can't create a GtkStyleContext without a display connection",
    # which kills QQ a second or two after the first frame. Only point GTK at
    # fcitx when fcitx is actually going to be started.
    if [ "${QQ_ENABLE_IME:-0}" = "1" ]; then
        export GTK_IM_MODULE=fcitx
    else
        # NOT "${GTK_IM_MODULE:-...}": the image bakes GTK_IM_MODULE=fcitx, so
        # that default never fires and we would keep the broken value.
        export GTK_IM_MODULE=gtk-im-context-simple
        unset XMODIFIERS
    fi
else
    export DISPLAY=":${DISPLAY_NUM}"

    if [ -n "${QQ_X11_HOST:-}" ]; then
        export DISPLAY="${QQ_X11_HOST}:${DISPLAY_NUM}"
        log "DISPLAY=${DISPLAY} (explicit QQ_X11_HOST)"
        if ! timeout 5 bash -c "exec 3<>/dev/tcp/${QQ_X11_HOST}/${X11_PORT}" 2>/dev/null; then
            log "WARNING: cannot reach X server at ${QQ_X11_HOST}:${X11_PORT}"
            log "         -> is XQuartz running and listening on TCP? see README"
        fi
    else
        export DISPLAY="${HOST_GATEWAY}:${DISPLAY_NUM}"
        log "DISPLAY=${DISPLAY} (vmnet gateway)"
    fi

    # XQuartz ignores host-based xauth by default; the cookie is optional. If
    # the host passed one in we honour it, otherwise we let XQuartz's `xhost`
    # policy decide.
    if [ -f /home/user/.x11-auth/.x11-cookie ]; then
        mkdir -p "$(dirname "${XAUTHORITY}")"
        cookie=$(cat /home/user/.x11-auth/.x11-cookie)
        # Register the cookie under both the gateway address we connect to and
        # the container's own IP; X clients match on the display they were given.
        for host in "${HOST_GATEWAY}" "${DISPLAY%%:*}"; do
            xauth -f "${XAUTHORITY}" add "${host}:${DISPLAY_NUM}" \
                MIT-MAGIC-COOKIE-1 "$cookie" 2>/dev/null || true
        done
        chmod 600 "${XAUTHORITY}" 2>/dev/null || true
        log "installed X11 cookie for ${HOST_GATEWAY}:${DISPLAY_NUM}"
    fi
fi

# ---------------------------------------------------------------------------
# 2. D-Bus session bus
# ---------------------------------------------------------------------------
# A private session bus inside the container. Upstream forwarded the host's
# bus, which is both fragile and a real isolation hole: any process on the bus
# can talk to every other process on it. QQ does not need the host bus.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    mkdir -p /tmp/runtime-user && chmod 700 /tmp/runtime-user
    export XDG_RUNTIME_DIR=/tmp/runtime-user
    if command -v dbus-launch >/dev/null 2>&1; then
        eval "$(dbus-launch --sh-syntax)"
        log "started private session bus: ${DBUS_SESSION_BUS_ADDRESS}"
    else
        log "dbus-launch not found; QQ may log harmless dbus warnings"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Shared folder
# ---------------------------------------------------------------------------
mkdir -p /home/user/shared 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Rendering
# ---------------------------------------------------------------------------
# Apple `container` has no GPU passthrough, so Electron must use SwiftShader.
# Without this QQ frequently exits with a blank/aborted GL context. This
# applies to the Wayland path too: Cocoa-Way uploads CPU-rendered SHM buffers
# and presents them through Metal on the host.
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
# The guest VM has no /dev/dri node at all, so Mesa's loader would otherwise
# probe for a GPU that cannot exist. Pinning the loader to the software
# rasteriser skips that probe. Chromium still logs one "drmGetDevices2() has
# not found any devices" line, which is expected and harmless.
export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-swrast}"
export ELECTRON_DISABLE_SECURITY_WARNINGS="${ELECTRON_DISABLE_SECURITY_WARNINGS:-true}"

# ---------------------------------------------------------------------------
# 5. Optional fcitx5 IME
# ---------------------------------------------------------------------------
if [ "${QQ_ENABLE_IME:-0}" = "1" ] && command -v fcitx5 >/dev/null 2>&1; then
    fcitx5 -d --replace >/dev/null 2>&1 &
    sleep 1
    log "fcitx5 started (GTK_IM_MODULE=${GTK_IM_MODULE:-fcitx})"
fi

log "launching: $*"
exec "$@"
