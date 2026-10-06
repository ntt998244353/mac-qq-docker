#!/bin/bash
# windows.sh -- list on-screen GUI windows with their owning PID and size.
#
# Why: `cocoa-wayctl diagnostics` reports redraw_fps and commits_per_second,
# but an *idle* application legitimately commits zero frames. So a zero there
# does not mean the window is missing. The only trustworthy check is asking the
# macOS window server directly whether a surface exists.
#
# AppleScript is not usable for this:  System Events returns error -1743
# ("not authorized to send Apple events") unless the parent process has been
# granted Automation permission, which a headless shell cannot do.
# CGWindowListCopyWindowInfo needs no permission for basic window metadata.
#
# Usage: ./windows.sh [name-filter]
set -euo pipefail

FILTER="${1:-}"
DIR="${TMPDIR:-/tmp}/mac-qq-windows"
mkdir -p "$DIR"

if [ ! -x "$DIR/wl" ] || [ ! -f "$DIR/wl.swift" ]; then
    cat >"$DIR/wl.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []

for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let title = w[kCGWindowName as String] as? String ?? ""
    let pid   = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let b     = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let wd = b["Width"]  as? Double ?? 0
    let ht = b["Height"] as? Double ?? 0
    print("\(pid)\t\(owner)\t\(Int(wd))x\(Int(ht))\t\(title)")
}
SWIFT
    swiftc -O "$DIR/wl.swift" -o "$DIR/wl" 2>/dev/null \
        || { echo "error: failed to compile the window lister" >&2; exit 1; }
fi

"$DIR/wl" | if [ -n "$FILTER" ]; then grep -i -- "$FILTER"; else cat; fi
