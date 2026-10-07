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
#   (no GL switch at all)  <-- tried on Wayland; rejected, see below
#       Chromium picks its own software fallback and
#       ui/ozone/platform/wayland/gpu/wayland_surface_factory.cc selects the
#       GLSurfaceEglReadbackWayland branch (render on the CPU, then present via
#       wl_shm). When it works, that branch makes a window appear without a DRM
#       render node, and QQ renders and accepts input.
#
#       It is however NOT reliable: Chromium still probes for a DRM node, logs
#       "drmGetDevices2() has not found any devices" and can fail its GPU
#       context outright ("ContextResult::kFatalFailure: WebGL1 blocklisted").
#       When that happens the GPU process dies, which drops the Wayland
#       connection and makes waypipe abort the session
#       ("wl_display#1: error 3: waypipe internal error"), after which GTK
#       reports the misleading "Can't create a GtkStyleContext without a
#       display connection". Because the failure is a race, this path can look
#       like it works for a while and then fail on a later launch.
#
#       Wayland mode therefore no longer relies on it; see the else-branch below.
#
#   --use-angle=swiftshader
#       Also satisfies the same branch, but is slower and needs
#       --enable-unsafe-swiftshader to avoid a warning. Not used; kept only as
#       a documented alternative.
#
# So: keep the GPU disabled on every backend. QQ_FORCE_SOFTWARE=1 is kept as an
# explicit escape hatch; on Wayland it is now redundant (that is already the
# default) and it remains the way to force software GL on X11.
# The default for X11, and also the fallback for Wayland (see the branch
# below, which overrides this). On X11 there is no dmabuf requirement, so a
# disabled GPU is harmless and these are the right flags.
#
# On Wayland they are NOT: as the notes above say, --disable-gpu leaves the
# renderer unable to commit a frame at all -- the compositor holds an empty
# window and waypipe never grows past "opened stream 1/2". The Wayland branch
# below therefore replaces them.
ARGS+=(--disable-gpu --disable-gpu-compositing)
# NB: do NOT also pass --disable-software-rasterizer -- without it Chromium
# falls back to its own SwiftShader software path instead of failing outright.
ARGS+=(--in-process-gpu)
# Make sure Chromium never depends on the tiny /dev/shm. The launcher raises it
# with --shm-size; keep the disk-backed fallback as a belt-and-braces guarantee.
ARGS+=(--disable-dev-shm-usage)

