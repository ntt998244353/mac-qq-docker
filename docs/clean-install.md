# Clean install / uninstall (reproducing a from-scratch run)

How to wipe everything this project installs and then reproduce it from
scratch, so a fix can be trusted on a machine that has never run it.

`./qq.sh --uninstall` reverses the installation. It is reversible and
idempotent: running it twice changes nothing the second time.

---

## 1. What gets installed, and therefore what gets removed

The install is spread over four places, which is why a hand-rolled cleanup
usually leaves something behind:

| # | Artefact | Where | Why it needs its own step |
|---|----------|-------|---------------------------|
| 1 | Cocoa-Way **session** | in-memory in the Cocoa-Way daemon + `~/.config/cocoa-way/container-sessions.toml` | Only `cocoa-wayctl` can end a session. Deleting the container behind its back leaves the session believing it is still running. Editing the TOML alone is not enough either, because the daemon may be holding it in memory. |
| 2 | **Container** | Apple `container` runtime | Named `cocoa-way-<session>`, *not* `<session>`. `container delete qq-amd64-wayland` misses it entirely. |
| 3 | **Image(s)** | Apple `container` runtime | `mac-qq-docker:amd64`, `:arm64`, `:latest`. |
| 4 | **Session block** | `~/.config/cocoa-way/container-sessions.toml` | Inserted by `wayland-launch.sh`. Must be removed by exact `name` match, and the file re-parsed, or the user's own `[[session]]` entries are damaged. |
| 5 | **Scratch state** | `/tmp/cocoa-way-qq`, `/tmp/cw-501-*` | Transport sockets, logs, and the legacy runtime dir. |

Not touched (shared tooling, belongs to the machine not the project):
Cocoa-Way itself, waypipe, XQuartz, Homebrew, the `container` CLI.

---

## 2. Uninstall

```bash
cd ~/projects/mac-qq-docker

# see what would go, without touching anything
./qq.sh --uninstall --dry-run

# actually remove it; keeps ./QQ and ./shared
./qq.sh --uninstall

# or remove the user data too (chat history + login state, ~670MB here)
./qq.sh --uninstall --purge
```

`--purge` on its own is rejected rather than silently ignored.

### User data is kept by default — on purpose

| Path | Size | Contents |
|------|------|----------|
| `./QQ` | ~488 MB | chat history, login state, caches |
| `./shared` | ~179 MB | files shared with the guest |

Deleting these means re-scanning a QR code to log in again, so they are only
removed when `--purge` is explicit.

### Confirm it is really gone

```bash
container image ls   | grep mac-qq     # expect: no output
container ls -a      | grep qq         # expect: no output
cocoa-wayctl --json applications       # expect: no qq* session

# the user's own session must survive, and the file must stay valid TOML
/opt/homebrew/bin/python3 -c "
import tomllib
d = tomllib.load(open('$HOME/.config/cocoa-way/container-sessions.toml','rb'))
print([s['name'] for s in d['session']])
"
```

---

## 3. Reinstall from scratch

### 3.1 Cocoa-Way must already be running

`qq.sh` talks to a Cocoa-Way **daemon**. Uninstalling does not stop it, but if
it is not running the launch fails with a confusing
`cannot connect to Cocoa-Way ... Connection refused (os error 61)`:

```bash
pgrep -f 'bin/cocoa-way$' || nohup /opt/homebrew/bin/cocoa-way >/tmp/cocoa-way.log 2>&1 &
sleep 10
cocoa-wayctl status >/dev/null && echo "daemon ok"
```

### 3.2 The cursor fix must still be installed

Stock Homebrew 2.0.3 has the disappearing-cursor bug (`NSCursor::hide()`
without a matching `unhide()`). Confirm the patched binary is in place:

```bash
md5 -q /opt/homebrew/bin/cocoa-way
# af6b95bbd942d8d737fdd1fbf0e9ac6f  = patched HEAD  (correct)
# aa5094b72fab963317724616fc3feab7  = stock 2.0.3   (cursor will vanish)
```

If it shows the stock hash, reinstall the patch:

```bash
cd ~/projects/mac-qq-docker/cocoa-way-patch && ./install-cocoa-way-head.sh
```

**A `brew upgrade cocoa-way` silently reverts this.** Re-run the script after
any upgrade.

