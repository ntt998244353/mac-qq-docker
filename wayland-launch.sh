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
# This script does NOT build the transport itself. It asks Cocoa-Way to run
# the session, because a surface only gets presented when Cocoa-Way's own
# launcher is the thing that created it. See the comment at "delegate" below;
# this was the cause of a long-standing "QQ runs but no window appears" bug.
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
# Chromium's renderer needs far more than the 64M /dev/shm default. The guest
# VM also has no /dev/dri, so GL is pinned to Mesa's software rasteriser
# below; without that Chromium's GPU process dies and takes the Wayland
# connection with it.
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
        *)
            printf 'error: unknown option for wayland-launch.sh: %s\n' "$1" >&2
            exit 2 ;;
    esac
done

[ "$ARCH" = "arm64" ] && PLATFORM="linux/arm64" || PLATFORM="linux/amd64"

RUNTIME_DIR="/tmp/cocoa-way-qq"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[wayland] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# prerequisites
# ---------------------------------------------------------------------------

command -v cocoa-way >/dev/null 2>&1 \
    || die "cocoa-way not found. Install with: brew tap J-x-Z/tap && brew install cocoa-way waypipe-darwin"
command -v cocoa-wayctl >/dev/null 2>&1 \
    || die "cocoa-wayctl not found (ships with cocoa-way)"
command -v waypipe  >/dev/null 2>&1 \
    || die "waypipe not found. Install with: brew install J-x-Z/tap/waypipe-darwin"

# ---------------------------------------------------------------------------
# write a session definition for Cocoa-Way
# ---------------------------------------------------------------------------
#
# Cocoa-Way reads every session it is allowed to launch from
# ~/.config/cocoa-way/container-sessions.toml, and that path is hardcoded (there
# is no environment override). Writing an entry there is the whole trick: it
# means Cocoa-Way, not this script, owns the container and the waypipe pair, and
# therefore it is Cocoa-Way that allocates the display.
#
# The file may also hold sessions belonging to the user, so it is edited rather
# than replaced: our own block is delimited by markers and swapped out, and
# everything outside those markers is left byte-for-byte alone.

CONFIG_DIR="${HOME}/.config/cocoa-way"
CONFIG_FILE="$CONFIG_DIR/container-sessions.toml"
BEGIN_MARK="# >>> mac-qq-docker (managed block; edit wayland-launch.sh instead) >>>"
END_MARK="# <<< mac-qq-docker <<<"

# Cocoa-Way matches on this name; it is also what `cocoa-wayctl launch` takes
# and what `displays` reports as the display slot.
SESSION_NAME="${QQ_SESSION_NAME:-$CONTAINER_NAME}"
case "$SESSION_NAME" in
    *[!A-Za-z0-9._-]*) die "session name must be alphanumeric with . _ - only: $SESSION_NAME" ;;
esac

mkdir -p "$CONFIG_DIR"

# TOML string escaping: only backslash and double quote are special here.
toml_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# The container name is derived by Cocoa-Way from the session; deleting any
# same-named container first avoids "ContainerAlreadyRunning" on relaunch, which
# would otherwise need the GUI to clear.
if container list --format '{{.Names}}' 2>/dev/null | grep -qx "cocoa-way-$SESSION_NAME"; then
    log "removing stale container 'cocoa-way-$SESSION_NAME'"
    container stop "cocoa-way-$SESSION_NAME" >/dev/null 2>&1 || true
    sleep 1
    container delete "cocoa-way-$SESSION_NAME" >/dev/null 2>&1 || true
fi

# If a previous run left a live session for this name, stop it first so the
# relaunch does not collide with itself.
if cocoa-wayctl --json applications 2>/dev/null \
        | grep -q "\"name\":\"$SESSION_NAME\""; then
    log "stopping existing Cocoa-Way session '$SESSION_NAME'"
    cocoa-wayctl --json stop "$SESSION_NAME" >/dev/null 2>&1 || true
    sleep 2
fi

# Build our block in a temp file first, then splice it into the config.
BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/qq-session-block.XXXXXX")"
# Compose with the existing EXIT trap rather than replacing it: a second
# `trap ... EXIT` would silently drop the first one.
cleanup_tmp() {
    rm -f "$BLOCK_FILE" "${MERGED_FILE:-}"
}

