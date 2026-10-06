# Cocoa-Way HEAD cursor fix

> **版本要求：cocoa-way > 2.0.3，或 ≥ commit `f7eca85c`。**
> v2.0.3 及之前的所有版本都有此 bug。

## The three upstream fix commits

| commit | subject |
| --- | --- |
| `f7eca85c` | Balance NSCursor hide/unhide so the cursor doesn't stay hidden |
| `d6895dac` | Show a hidden cursor when the pointer leaves or its window closes |
| `3e2f631c` | Restore the cursor when its Wayland surface closes |

`f7eca85c` is the core fix (balanced refcounting). The other two close the
remaining leak paths (window close / surface destruction). v2.0.3's tip is
`bdcb7b8b`; the last buggy state is `e1ff9b9b`.

The released **cocoa-way 2.0.3** (also the Homebrew `j-x-z/tap/cocoa-way` default)
has a genuine upstream bug that makes the **mouse cursor disappear** in Wayland
clients and never reliably come back.

## Symptom (matches this project)

- The QQ window renders and is interactive, but the mouse cursor is **invisible**.
- Clicking the macOS **menu bar** brings the cursor back — until a **new window**
  is opened (e.g. QQ "merged-forward chat records"), at which point it vanishes
  again. Other clicks inside a window have no effect on cursor visibility.

## Root cause (verified against source of v2.0.3 tarball)

`src/state.rs::cursor_image()`:

```rust
match image {
    CursorImageStatus::Hidden => NSCursor::hide(),   // refcount+1
    CursorImageStatus::Named(icon) => { ...cursor.set()... }  // never unhides
    CursorImageStatus::Surface(_) => { ... }                 // never unhides
}
```

- `NSCursor::hide()` / `unhide()` are **reference-counted** macOS APIs.
- v2.0.3 calls `hide()` and has **zero `unhide()` calls** in the whole tree, and
  **no `show_hidden_cursor` helper**.
- The only path that re-shows the cursor is winit's internal
  `set_cursor_visible(true)` on `CursorLeft` — which is why leaving the window
  (menu-bar click) restores it, and why each new window re-hides it.

This is a **general** bug: any Wayland client that sends `Hidden`
(Chromium/Electron send it on new-window popups and video idle periods) is hit.
It is not specific to QQ or this project.

## The fix already exists upstream (unreleased)

Upstream master added a refcounted `CursorVisibility` AtomicBool so
`hide()`/`unhide()` stay balanced (comment in source):

```rust
// NSCursor hide/unhide calls are counted and must be balanced. Clients such as
// Chromium hide the cursor repeatedly (YouTube does on every idle period during
// playback), so hide only once and unhide as soon as a visible cursor is set again.
```

**No release tag contains this fix** (latest tag is `v2.0.3`), so we build master
and verify the fix markers are present before installing.

## Applying the fix

```bash
cd cocoa-way-patch
./install-cocoa-way-head.sh   # clones master, verifies fix, builds, replaces Cellar binary
```

Afterwards:
- **Restart** cocoa-way so the new binary is live:
  ```bash
  pkill -f '^/opt/homebrew/Cellar/cocoa-way/.*/cocoa-way$'
  nohup cocoa-way > /tmp/cocoa-way.log 2>&1 &
  ```
- Concurrency note: a `brew upgrade cocoa-way` restores stock 2.0.3; re-run the
  installer then.

## Repro / verification notes

- The working binary here also verified: QC the running session still launches
  (`cocoa-wayctl launch QQ`) and the window + cursor remain over time.
- Validated via a temporary instrumented build that logs `cursor_image`,
  `set_cursor_hidden`, and `show_hidden_cursor` callbacks — see
  `cocoa-way-patch/` for the diagnosis trail.