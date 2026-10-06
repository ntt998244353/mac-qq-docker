#!/usr/bin/env bash
#
# Replace the Homebrew cocoa-way 2.0.3 binary with one built from upstream
# HEAD, which fixes a mouse-cursor bug present in the released v2.0.3.
#
# WHY
#   The released cocoa-way 2.0.3 has a broken cursor handler in
#   src/state.rs::cursor_image():
#
#       CursorImageStatus::Hidden  => NSCursor::hide()
#       CursorImageStatus::Named   => { cursor.set() ; /* never unhides */ }
#       CursorImageStatus::Surface => { ...          ; /* never unhides */ }
#
#   NSCursor::hide()/unhide() are reference-counted. v2.0.3 calls hide()
#   but has NO matching unhide() anywhere in the codebase (verified: 0
#   occurrences), and no `show_hidden_cursor` helper at all. So the first
#   time any Wayland client sends CursorImageStatus::Hidden the cursor is
#   hidden for good. The only thing that brings it back is winit's
#   internal set_cursor_visible(true) on CursorLeft (e.g. clicking the
#   macOS menu bar so the pointer leaves the window).
#
#   This is a GENERAL bug: Chromium/Electron clients (QQ included) send
#   Hidden very often (new window popup, video idle period, etc.), so the
#   cursor disappearing is universal on released cocoa-way for Electron
#   apps, not specific to this project.
#
#   Upstream fixed it on master (commit after v2.0.3) with a refcounted
#   CursorVisibility AtomicBool that balances hide()/unhide(). No release
#   tag contains the fix yet, so we build master ourselves.
#
# USAGE
#   ./install-cocoa-way-head.sh          # rebuild + install + (opt) restart
#
# NOTE
#   A Homebrew `upgrade` of cocoa-way will overwrite this. Re-run this
#   script afterwards (source patch notes: re-link any newer binary too).
#
set -euo pipefail

VER="2.0.3"
SRC_REPO="https://github.com/J-x-Z/cocoa-way"
BRANCH="master"
CELLAR_BIN="/usr/local/Cellar/cocoa-way/$VER/bin/cocoa-way"
HOMEBREW_PREFIX="$(brew --prefix)"
CELLAR_BIN="$HOMEBREW_PREFIX/Cellar/cocoa-way/$VER/bin/cocoa-way"

echo "==> Cocoa-Way HEAD patch installer ($VER -> master)"

if [ ! -x "$CELLAR_BIN" ]; then
    echo "!! Cellar binary not found at $CELLAR_BIN ; installing via brew first is required."
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cloning upstream master"
git clone --depth 1 -b "$BRANCH" "$SRC_REPO" "$WORK/cocoa-way"

echo "==> Verifying cursor fix present in source"
FIX_SIGNS=$(grep -c "set_cursor_hidden\|show_hidden_cursor" "$WORK/cocoa-way/src/state.rs")
if [ "$FIX_SIGNS" = "0" ]; then
    echo "!! Cursor fix not found in cloned source; aborting to avoid clobbering a good binary."
    exit 1
fi
echo "    cursor fix markers found: $FIX_SIGNS"

echo "==> Building (this needs cargo + rust + Xcode CLT)"
( cd "$WORK/cocoa-way" && cargo build --release )

NEW_BIN="$WORK/cocoa-way/target/release/cocoa-way"
[ -x "$NEW_BIN" ] || { echo "!! build did not produce a binary"; exit 1; }

echo "==> Backing up existing binary"
cp "$CELLAR_BIN" "$CELLAR_BIN.v$VER-orig"

echo "==> Installing"
install -m 0755 "$NEW_BIN" "$CELLAR_BIN"

echo
echo "Installed. Verify with:  cocoa-way --version"
echo "The cursor should now stay visible across client window changes."
echo "A 'brew upgrade cocoa-way' will restore the stock 2.0.3; re-run this script then."