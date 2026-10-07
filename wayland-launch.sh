#!/bin/bash
# Launch QQ as a native Wayland client through Cocoa-Way.
#
# Why this exists alongside run.sh:
#
#   X11 (run.sh) reaches XQuartz over TCP. The X11 protocol gives every client
#   unrestricted access to the whole input stream -- any X client can read all
#   keystrokes, including ones typed into other windows. That risk is inherent
#   to X11 and cannot be turned off by our own code.
#
#   Wayland has no such primitive. A client only receives events for surfaces
#   it owns, and the compositor mediates everything else. Running QQ this way
#   removes that attack surface rather than merely narrowing permissions.
#
# The transport is Cocoa-Way's: it publishes a host Unix socket into the
# container, and a guest-side relay multiplexes a waypipe connection over it.
# waypipe forwards the Wayland protocol, so QQ remains a genuine Wayland client
# (ELECTRON_OZONE_PLATFORM_HINT=wayland, no XWayland anywhere).
set -euo pipefail

cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# options (all optional; qq.sh passes these through)
# ---------------------------------------------------------------------------
# Defaults preserve the original behaviour when the script is run directly.
CONTAINER_NAME="${CONTAINER_NAME:-qq-wayland}"
IMAGE="${IMAGE:-mac-qq-docker:latest}"
ARCH="${QQ_ARCH:-amd64}"
ROSETTA="${QQ_ROSETTA:-1}"
CPUS="${QQ_CPUS:-4}"
MEMORY="${QQ_MEMORY:-3G}"
# Chromium's renderer needs far more than the 64M /dev/shm default; see the
# comment at the `container run` invocation below.
SHM_SIZE="${QQ_SHM_SIZE:-1G}"
IME="${QQ_ENABLE_IME:-0}"
EXTRA_ARGS="${QQ_EXTRA_ARGS:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --name)       CONTAINER_NAME="$2"; shift 2 ;;
        --image)      IMAGE="$2";          shift 2 ;;
        --arch)       ARCH="$2";           shift 2 ;;
        --cpus)       CPUS="$2";           shift 2 ;;
        --memory)     MEMORY="$2";         shift 2 ;;
        --shm-size)   SHM_SIZE="$2";       shift 2 ;;
        --ime)        IME="$2";            shift 2 ;;
        --extra-args) EXTRA_ARGS="$2";     shift 2 ;;
        --no-rosetta) ROSETTA=0;            shift   ;;
        -*)
            printf 'error: unknown option for wayland-launch.sh: %s\n' "$1" >&2
            exit 2 ;;
        *)
            printf 'error: unexpected argument: %s\n' "$1" >&2
            exit 2 ;;
    esac
done

[ "$ARCH" = "arm64" ] && PLATFORM="linux/arm64" || PLATFORM="linux/amd64"

RUNTIME_DIR="/tmp/cocoa-way-qq"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[wayland] %s\n' "$*" >&2; }

# --- prerequisites ---------------------------------------------------------

command -v cocoa-way >/dev/null 2>&1 \
    || die "cocoa-way not found. Install with: brew tap J-x-Z/tap && brew install cocoa-way waypipe-darwin"
command -v waypipe  >/dev/null 2>&1 \
    || die "waypipe not found. Install with: brew install J-x-Z/tap/waypipe-darwin"
command -v perl     >/dev/null 2>&1 || true

# Cocoa-Way puts its Wayland socket in $TMPDIR/cocoa-way. It derives TMPDIR
# from its own launch environment, so detect the socket by probing rather than
# by parsing process arguments (the path never appears in argv).
cw_runtime=""
for candidate in \
    "${XDG_RUNTIME_DIR:-}" \
    "${TMPDIR:-/tmp}/cocoa-way" \
    /var/folders/*/*/T/cocoa-way; do
    [ -n "$candidate" ] || continue
    if [ -S "$candidate/${WAYLAND_DISPLAY:-wayland-1}" ]; then
        cw_runtime="$candidate"
        break
    fi
done
[ -n "$cw_runtime" ] || die "cannot locate Cocoa-Way's Wayland socket; is the compositor running? (launch: cocoa-way)"

wl_display="${WAYLAND_DISPLAY:-wayland-1}"
[ -S "$cw_runtime/$wl_display" ] \
    || die "no Wayland socket at $cw_runtime/$wl_display -- start Cocoa-Way first"
log "compositor: $cw_runtime ($wl_display)"

# --- container state -------------------------------------------------------

if container list --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    log "removing stale container '$CONTAINER_NAME'"
    container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    sleep 1
    container delete "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

host_transport="$RUNTIME_DIR/transport.sock"
host_waypipe="$RUNTIME_DIR/waypipe.sock"
rm -f "$host_transport" "$host_waypipe"

# The waypipe client side: it dials the compositor and waits for the guest.
XDG_RUNTIME_DIR="$cw_runtime" WAYLAND_DISPLAY="$wl_display" \
    waypipe --socket "$host_waypipe" --compress lz4 client \
    >"$RUNTIME_DIR/waypipe-client.log" 2>&1 &
wp_pid=$!
log "waypipe client pid $wp_pid"

for _ in $(seq 1 50); do
    [ -S "$host_waypipe" ] && break
    sleep 0.1
done
[ -S "$host_waypipe" ] || { kill "$wp_pid" 2>/dev/null || true; die "waypipe client never created $host_waypipe"; }