{
    echo "$BEGIN_MARK"
    echo "[[session]]"
    echo "name = \"$(toml_escape "$SESSION_NAME")\""
    echo "runtime = \"container\""
    echo "image = \"$(toml_escape "$IMAGE")\""
    echo "# rootless: each native Wayland app gets its own macOS window."
    echo "presentation = \"rootless\""
    echo "profile = \"single-app\""
    echo "app = \"/home/user/qq-wrapper.sh\""
    echo "waypipe_compress = \"lz4\""
    echo "audio = false"
    echo
    echo "runtime_args = ["
    if [ "$ARCH" = "amd64" ]; then
        echo "  \"--arch\", \"amd64\","
        echo "  \"--platform\", \"linux/amd64\","
    else
        echo "  \"--arch\", \"arm64\","
        echo "  \"--platform\", \"linux/arm64\","
    fi
    if [ "$ROSETTA" = "1" ] && [ "$ARCH" = "amd64" ]; then
        echo "  \"--rosetta\","
    fi
    echo "  \"--cpus\", \"$(toml_escape "$CPUS")\","
    echo "  \"--memory\", \"$(toml_escape "$MEMORY")\","
    echo "  \"--shm-size\", \"$(toml_escape "$SHM_SIZE")\","
    echo "]"
    echo
    echo "mounts = ["
    echo "  \"type=bind,source=$(pwd)/QQ,target=/home/user/.config/QQ\","
    echo "  \"type=bind,source=$(pwd)/shared,target=/home/user/shared\","
    echo "]"
    echo
    # The key must be "env". The config struct has no deny_unknown_fields, so
    # an invented key such as "environment" is silently dropped and QQ falls
    # back to the X11 branch, dying with "Missing X server or $DISPLAY".
    echo "env = ["
    echo "  \"QQ_DISPLAY_BACKEND=wayland\","
    echo "  \"ELECTRON_OZONE_PLATFORM_HINT=wayland\","
    echo "  \"GDK_BACKEND=wayland\","
    echo "  \"QT_QPA_PLATFORM=wayland\","
    echo "  \"LIBGL_ALWAYS_SOFTWARE=1\","
    echo "  \"GALLIUM_DRIVER=llvmpipe\","
    echo "  \"MESA_LOADER_DRIVER_OVERRIDE=swrast\","
    echo "  \"QQ_ENABLE_IME=$(toml_escape "$IME")\","
    if [ -n "$EXTRA_ARGS" ]; then
        echo "  \"QQ_EXTRA_ARGS=$(toml_escape "$EXTRA_ARGS")\","
    fi
    echo "]"
    echo "$END_MARK"
} > "$BLOCK_FILE"

# Splice: keep everything outside our markers, drop our previous block if any.
MERGED_FILE="$(mktemp "${TMPDIR:-/tmp}/qq-session-merged.XXXXXX")"
if [ -f "$CONFIG_FILE" ]; then
    /usr/bin/awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip       { print }
    ' "$CONFIG_FILE" > "$MERGED_FILE"
else
    : > "$MERGED_FILE"
fi

# Re-join with exactly one blank line between the preserved sessions and ours,
# however many trailing newlines the original file happened to end with.
/usr/bin/awk '
    { lines[NR] = $0 }
    END {
        last = NR
        while (last > 0 && lines[last] == "") last--
        for (i = 1; i <= last; i++) print lines[i]
        if (last > 0) print ""
    }
' "$MERGED_FILE" > "$MERGED_FILE.tmp" && mv "$MERGED_FILE.tmp" "$MERGED_FILE"

cat "$BLOCK_FILE" >> "$MERGED_FILE"

# Only replace the real config once the merged result parses as TOML, so a bug
# here cannot leave the user with a config Cocoa-Way refuses to read.
#
# tomllib is Python 3.11+, but macOS ships 3.9 at /usr/bin/python3, so prefer a
# Homebrew interpreter and skip the check entirely if none has it. Skipping is
# safe: the only content we add is generated by this script, and the merge
# preserves the user's bytes exactly.
valid=1
for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$py" ] || continue
    if "$py" -c 'import tomllib' 2>/dev/null; then
        if ! "$py" -c '
import sys, tomllib
try:
    tomllib.load(open(sys.argv[1], "rb"))
except Exception as exc:
    sys.stderr.write("merged config is not valid TOML: %s\n" % exc)
    sys.exit(1)
' "$MERGED_FILE"; then
            valid=0
        fi
        break
    fi
done

if [ "$valid" = "1" ]; then
    mv "$MERGED_FILE" "$CONFIG_FILE"
    MERGED_FILE=""
else
    rm -f "$MERGED_FILE"
    die "refusing to write $CONFIG_FILE: the merged result is not valid TOML"
fi

