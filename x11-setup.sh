#!/bin/bash
# x11-setup.sh -- prepare XQuartz so the container can display QQ.
#
# macOS has no X11 server by default. XQuartz provides one, but it ships
# configured to refuse TCP connections, so that has to be relaxed.
#
# Access control: we use X11 cookies (`xauth`), not `xhost`.
#   * `xhost +` (what most tutorials suggest) disables access control for
#     EVERY host -- any machine that can reach port 6000 gets your display,
#     which means keylogging and screenshots.
#   * `xhost +<ip>` would be fine, but Apple `container` assigns the guest a
#     new IP on every run (192.168.64.7, .8, .9, ...), so it breaks constantly.
# Cookies are both per-host-capable and stable across container restarts.
#
# Run this once after installing XQuartz, and again after any reboot.
set -euo pipefail

cd "$(dirname "$0")"

export PATH="/opt/X11/bin:$PATH"

if [ ! -d /Applications/Utilities/XQuartz.app ]; then
    echo "XQuartz is not installed."
    echo
    echo "Install it (needs your password):"
    echo "    brew install --cask xquartz"
    echo
    echo "Then re-run this script. XQuartz 2.8.6+ starts listening immediately,"
    echo "so a logout is usually not required."
    exit 1
fi

# ---- 1. let XQuartz accept TCP connections --------------------------------
echo "==> enabling TCP listener in XQuartz"
defaults write org.xquartz.X11 nolisten_tcp -bool false
defaults write org.xquartz.X11 no_auth -bool false
defaults write org.xquartz.X11 enable_iglx -bool true

# ---- 2. make sure XQuartz is running --------------------------------------
if ! nc -z 127.0.0.1 6000 2>/dev/null; then
    echo "==> starting XQuartz"
    open -a XQuartz
    for _ in $(seq 1 20); do
        nc -z 127.0.0.1 6000 2>/dev/null && break
        sleep 1
    done
fi

if ! nc -z 127.0.0.1 6000 2>/dev/null; then
    echo "ERROR: XQuartz is not listening on TCP 6000." >&2
    echo "       Try logging out and back in, then re-run this script." >&2
    exit 1
fi
echo "    X11 TCP listener is up on 127.0.0.1:6000"

# ---- 3. find the X server's real auth file --------------------------------
# XQuartz is started via startx, which passes an explicit
#   -auth /Users/<you>/.serverauth.<pid>
# Adding cookies to ~/.Xauthority therefore has NO effect on the running
# server. We must write to the file the server actually loaded.
find_server_auth() {
    local pid authfile
    pid=$(pgrep -f 'Xquartz :0' | head -1) || true
    if [ -z "$pid" ]; then return 1; fi
    authfile=$(ps -o args= -p "$pid" | tr ' ' '\n' | grep -A1 '^-auth$' | tail -1)
    [ -n "$authfile" ] && [ -f "$authfile" ] && printf '%s\n' "$authfile"
}

AUTHFILE=$(find_server_auth || true)
if [ -z "$AUTHFILE" ]; then
    echo "ERROR: could not locate XQuartz's -auth file." >&2
    exit 1
fi
echo "    X server auth file: ${AUTHFILE}"

# ---- 4. generate and install a cookie for the container subnet ------------
COOKIE_FILE="${PWD}/.x11-cookie"
if [ -f "$COOKIE_FILE" ]; then
    COOKIE=$(cat "$COOKIE_FILE")
    echo "    reusing existing cookie from .x11-cookie"
else
    COOKIE=$(openssl rand -hex 16)
    printf '%s' "$COOKIE" > "$COOKIE_FILE"
    chmod 600 "$COOKIE_FILE"
    echo "    generated new cookie -> .x11-cookie"
fi

# The vmnet guest range is 192.168.64.0/24 and the guest IP changes per run.
# Register a handful of addresses so any recent container works without
# re-running this script. Extra unused entries are harmless.
echo "==> installing cookies into the running X server"
for ip in $(seq 2 30); do
    xauth -f "$AUTHFILE" add "192.168.64.${ip}:0" MIT-MAGIC-COOKIE-1 "$COOKIE" 2>/dev/null || true
done
echo "    registered 192.168.64.2-30"

# Also record it in the user's own authority file, so plain `xhost`/X clients
# from the host keep working consistently.
xauth -f ~/.Xauthority add "192.168.64.1:0" MIT-MAGIC-COOKIE-1 "$COOKIE" 2>/dev/null || true

# ---- 5. verify ------------------------------------------------------------
echo
echo "==> verification"
if command -v xdpyinfo >/dev/null 2>&1; then
    DISPLAY=:0 timeout 10 xdpyinfo >/dev/null 2>&1 \
        && echo "    local display :0 OK"
fi
echo "    server knows these container displays:"
xauth -f "$AUTHFILE" list | grep -c '192\.168\.64\.' | sed 's/^/      /'

echo
echo "done. access control is still ENABLED (unlike 'xhost +')."
echo "you can now run:  ./run.sh"
