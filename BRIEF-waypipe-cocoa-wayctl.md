# Decision Brief: `cocoa-wayctl` / waypipe Wayland launch regression

Repo: `/Users/ntt/projects/mac-qq-docker` (HEAD `f0655d3`, containing `924924a`, `b89abbb`)

## Status of inputs

- **Report 1 (waypipe / build):** Subagent stopped by user — no findings available. **GAP.**
- **Report 2 (cocoa-wayctl reference path):** Complete, evidence-backed.

---

## CONFIRMED facts

### Transport / architecture (cocoa-wayctl path)
- `cocoa-wayctl launch QQ` is a **control-API client**, not a launcher. It writes a command onto Cocoa-Way's compositor event loop (`"queued on Cocoa-Way's compositor event loop"`) and returns `accepted:true`.
- Compositor = pid `71783`, `/tmp/cwrepo/target/release/cocoa-way`. It runs its own container-session engine (`src/container_sessions.rs`), building:
  - per-session host Wayland display `wayland-<id>` (e.g. `wayland-SOWmBh2IEQ`)
  - per-session waypipe socket `/tmp/cocoa-way/waypipe.sock-server-<id>.sock`
  - **Host side waypipe (ssh mode):** `waypipe --compress lz4 --socket /tmp/cw-501-<pid>/qq-<id>.sock --remote-socket /tmp/cocoa-way/waypipe.sock --ssh-bin cocoa-way --remote-bin waypipe ssh apple-container sh -lc …` plus a `cocoa-way -R <guest>:<host>` relay process.
  - **Guest side:** compositor's **inline Perl CWV2 relay** (forked inline, *not* the repo's `wl-transport.pl`) execs:
    `waypipe --no-gpu --unlink-socket --threads 0 --compress lz4 --socket /tmp/cocoa-way/waypipe.sock-server-<id>.sock --display wayland-<id> server sh -lc '…; exec /home/user/qq-wrapper.sh'`
  - Container: `cocoa-way-qq`, image `mac-qq-docker:latest`, `--arch amd64 --platform linux/amd64 --rosetta --cpus 4 --memory 3072MB --shm-size 1G`
- Transport: Apple `container --publish-socket` bridges guest listen socket to host. CWV2 framing = `pack('CNN')` = kind + stream_id + len over a 5-byte `CWV2\x01` preamble.
- Both paths use the **same CWV2 protocol** and the **same host waypipe 0.11.2 / guest waypipe 0.8.4**.

### Difference table: cocoa-wayctl (works) vs `wayland-launch.sh`
| Aspect | cocoa-wayctl (works) | wayland-launch.sh |
|---|---|---|
| Host waypipe role | `ssh` mode, `--remote-socket` + relay binary | plain `client`, manual `host-relay.pl` |
| Guest server flags | `--no-gpu --unlink-socket --threads 0 --display wayland-<id>` | `--oneshot --compress lz4 --socket /tmp/wayland-runtime/waypipe.sock` |
| Wayland display | dedicated `wayland-<id>` | shared `wayland-1` |
| Guest relay | compositor inline Perl (multi-stream) | repo `wl/wl-transport.pl` (single stream) |
| Guest image | `mac-qq-docker:latest` | `mac-qq-docker:amd64` / `arm64` |
| QQ flags seen live | `--no-sandbox --ozone-platform=wayland --enable-wayland-ime …` (**no** `--disable-gpu`) | `--no-sandbox --disable-gpu --disable-gpu-compositing --in-process-gpu …` |

### cocoa-wayctl still works today — **YES**
- `cocoa-wayctl --json launch QQ` → API `accepted:true`.
- `running`: active session `display_slot: rootless-qq`, `instance_id: 6`, `display_pid 78894`, `waypipe_pid 78897`.
- `applications`: **`QQ -> Running`**.
- Container `cocoa-way-qq` alive; guest `ps` shows QQ pid 16 (`--ozone-platform=wayland`) + crashpad.
- Activity log: `cocoa-way transport v2: opened stream 2`, Chromium startup, frames.
- **The reported regression is not reproducible at HEAD.**
- Repo's own `wayland-launch.sh` also captured a **fully working run**: guest `waypipe server` held live `/memfd:waypipe` + `/memfd:wayland-cursor`; host `client-conn` fd4 peer `0x1d86979df424448c` matched **exactly** the compositor's `wayland-1` socket peer in `lsof -U`; thousands of `BufferDiff` / `Protocol` / `Applying diff` lines.
- `waypipe-client.log` is **0 bytes simply because non-debug waypipe prints nothing on success** — that was the misleading "symptom."