if [ "${QQ_DISPLAY_BACKEND:-x11}" = "wayland" ]; then
    # Wayland must NOT reuse the X11 flag set above. --disable-gpu drops
    # Chromium into GpuMode::SOFTWARE_GL with the GL implementation effectively
    # disabled, and the renderer then never commits anything: the compositor
    # keeps an empty 800x632 window, `commits_per_second` stays 0.0 and no
    # renderer process is ever forked. That is the "window exists but is blank"
    # symptom, and it is why the notes above say Wayland must not rely on
    # --disable-gpu -- even though the unconditional lines above did exactly
    # that.
    #
    # What does work is letting Chromium take its own software fallback path.
    # Without a GL switch, wayland_surface_factory.cc picks the
    # GLSurfaceEglReadbackWayland branch: it renders on the CPU and presents
    # through wl_shm, which needs no DRM render node and no dmabuf -- exactly
    # right for a guest with no /dev/dri.
    #
    # Strip the X11 GPU flags and leave the choice to Chromium.
    _kept=()
    for _a in "${ARGS[@]}"; do
        case "$_a" in
            --disable-gpu|--disable-gpu-compositing|--in-process-gpu) ;;
            *) _kept+=("$_a") ;;
        esac
    done
    ARGS=("${_kept[@]}")
    log "wayland: leaving GL to Chromium's wl_shm software path (no /dev/dri in guest)"
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

    # The image bakes GTK_IM_MODULE=fcitx because the X11 path starts fcitx5.
    # In Wayland mode fcitx is usually NOT running, and the fcitx GTK3 immodule
    # is nonetheless loaded during GTK init, where it fails and takes the whole
    # process down with the misleading message
    #   "Gtk-ERROR: Can't create a GtkStyleContext without a display connection"
    # about a second after the first frame is presented -- the window shows,
    # then vanishes. Only keep the fcitx bindings when we are actually running
    # fcitx (--ime).
    if [ "${QQ_ENABLE_IME:-0}" != "1" ]; then
        export GTK_IM_MODULE=gtk-im-context-simple
        unset QT_IM_MODULE XMODIFIERS
    fi

    # Same bypass means the entrypoint's private D-Bus session never starts
    # either, leaving DBUS_SESSION_BUS_ADDRESS unset. Chromium then falls back
    # to the *system* bus, which does not exist in this image, and logs
    # "Failed to connect to the bus: /run/dbus/system_bus_socket". Qt uses the
    # session bus for its platform theme, so start one here to match the X11
    # path's environment.
    # XDG_RUNTIME_DIR and WAYLAND_DISPLAY must both be set and must agree:
    # XDG_RUNTIME_DIR is the directory WAYLAND_DISPLAY is resolved against.
    #
    # This is not merely a matter of picking the right directory, because
    # Cocoa-Way makes the choice for us and will not be overridden. In
    # container_sessions.rs it does
    #
    #     .arg("--env")
    #     .arg(format!("XDG_RUNTIME_DIR={}", default_guest_runtime_dir()))
    #     for env in environment {
    #         if !env.starts_with("XDG_RUNTIME_DIR=") {   // <- filtered out
    #             cmd.arg("--env").arg(env);
    #         }
    #     }
    #
    # so every XDG_RUNTIME_DIR we put in the session's env[] is discarded and
    # the guest always gets the hardcoded /tmp/cocoa-way-runtime -- a directory
    # Cocoa-Way never creates, because the session socket actually lands in
    # /tmp/runtime-user.
    #
    # Meanwhile Chromium's zygote re-creates child environments from the init
    # process, so the renderer inherited the bare XDG_RUNTIME_DIR with no
    # WAYLAND_DISPLAY at all:
    #
    #   browser  : XDG_RUNTIME_DIR=/tmp/runtime-user, WAYLAND_DISPLAY=wayland-XXX  OK
    #   renderer : XDG_RUNTIME_DIR=/tmp/cocoa-way-runtime, WAYLAND_DISPLAY unset   broken
    #
    # A renderer that cannot name the socket never opens the display and never
    # commits a frame, so QQ shows an empty window while every process looks
    # healthy -- which is exactly the "window exists but is blank" symptom.
    #
    # So do not fight the environment; satisfy it. Create the directory
    # Cocoa-Way insists on and make the real socket reachable inside it under
    # the conventional name, then export the pair. Children that inherit
    # either spelling will find a working socket.
    export XDG_RUNTIME_DIR=/tmp/runtime-user
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    compat_runtime_dir=/tmp/cocoa-way-runtime
    mkdir -p "$compat_runtime_dir" && chmod 700 "$compat_runtime_dir" 2>/dev/null || true

    # Cocoa-Way's relay creates the real socket a moment after we start, so
    # wait for it rather than assuming its name.
    real_sock=""
    for _ in $(seq 1 100); do
        real_sock="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' -type s 2>/dev/null | head -1)"
        [ -n "$real_sock" ] && break
        sleep 0.1
    done
    if [ -n "$real_sock" ]; then
        export WAYLAND_DISPLAY="$(basename "$real_sock")"
        # Reachable under the names a child may assume. A renderer that
        # inherits no WAYLAND_DISPLAY calls wl_display_connect(NULL), and
        # libwayland then tries "wayland-0" -- so that alias matters more than
        # wayland-1 here.
        ln -sfn "$real_sock" "$compat_runtime_dir/wayland-0" 2>/dev/null || true
        ln -sfn "$real_sock" "$compat_runtime_dir/wayland-1" 2>/dev/null || true
        ln -sfn "$real_sock" "$XDG_RUNTIME_DIR/wayland-0" 2>/dev/null || true
        log "wayland: display=$WAYLAND_DISPLAY ($real_sock)"
    else
        log "wayland: warning: no compositor socket appeared in $XDG_RUNTIME_DIR"
    fi

    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then
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