# The host half of the CWV2 transport. It waits for the container to publish
# its socket, then bridges frames to the waypipe client above.
host_relay_pid=""
cleanup() {
    log "shutting down"
    [ -n "$host_relay_pid" ] && kill "$host_relay_pid" 2>/dev/null || true
    kill "$wp_pid" 2>/dev/null || true
    container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f "$host_transport" "$host_waypipe"
}
trap cleanup EXIT INT TERM

# --- launch ----------------------------------------------------------------
#
# --publish-socket bridges a socket the *guest* creates back to the host path,
# which is why the relay script must be the container's first process.
# It listens on both ends and reports readiness on stdout before QQ starts.

log "starting container '$CONTAINER_NAME' ($ARCH)"
# --rosetta is only added for amd64: the vz backend cannot run a foreign arch
# without it, and adding it for a native arm64 guest would be pointless.
rosetta_flag=()
if [ "$ROSETTA" = "1" ] && [ "$ARCH" = "amd64" ]; then
    rosetta_flag=(--rosetta)
fi
# ${arr[@]} on an empty array trips `set -u` on bash 3.2 (the macOS default),
# so expand it only when it has an element.
#
# The --shm-size and the GL pinning below are not cosmetic. Chromium's renderer
# needs shared memory, and the container default is only 64M -- small enough
# that QQ presents a frame or two and then the renderer dies, surfacing as the
# misleading "Gtk-ERROR: Can't create a GtkStyleContext without a display
# connection" followed by an immediate shutdown. The guest VM also has no
# /dev/dri at all, so Chromium would otherwise spend its startup probing for a
# GPU that cannot exist; pinning Mesa's software rasteriser avoids that. These
# mirror what the working Cocoa-Way container profile
# (~/.config/cocoa-way/container-sessions.toml) sets.
container run --rm \
    --name "$CONTAINER_NAME" \
    --arch "$ARCH" --platform "$PLATFORM" ${rosetta_flag[@]+"${rosetta_flag[@]}"} \
    --cpus "$CPUS" --memory "$MEMORY" --shm-size "$SHM_SIZE" \
    --cap-drop ALL \
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --cap-add SETUID --cap-add SETGID --cap-add KILL \
    --env QQ_DISPLAY_BACKEND=wayland \
    --env XDG_RUNTIME_DIR=/tmp/wayland-runtime \
    --env WAYLAND_DISPLAY=waypipe.sock \
    --env QQ_WAYLAND_SOCKET=/tmp/wayland-runtime/waypipe.sock \
    --env QQ_ENABLE_IME="${IME}" \
    --env QQ_EXTRA_ARGS="${EXTRA_ARGS}" \
    --env LIBGL_ALWAYS_SOFTWARE=1 \
    --env GALLIUM_DRIVER=llvmpipe \
    --env MESA_LOADER_DRIVER_OVERRIDE=swrast \
    --publish-socket "$host_transport:/tmp/cocoa-way/transport.sock" \
    --mount type=bind,source="$(pwd)/QQ",target=/home/user/.config/QQ \
    --mount type=bind,source="$(pwd)/shared",target=/home/user/shared \
    --mount type=bind,source="$(pwd)/wl",target=/opt/wl,readonly \
    "$IMAGE" \
    /opt/wl/wl-transport.pl /tmp/cocoa-way/transport.sock /tmp/wayland-runtime/waypipe.sock \
        /usr/bin/waypipe --oneshot --compress lz4 \
            --socket /tmp/wayland-runtime/waypipe.sock server \
            -- /home/user/qq-wrapper.sh \
    >"$RUNTIME_DIR/container.log" 2>&1 &

container_pid=$!

# Ordering matters: the guest relay announces readiness on stdout only after it
# is listening, and the published socket is not usable before that. Connecting
# earlier lands on a placeholder the runtime accepts but never bridges, which
# shows up as "no OPEN frame from guest". So wait for READY first.
ready=0
for _ in $(seq 1 300); do
    if grep -q 'COCOA_WAY_TRANSPORT_V2_READY' "$RUNTIME_DIR/container.log" 2>/dev/null; then
        ready=1
        break
    fi
    if grep -Eq 'transport handshake|error|not found' "$RUNTIME_DIR/container.log" 2>/dev/null; then
        log "--- guest log ---"
        cat "$RUNTIME_DIR/container.log" >&2
        die "guest transport failed to start"
    fi
    kill -0 "$container_pid" 2>/dev/null || {
        log "--- guest log ---"; cat "$RUNTIME_DIR/container.log" >&2
        die "container exited during startup"
    }
    sleep 0.1
done
[ "$ready" = 1 ] || die "guest transport never reported ready"
log "guest transport ready"

# Now the bridge can be established in both directions.
perl "$(pwd)/wl/host-relay.pl" "$host_transport" "$host_waypipe" \
    >"$RUNTIME_DIR/host-relay.log" 2>&1 &
host_relay_pid=$!
log "host relay pid $host_relay_pid"

cat <<EOF

QQ (Wayland) started.

  Compositor : Cocoa-Way, display $wl_display
  Logs       : $RUNTIME_DIR/container.log
  Stderr     : ./logs-wayland.sh
  Stop       : ./stop-wayland.sh

If no window appears, check the log for an X11 fallback: QQ must report
--ozone-platform=wayland, never x11.

EOF

wait "$container_pid"
