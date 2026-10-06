#!/bin/bash
# Launch Linux QQ with flags appropriate for an Apple `container` VM.
set -uo pipefail

log() { printf '[qq] %s\n' "$*" >&2; }

QQ_BIN=/opt/QQ/qq
[ -x "$QQ_BIN" ] || { log "FATAL: $QQ_BIN missing"; exit 1; }

ARGS=()

# --- Electron sandbox ------------------------------------------------------
# Upstream uses --no-sandbox. Inside a hardened Apple `container` VM the app
# is already inside a lightweight-VM boundary, and the container's seccomp
# profile blocks the namespace syscalls Chromium's layer-1 sandbox wants, so
# --no-sandbox is the reliable choice here. Set QQ_KEEP_SANDBOX=1 to try the
# setuid chrome-sandbox helper instead.
if [ "${QQ_KEEP_SANDBOX:-0}" != "1" ]; then
    ARGS+=(--no-sandbox)
else
    log "keeping Chromium sandbox enabled (QQ_KEEP_SANDBOX=1)"
fi

# --- GPU / buffer path -----------------------------------------------------
# No GPU exists inside the VM, so rendering has to be software either way.
# But *which* software path matters a great deal on Wayland, and getting it
# wrong is what made Wayland mode look completely broken for a long time.
#
# What happens with each choice (Chromium 144, the version QQ bundles):
#
#   --disable-gpu [--in-process-gpu]
#       GpuDataManager goes to GpuMode::SOFTWARE_GL, but the GL implementation
#       ends up effectively disabled. The renderer comes up, the Wayland
#       connection is established and the xdg_toplevel is created, yet no frame
#       is ever committed: the compositor keeps an empty window and the log
#       never grows past "opened stream 1/2". This is what the X11 path uses,
#       and it is fine there (X11 has no dmabuf requirement at all).
#
#   (no GL switch at all)  <-- Wayland wants this
#       Chromium picks its own software fallback and
#       ui/ozone/platform/wayland/gpu/wayland_surface_factory.cc selects the
#       GLSurfaceEglReadbackWayland branch (render on the CPU, then present via
#       wl_shm). That branch is what makes a window actually appear without a
#       DRM render node. Verified working: QQ renders, accepts input, and can
#       be logged into.
#
#   --use-angle=swiftshader
#       Also satisfies the same branch, but is slower and needs
#       --enable-unsafe-swiftshader to avoid a warning. Not used; kept only as
#       a documented alternative.
#
# So: only disable the GPU when we are NOT on Wayland. QQ_FORCE_SOFTWARE=1
# forces the old behaviour on Wayland for comparison/debugging.
if [ "${QQ_DISPLAY_BACKEND:-x11}" != "wayland" ] || [ "${QQ_FORCE_SOFTWARE:-0}" = "1" ]; then
    ARGS+=(--disable-gpu --disable-gpu-compositing)
    # NB: do NOT also pass --disable-software-rasterizer -- without it Chromium
    # falls back to its own SwiftShader software path instead of failing outright.
    ARGS+=(--in-process-gpu)
else
    # Deliberately no GL switch: let Chromium choose, so it takes the wl_shm
    # readback path. See the explanation above before "improving" this.
    log "wayland: leaving GL implementation to Chromium (wl_shm readback path)"
fi

# --- display backend -------------------------------------------------------
# The X11 path talks to XQuartz over TCP and needs nothing extra. The Wayland
# path must be explicit: Electron's ozone-platform-hint has repeatedly
# regressed across QQ releases, silently dropping clients back to XWayland,
# which would reintroduce exactly the X11 keylogging surface we are avoiding.
if [ "${QQ_DISPLAY_BACKEND:-x11}" = "wayland" ]; then
    # Cocoa-Way's single-app profile execs this wrapper directly, bypassing the
    # image entrypoint. That leaves the image's baked-in X11 variables in place,
    # and a leftover DISPLAY makes Chromium prefer X11 even when every Wayland
    # hint is set -- which is exactly the fallback we are trying to avoid.
    unset DISPLAY
    export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"
    export GDK_BACKEND="${GDK_BACKEND:-wayland}"
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"

    # Same bypass means the entrypoint's private D-Bus session never starts
    # either, leaving DBUS_SESSION_BUS_ADDRESS unset. Chromium then falls back
    # to the *system* bus, which does not exist in this image, and logs
    # "Failed to connect to the bus: /run/dbus/system_bus_socket". Qt uses the
    # session bus for its platform theme, so start one here to match the X11
    # path's environment.
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-user}"
        mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
        if eval "$(dbus-launch --sh-syntax 2>/dev/null)"; then
            log "started private session bus: ${DBUS_SESSION_BUS_ADDRESS}"
        else
            log "dbus-launch failed; continuing without a session bus"
        fi
    fi

    ARGS+=(--ozone-platform=wayland)
    # Text input via the Wayland protocol, so the host IME reaches QQ directly
    # instead of going through Xwayland's XIM bridge.
    [ "${QQ_ENABLE_IME:-0}" = "1" ] && ARGS+=(--enable-wayland-ime --wayland-text-input-version=3)
fi

# --- misc ------------------------------------------------------------------
# /dev/shm is a 64 MiB tmpfs by default, which is too small for Chromium's
# shared-memory buffers, so upstream always passes --disable-dev-shm-usage and
# gets disk-backed /tmp instead. We raise it with --shm-size (see runtime_args)
# and keep the flag anyway: it is what the known-good Wayland session ran with,
# so it stays until something proves it is worth changing.
ARGS+=(--no-first-run --disable-features=DialMediaRouteProvider)

# --- user extras -----------------------------------------------------------
# shellcheck disable=SC2206
[ -n "${QQ_EXTRA_ARGS:-}" ] && ARGS+=(${QQ_EXTRA_ARGS})

log "exec $QQ_BIN ${ARGS[*]} $*"
exec "$QQ_BIN" "${ARGS[@]}" "$@"