### Version hypothesis
- waypipe 0.11.2-client ↔ 0.8.4-server handshake is **proven compatible** (successful runs of both paths). **Not a version mismatch.**

### Documented failure modes (in-tree)
1. **fcitx GTK immodule.** With `GTK_IM_MODULE=fcitx` and fcitx *not* running, GTK aborts ~1–2 s after the first frame with the exact string:
   `Gtk-ERROR: Can not create a GtkStyleContext without a display connection`
   Env matrix reproduced: `QQ_ENABLE_IME=1` → `GTK_IM_MODULE=fcitx`; `QQ_ENABLE_IME=0` → `gtk-im-context-simple` (the fix). A launch path failing to pass `QQ_ENABLE_IME` inherits the image-baked `fcitx` and dies with exactly this message.
2. **GPU-process death race.** `QQ_FORCE_SOFTWARE` / missing `--disable-gpu`: Chromium logs `ContextResult::kFatalFailure: WebGL1 blocklisted` + `drmGetDevices2() has not found any devices`; GPU process dies, drops the Wayland connection, waypipe aborts (`wl_display#1: error 3`), and *then* GTK reports the same misleading message. In-tree fix: `--disable-gpu --disable-gpu-compositing --in-process-gpu` on Wayland.
3. **Stale image divergence.** `mac-qq-docker:latest` (used by cocoa-way) carries an **older `qq-wrapper.sh`** that *deliberately omits* `--disable-gpu` on Wayland (confirmed live: running QQ cmd had no `--disable-gpu`; baked file says "only disable the GPU when we are NOT on Wayland"). Current tree's `amd64`/`arm64` images always pass it. **Which image is stale determines whether the race fires.**

### Current tree already contains the fixes
- `924924a fix(wayland): stop the white-flash-then-die crash`
- `b89abbb fix(entrypoint): stop Crashpad state from breaking the next launch`
- `entrypoint.sh` / `qq-wrapper.sh` already export `QQ_ENABLE_IME` correctly and keep the Wayland `--disable-gpu` branch.

---

## HYPOTHESES (not yet independently confirmed)

- **H1:** The originally reported failure was environment/image-specific (stale `mac-qq-docker:latest` wrapper missing `--disable-gpu`), *not* a code regression at HEAD. *(Strongly supported by Report 2 (c)/(d)/(e); not reproducible at HEAD.)*
- **H2:** If any launch path drops `QQ_ENABLE_IME`, it inherits image-baked `GTK_IM_MODULE=fcitx` and reproduces the exact `Gtk-ERROR` string. *(Mechanism documented in-tree; not re-triggered live in Report 2.)*
- **H3:** Whatever Report 1 was investigating (waypipe/build) remained unresolved due to the user stop; may contain the missing root-cause evidence. **UNKNOWN.**

---

## RECOMMENDED FIX (single)

**Rebuild and retag `mac-qq-docker:latest` (and point the cocoa-way session `image` at it) from the current tree at `b89abbb`/`f0655d3`.**

```bash
docker build -t mac-qq-docker:latest .
docker build -t mac-qq-docker:amd64 .
```

(or use the repo's build script). This removes the stale `qq-wrapper.sh` that omits `--disable-gpu` on Wayland — the one concrete divergence between the working `cocoa-wayctl` path and the failure signature.

**Supporting actions (already correct in tree, verify only):**
1. Ensure every launch path exports `QQ_ENABLE_IME` (`qq.sh` → `wayland-launch.sh --ime`, and the cocoa-way session profile) so `GTK_IM_MODULE=gtk-im-context-simple` when fcitx is off.
2. Keep `--disable-gpu --disable-gpu-compositing --in-process-gpu` on the Wayland branch.

## ALTERNATIVES

- **A1:** If a distinct failure persists after the rebuild, add debug logging to waypipe (`--debug`) — since non-debug waypipe is silently 0 bytes on success, which caused the false "session dead" read.
- **A2:** Temporarily set `QQ_ENABLE_IME=0` explicitly in the cocoa-way session profile to isolate the fcitx path from the GPU path.
- **A3 (rejected):** Downgrade/pin waypipe to align 0.11.2/0.8.4. **Disproven** — both versions successfully interoperate.
- **A4:** Investigate Report 1's build/waypipe angle if the user can re-run it; that evidence is currently missing.

---

## Residual risks / open gaps

- Report 1 was stopped; its findings are entirely absent from this brief.
- H1–H3 are inference from Report 2; a clean rebuild-and-relaunch test was **not** performed in the input evidence.
- The Report 2 run at HEAD succeeded, so a fix cannot be "verified against a failing baseline" from the provided data.