### 3.3 Build and run

```bash
cd ~/projects/mac-qq-docker
./qq.sh --build --arch amd64
```

Full form when you already have the `.deb` locally (skips the download):

```bash
./qq.sh --build --pkg local --pkg-path /tmp/QQ_3.2.34_260924_amd64_01.deb --arch amd64
```

First build takes several minutes (it fetches the `.deb` and exports an OCI
image). The command returns once the session is launched.

---

## 4. Verifying the result

> **The renderer count is not a valid check.** QQ on this build renders
> **in-process**. A fully working session has **zero** `--type=renderer` and
> zero `--type=gpu-process` children, with ~87 threads in the browser process.
> Counting renderers measures nothing and will make a healthy window look
> broken.

### 4.1 The window exists and belongs to *this* session

```bash
cocoa-wayctl --json displays | /opt/homebrew/bin/python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
print('active:',[(a.get('display_slot'),a.get('display_pid')) for a in d.get('active',[])])
"
```

Note the `display_pid`, then check which process owns the on-screen window:

```bash
/tmp/winlist2 2>/dev/null | grep APP-SIZED   # rebuild from /tmp/winlist2.swift if missing
```

The `pid=` of the 800x632 window must equal the session's `display_pid`.
**A 800x632 window with `onscreen=1` belonging to a *different* pid is a
ghost** left by an earlier run — see 4.3.

### 4.2 It is actually painting

Sample several times; a single reading is meaningless because an idle app
legitimately reports 0:

```bash
for i in 1 2 3 4 5; do
  cocoa-wayctl --json displays | /opt/homebrew/bin/python3 -c "
import json,sys
for p in json.load(sys.stdin)['data'].get('performance',[]):
    if 'qq' in p['slot']: print(p['commits_per_second'])
"
  sleep 4
done
```

- **Working**: 0 when idle, roughly 15–36 when QQ repaints.
- **Blank-window bug**: 0 on every sample, *and* `host_input_to_present_ms`
  is `null` (that field is only written when a frame really reaches the host).

### 4.3 Ghost windows (a false positive to watch for)

A long-lived Cocoa-Way daemon keeps **orphan 800x632 windows** from earlier
sessions, and the window server reports one of them as `onscreen=1`. So
"a window is on screen" can be true while *your* session's window is not.

Confirm by matching the window's `pid=` to the session's `display_pid`
(section 4.1). When in doubt, stop the session — if the window survives, it
was never yours:

```bash
./stop-wayland.sh
/tmp/winlist2 2>/dev/null | grep APP-SIZED    # should print nothing
```

---

## 5. Gotchas that cost real time here

- **`--uninstall --dry-run` must stay side-effect free.** An earlier revision
  performed the uninstall despite `--dry-run`; the ordering is now
  uninstall → dry-run check → real uninstall.
- **`QQ_EXTRA_ARGS` never reaches the guest.** It is written to the session
  TOML correctly and appears in the waypipe argv, but is dropped in the
  relay handoff, so it is absent from `container run`. Flags must be baked
  into the image (`qq-wrapper.sh`) and rebuilt.
- **`XDG_RUNTIME_DIR` cannot be overridden** via the session's `env[]`:
  Cocoa-Way hardcodes `/tmp/cocoa-way-runtime` and filters our value out.
  `qq-wrapper.sh` therefore *satisfies* it instead (creates the dir and
  symlinks the real socket as `wayland-0`/`wayland-1`).
- **`pgrep -f "type=renderer"` inside `sh -c` matches the shell itself**, and
  `grep -c "--type=renderer"` counts its own process. Use
  `ps -eo args | awk '/--type=renderer/ && !/awk/'`.
- **QQ's `NativeCrashHandler` is not evidence of a crash.** It runs on every
  start and uploads a ~27 KB event built from empty paths
  (`backup_record.txt` and `sysLog` are both absent) and reports
  `response code: 200`. A real crash shows up as a fresh `.dmp` under
  `QQ/Crashpad/`.
- **`./stop-wayland.sh` derives the session name** rather than assuming
  `qq-wayland`, because `qq.sh` names sessions per arch
  (`qq-amd64-wayland`). Assuming the default left the real session running,
  and the next launch silently reused the stale container.