log "wrote session '$SESSION_NAME' to $CONFIG_FILE"

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# ---------------------------------------------------------------------------
# delegate: let Cocoa-Way own the launch
# ---------------------------------------------------------------------------
#
# This is the part that makes the difference between "QQ runs" and "QQ is on
# screen", and it is not obvious from the outside.
#
# Cocoa-Way reports two different lists, and only one of them means anything:
#
#   displays.managed[]   displays that exist. A display created through
#                        `display-create` sits here forever with
#                        "status":"free","attachments":0, because the
#                        attachment count is computed as
#                            active_sessions.filter(s.display_slot == slot).count()
#                        i.e. it counts *Cocoa-Way's own* sessions. An external
#                        waypipe pointed at such a display connects happily,
#                        transfers frames, and presents nothing at all -- with
#                        no error anywhere.
#
#   displays.active[]    displays with a live session attached, i.e. what is
#                        actually on screen. Only `cocoa-wayctl launch` gets a
#                        session in here.
#
# So do not hand waypipe a socket path; hand Cocoa-Way the whole session.

cocoa-wayctl --json launch "$SESSION_NAME" >/dev/null 2>&1 \
    || die "cocoa-wayctl launch '$SESSION_NAME' failed (run: cocoa-wayctl diagnostics $SESSION_NAME)"

# Wait for the session to appear, then for its display to attach.
#
# A freshly queued launch can report a terminal-looking state for a moment
# while Cocoa-Way is still spinning the container up, so do not trust a single
# reading: only give up once a terminal state has held still for a while.
session_state() {
    cocoa-wayctl --json applications 2>/dev/null \
        | /usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin).get("data") or []
except Exception:
    sys.exit(0)
for entry in data:
    if entry.get("name") == sys.argv[1]:
        print(entry.get("state") or "")
        break
' "$SESSION_NAME" 2>/dev/null || true
}

state=""
terminal_streak=0
for _ in $(seq 1 600); do
    state="$(session_state)"
    case "$state" in
        Running) break ;;
        Exited|Failed)
            terminal_streak=$((terminal_streak + 1))
            # ~10s of consecutive terminal readings before believing it.
            [ "$terminal_streak" -ge 100 ] && break ;;
        *) terminal_streak=0 ;;
    esac
    sleep 0.1
done

if [ "$state" != "Running" ]; then
    log "--- cocoa-way diagnostics ---"
    cocoa-wayctl diagnostics "$SESSION_NAME" >&2 2>/dev/null || true
    die "session '$SESSION_NAME' did not reach Running (state: ${state:-unknown})"
fi

# A Running session with no attached display is the exact silent-failure mode
# described above, so check for it explicitly instead of assuming success.
attached=0
for _ in $(seq 1 100); do
    attached="$(cocoa-wayctl --json displays 2>/dev/null \
        | /usr/bin/python3 -c '
import json, sys
try:
    active = (json.load(sys.stdin).get("data") or {}).get("active") or []
except Exception:
    sys.exit(0)
print(1 if active else 0)
' 2>/dev/null || echo 0)"
    [ "$attached" = "1" ] && break
    sleep 0.1
done

if [ "$attached" != "1" ]; then
    log "--- cocoa-way diagnostics ---"
    cocoa-wayctl diagnostics "$SESSION_NAME" >&2 2>/dev/null || true
    die "session is Running but no display attached -- the window will not be visible"
fi

log "session '$SESSION_NAME' is Running with an attached display"

cat <<EOF

QQ (Wayland) started.

  Session    : $SESSION_NAME (owned by Cocoa-Way)
  Compositor : Cocoa-Way, rootless presentation
  Logs       : ./logs-wayland.sh
  Stop       : ./stop-wayland.sh

Verify the window is really presented -- "attached" must be non-empty:

  cocoa-wayctl displays

EOF

# Follow the session until it ends, so `qq.sh` behaves like it did when it
# owned the container directly (foreground, exits with QQ). Cocoa-Way holds
# the container, so there is no child of ours to wait on; poll instead.

# Ctrl-C should stop the session, not leave an orphaned container behind.
interrupted=0
on_signal() {
    interrupted=1
}
trap on_signal INT TERM
trap cleanup_tmp EXIT

while :; do
    sleep 2
    if [ "$interrupted" = "1" ]; then
        log "interrupted -- stopping session '$SESSION_NAME'"
        cocoa-wayctl --json stop "$SESSION_NAME" >/dev/null 2>&1 || true
        break
    fi
    state="$(session_state)"
    case "$state" in
        Running|Starting) ;;
        *) break ;;
    esac
done

log "session ended (state: ${state:-unknown})"
