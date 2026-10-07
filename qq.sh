#!/bin/bash
# qq.sh -- unified launcher for Linux QQ on macOS.
#
# One entry point for every supported combination:
#
#     runtime : container (Apple `container`, default)  |  lima (VM, vz/krunkit)
#     display : wayland  (Cocoa-Way, default, safer)    |  x11  (XQuartz)
#     package : url      (Tencent CDN, default)         |  local (.deb)  |  apt
#     arch    : amd64    (default)                      |  arm64
#
# Everything can be given as a flag or as an environment variable; flags win.
# Run `./qq.sh --help` for the full list.
#
# Design notes that matter:
#
#   * Rosetta is NOT an independent knob. Apple's vz backend cannot execute a
#     foreign architecture by itself, so an amd64 guest can only run at all
#     when Rosetta translation is on. Conversely Rosetta is pointless (and on
#     lima refused) for an aarch64 guest. So --rosetta is derived from
#     runtime x arch, and the flag only exists to override/disambiguate.
#
#   * The package source and the architecture are related: Tencent publishes
#     separate amd64/arm64 .deb files, so `--pkg local` needs to know which
#     one it is being handed. When it can, the script reads the arch straight
#     out of the .deb control file instead of trusting the user.
#
#   * `container` and `lima` are wildly different runtimes, so the script does
#     the small amount of translation between them (image build vs. VM setup,
#     `container run` flags vs. `limactl` + in-guest docker/podman) and keeps
#     the QQ-specific parts (mounts, env, backend selection) identical.
set -euo pipefail

# Remember where the user invoked us from. The script cd's into the project
# dir below, but paths the user typed (e.g. --pkg-path) must resolve against
# their shell's cwd, not against the project.
INVOKE_DIR="$(pwd)"
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
SELF="$(basename "$0")"

# ---------------------------------------------------------------------------
# defaults (all overridable by env, then by flags)
# ---------------------------------------------------------------------------
QQ_RUNTIME="${QQ_RUNTIME:-container}"     # container | lima
QQ_DISPLAY="${QQ_DISPLAY:-wayland}"       # wayland | x11
QQ_ARCH="${QQ_ARCH:-amd64}"               # amd64 | arm64
QQ_PKG="${QQ_PKG:-url}"                   # url | local | apt
QQ_PKG_PATH="${QQ_PKG_PATH:-}"            # path to .deb when QQ_PKG=local
QQ_ROSETTA="${QQ_ROSETTA:-}"              # "" = auto, 1 = force on, 0 = force off
QQ_NAME="${QQ_NAME:-}"                    # container / VM name (default per combo)
QQ_IMAGE="${QQ_IMAGE:-}"                  # image tag (default per arch)
QQ_CPUS="${QQ_CPUS:-4}"
QQ_MEMORY="${QQ_MEMORY:-4g}"
QQ_SHM_SIZE="${QQ_SHM_SIZE:-2g}"
QQ_VM_TYPE="${QQ_VM_TYPE:-vz}"            # lima only: vz | krunkit
QQ_LIMA_OS="${QQ_LIMA_OS:-debian-12}"     # lima only: template name

# Proxy handed to the guest/build. lima copies the host's HTTP(S)_PROXY into
# the VM, which is often wrong (a proxy reachable from the host may be flaky or
# unroutable from the guest) and shows up as apt 502s deep inside a build.
#   (unset)  inherit whatever lima gave the VM -- historical behaviour
#   off      explicitly unset the proxy vars in the guest
#   <url>    force this proxy for the guest's apt/curl
QQ_PROXY="${QQ_PROXY:-}"
QQ_ENABLE_IME="${QQ_ENABLE_IME:-0}"
QQ_EXTRA_ARGS="${QQ_EXTRA_ARGS:-}"
QQ_TZ="${QQ_TZ:-${TZ:-Asia/Shanghai}}"
QQ_BUILD=0
QQ_DRY_RUN=0
QQ_UNINSTALL=0
QQ_PURGE=0

# Tencent's official Linux packages. The amd64 one is the same artifact the
# AUR PKGBUILD mirrors; the arm64 one is served from the QQNT CDN. Both were
# verified to exist (HTTP 206) and the sha512 of the full files was recorded.
LINUXQQ_URL_AMD64="https://mirrors.sdu.edu.cn/spark-store-repository/store/chat/linuxqq/linuxqq_3.2.34-53644_amd64.deb"
LINUXQQ_SHA_AMD64="774e45cd7238dc51b31c02ee494f9f86e773c487a90851790a806f776e130af125110045844e90dd68d0b073dc53bdd4d1c6d8fb7225b8f214fc0e35d1a20e32"
LINUXQQ_URL_ARM64="https://qqdl.gtimg.cn/qqfile/QQNT/9.9.36/beta/9ee04bef/linuxqq_3.2.34-53644_arm64.deb"
LINUXQQ_SHA_ARM64="fa1424d41f934798a8f20b6cad8749f1eb99f29957501b3578449ade06fe105387e038e98cafb1bcc57d4d35010d771312ca0de7b14e62da0765cd29b005a5d1"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
c_reset=''; c_bold=''; c_dim=''; c_red=''; c_grn=''; c_ylw=''
if [ -t 2 ]; then
    c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'
    c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'
fi
die()  { printf '%serror:%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
warn() { printf '%swarn:%s %s\n'  "$c_ylw" "$c_reset" "$*" >&2; }
info() { printf '%s==>%s %s\n'    "$c_grn" "$c_reset" "$*" >&2; }
step() { printf '%s  -%s %s\n'    "$c_dim" "$c_reset" "$*" >&2; }

# Does this long option take a value? Used by the argument parser.
opt_needs_value() {
    case "$1" in
        runtime|display|pkg|pkg-path|arch|name|image|vm-type|lima-os|proxy|\
        cpus|memory|shm-size|extra-args|tz) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
${c_bold}qq.sh${c_reset} -- launch Linux QQ on macOS (Apple container or lima).

${c_bold}USAGE${c_reset}
  ./$SELF [options]
  ./$SELF --help

${c_bold}RUNTIME${c_reset}
  -r, --runtime <container|lima>   Where QQ runs.              (default: container)
      --vm-type <vz|krunkit>       lima only: VM driver.       (default: vz)
      --lima-os <template>         lima only: guest image.     (default: debian-12)
      --proxy <url|off>            lima only: proxy for the guest's apt/curl.
                                   lima copies the host proxy into the VM, which
                                   often breaks apt with 502s; pass 'off' to
                                   unset it, or a URL to override. (default: inherit)
  -n, --name <name>                Container / VM name.

${c_bold}DISPLAY${c_reset}
  -d, --display <wayland|x11>      Display backend.            (default: wayland)
                                   wayland = Cocoa-Way (no X11 keylogging surface)
                                   x11     = XQuartz over TCP

${c_bold}PACKAGE${c_reset}
  -p, --pkg <url|local|apt>        Where linuxqq comes from.    (default: url)
      --pkg-path <file.deb>        Required when --pkg local.
  -a, --arch <amd64|arm64>         Guest architecture.          (default: amd64)
                                   With --pkg local this is read from the .deb
                                   control metadata unless it contradicts.

${c_bold}ROSETTA${c_reset}
  --rosetta                        Force Rosetta on.
  --no-rosetta                     Force Rosetta off.
                                   Default is auto: Apple's vz backend cannot run a
                                   foreign arch, so it is required for an amd64
                                   guest and refused for an arm64 guest. Do not
                                   set this unless you are overriding on purpose.

${c_bold}RESOURCES${c_reset}
      --cpus <n>                   vCPUs.                      (default: 4)
      --memory <size>              RAM (e.g. 4g).              (default: 4g)
      --shm-size <size>            /dev/shm (container only).  (default: 2g)
      --ime                        Start fcitx5 inside the guest.
      --extra-args <args>          Extra args passed to QQ.
      --tz <zone>                  Timezone.                 (default: Asia/Shanghai)

${c_bold}ACTIONS${c_reset}
      --build                      (Re)build the image / prepare the VM first.
      --uninstall                  Remove everything this project installed:
                                   the Cocoa-Way session, the container(s), the
                                   image(s), and the generated session block.
                                   User data (QQ/ and shared/) is KEPT unless
                                   --purge is also given.
      --purge                      With --uninstall, also delete ./QQ and
                                   ./shared (chat history and login state).
      --dry-run                    Print the resolved plan and exit.
  -h, --help                       This help.

${c_bold}UNINSTALL${c_reset}
  --uninstall is safe to run repeatedly and does not touch Cocoa-Way,
  waypipe, XQuartz or Homebrew itself -- only the things this project made.
  To reproduce a from-scratch install:

    ./qq.sh --uninstall --purge     # back to a pristine checkout
    ./qq.sh --build                 # rebuild and run

${c_bold}ENVIRONMENT${c_reset}
  Every option has a QQ_-prefixed environment equivalent, e.g.
    QQ_RUNTIME=lima QQ_DISPLAY=x11 QQ_ARCH=arm64 ./$SELF
  Flags take precedence over environment variables.

${c_bold}EXAMPLES${c_reset}
  ${c_dim}# default: Apple container + Wayland + official amd64 .deb${c_reset}
  ./$SELF

  ${c_dim}# X11 instead of Wayland${c_reset}
  ./$SELF --display x11

  ${c_dim}# lima VM, native arm64 guest with the official arm64 package${c_reset}
  ./$SELF --runtime lima --arch arm64 --no-rosetta

  ${c_dim}# lima + amd64 guest (Rosetta required, auto-enabled)${c_reset}
  ./$SELF --runtime lima --arch amd64 --rosetta

  ${c_dim}# build an image from a .deb you already downloaded${c_reset}
  ./$SELF --pkg local --pkg-path ~/Downloads/linuxqq_3.2.34-53644_arm64.deb --build

  ${c_dim}# use whatever the distro repo ships (not Tencent's official build)${c_reset}
  ./$SELF --pkg apt
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
# macOS ships BSD getopt, which knows nothing about long options (and whose
# --version call silently mis-parses rather than reporting anything useful).
# Rather than add a Homebrew gnu-getopt dependency, both forms are parsed here
# in a way that behaves identically on macOS and Linux. Handles --opt=value,
# --opt value, -o value, and standalone short flags such as -h.
while [ $# -gt 0 ]; do
    opt=""; val=""

    case "$1" in
        --)  shift; break ;;

        # --opt=value -> normalise into two arguments
        --*=*)
            opt="${1%%=*}"; opt="${opt#--}"
            val="${1#*=}"
            ;;

        # --opt value / --flag
        --*)
            opt="${1#--}"
            if opt_needs_value "$opt"; then
                [ $# -ge 2 ] || die "--$opt requires a value"
                val="$2"; shift
            fi
            ;;

        # -x value
        -r|-d|-p|-a|-n)
            case "$1" in
                -r) opt=runtime ;; -d) opt=display ;; -p) opt=pkg ;;
                -a) opt=arch    ;; -n) opt=name    ;;
            esac
            [ $# -ge 2 ] || die "$1 requires a value"
            val="$2"; shift
            ;;

        -h)  usage; exit 0 ;;
        -*)  die "unknown option: $1 (try --help)" ;;
        *)   die "unexpected argument: $1 (try --help)" ;;
    esac
    shift

    case "$opt" in
        # booleans
        rosetta)    QQ_ROSETTA=1 ;;
        no-rosetta) QQ_ROSETTA=0 ;;
        ime)        QQ_ENABLE_IME=1 ;;
        build)      QQ_BUILD=1 ;;
        uninstall)  QQ_UNINSTALL=1 ;;
        purge)      QQ_PURGE=1 ;;
        dry-run)    QQ_DRY_RUN=1 ;;
        help)       usage; exit 0 ;;
        # values
        runtime)    QQ_RUNTIME="$val" ;;
        display)    QQ_DISPLAY="$val" ;;
        pkg)        QQ_PKG="$val" ;;
        pkg-path)   QQ_PKG_PATH="$val" ;;
        arch)       QQ_ARCH="$val" ;;
        name)       QQ_NAME="$val" ;;
        image)      QQ_IMAGE="$val" ;;
        vm-type)    QQ_VM_TYPE="$val" ;;
        lima-os)    QQ_LIMA_OS="$val" ;;
        proxy)      QQ_PROXY="$val" ;;
        no-proxy)   QQ_PROXY="off" ;;
        cpus)       QQ_CPUS="$val" ;;
        memory)     QQ_MEMORY="$val" ;;
        shm-size)   QQ_SHM_SIZE="$val" ;;
        extra-args) QQ_EXTRA_ARGS="$val" ;;
        tz)         QQ_TZ="$val" ;;
        *)          die "unknown option: --$opt (try --help)" ;;
    esac
done

[ $# -eq 0 ] || die "unexpected argument: $1 (try --help)"

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------
case "$QQ_RUNTIME" in
    container|lima) ;;
    *) die "--runtime must be container or lima (got '$QQ_RUNTIME')" ;;
esac
case "$QQ_DISPLAY" in
    wayland|x11) ;;
    *) die "--display must be wayland or x11 (got '$QQ_DISPLAY')" ;;
esac
case "$QQ_ARCH" in
    amd64|arm64) ;;
    *) die "--arch must be amd64 or arm64 (got '$QQ_ARCH')" ;;
esac
case "$QQ_PKG" in
    url|local|apt) ;;
    *) die "--pkg must be url, local or apt (got '$QQ_PKG')" ;;
esac
case "$QQ_VM_TYPE" in
    vz|krunkit) ;;
    *) die "--vm-type must be vz or krunkit (got '$QQ_VM_TYPE')" ;;
esac

if [ "$QQ_PKG" = "local" ]; then
    [ -n "$QQ_PKG_PATH" ] || die "--pkg local needs --pkg-path <file.deb>"
    # Resolve against the invoking directory, not the project directory.
    case "$QQ_PKG_PATH" in
        /*) : ;;
        *)  QQ_PKG_PATH="${INVOKE_DIR}/${QQ_PKG_PATH#./}" ;;
    esac
    [ -f "$QQ_PKG_PATH" ] || die "no such file: $QQ_PKG_PATH"
    case "$QQ_PKG_PATH" in
        *.deb) ;;
        *) die "--pkg-path must be a .deb file (got '$QQ_PKG_PATH')" ;;
    esac
fi

# ---------------------------------------------------------------------------
# derive arch from a local .deb when possible
# ---------------------------------------------------------------------------
# dpkg-deb is not on macOS, and macOS `ar` cannot extract the trailing-slash
# member names that real Debian packages use (it errors with "No such file or
# directory"), so we read the ar container ourselves. A .deb is:
#
#     "!<arch>\n" then members of [16-byte name][12 mtime][6 uid][6 gid]
#     [8 mode][10 size][2 magic] followed by `size` bytes, padded to even.
#
# We only need the control tarball; perl is already a dependency of this
# project's Wayland transport, and doing it here avoids both `ar` and any
# assumption about which compressor was used.
deb_control_member() {
    perl -e '
        my $f = shift; open(my $fh, "<", $f) or exit 1; binmode($fh);
        read($fh, my $magic, 8) == 8 or exit 1;
        exit 1 unless $magic eq "!<arch>\n";
        my $out = shift; open(my $ofh, ">", $out) or exit 1; binmode($ofh);
        while (read($fh, my $hdr, 60) == 60) {
            my ($name, $size) = (substr($hdr,0,16), substr($hdr,48,10));
            $name =~ s/\s+$//; $name =~ s{/$}{};
            $size =~ s/\s+$//; $size = int($size);
            my $data = "";
            read($fh, $data, $size) if $size > 0;
            print $ofh $data if $name =~ /^control\.tar/;
            seek($fh, 1, 1) if $size % 2;
        }
    ' "$1" "$2"
}

deb_arch() {
    local deb="$1" tmp member control cpath
    # Resolve to an absolute path: we cd into a temp dir, so a relative path
    # handed in by the user would otherwise resolve against the wrong place.
    case "$deb" in
        /*) : ;;
        *)  deb="$(cd "$(dirname "$deb")" 2>/dev/null && pwd)/$(basename "$deb")" ;;
    esac
    [ -f "$deb" ] || return 1

    tmp="$(mktemp -d)" || return 1
    member="$tmp/control.tar"
    if ! deb_control_member "$deb" "$member" || [ ! -s "$member" ]; then
        rm -rf "$tmp"; return 1
    fi

    # The control file is at ./control or ./DEBIAN/control depending on how the
    # package was built; extract the (tiny) tarball and locate it rather than
    # guessing the member path. tar auto-detects gzip/xz, zstd needs a flag.
    mkdir -p "$tmp/ext"
    if tar -xf "$member" -C "$tmp/ext" 2>/dev/null \
        || tar --zstd -xf "$member" -C "$tmp/ext" 2>/dev/null; then
        cpath="$(find "$tmp/ext" -name control -type f 2>/dev/null | head -1)"
        [ -n "$cpath" ] && control="$(cat "$cpath" 2>/dev/null)"
    fi

    rm -rf "$tmp"
    [ -n "$control" ] || return 1
    printf '%s\n' "$control" | sed -n 's/^Architecture: *//p' | head -1 | tr -d '\r'
}

if [ "$QQ_PKG" = "local" ]; then
    a="$(deb_arch "$QQ_PKG_PATH" || true)"
    case "$a" in
        amd64|arm64)
            if [ "$a" != "$QQ_ARCH" ]; then
                warn "local package says Architecture=$a but --arch=$QQ_ARCH; following the package"
                QQ_ARCH="$a"
            else
                step "local package architecture: $a (matches --arch)"
            fi
            ;;
        "")
            warn "could not read Architecture from $QQ_PKG_PATH; trusting --arch=$QQ_ARCH"
            ;;
        *)
            die "local package architecture '$a' is not amd64/arm64"
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# derive Rosetta
# ---------------------------------------------------------------------------
# Apple's vz backend (used by both `container` and lima's default driver) has
# no native cross-arch execution: an amd64 guest is only possible *because*
# Rosetta translates it. So for vz the rule is mechanical:
#
#     amd64 guest  -> Rosetta REQUIRED
#     arm64 guest  -> Rosetta REFUSED (it would never be used)
#
# krunkit does not implement Rosetta at all, so an amd64 guest is simply
# impossible there -- fail early with an explanation instead of a cryptic
# boot error.
os_arch="$(uname -m)"
rosetta_auto=""
case "$QQ_RUNTIME:$QQ_VM_TYPE:$QQ_ARCH" in
    *:krunkit:amd64)
        die "krunkit cannot run an amd64 guest on this host:
       Apple's krunkit (libkrun) has no Rosetta support, so there is no way to
       translate x86_64. Use --arch arm64 with --runtime lima --vm-type krunkit,
       or drop --vm-type krunkit to get the vz driver (which does support it)." ;;
    *:krunkit:arm64) rosetta_auto=0 ;;
    *:vz:amd64)      rosetta_auto=1 ;;
    *:vz:arm64)      rosetta_auto=0 ;;
esac

# `container` is always vz underneath (there is no other backend), except that
# it has no VM-type knob at all -- so ignore QQ_VM_TYPE in that case.
if [ "$QQ_RUNTIME" = "container" ]; then
    case "$QQ_ARCH" in
        amd64) rosetta_auto=1 ;;
        arm64) rosetta_auto=0 ;;
    esac
fi

if [ -n "$QQ_ROSETTA" ]; then
    if [ "$QQ_ROSETTA" = "1" ] && [ "$rosetta_auto" = "0" ]; then
        if [ "$QQ_ARCH" = "arm64" ]; then
            die "--rosetta given but the guest is arm64; Rosetta only translates
       foreign-arch binaries, so it would sit unused. Drop --rosetta (or use
       --arch amd64 if translation is what you actually want)."
        fi
    fi
    if [ "$QQ_ROSETTA" = "0" ] && [ "$rosetta_auto" = "1" ] && [ "$QQ_VM_TYPE" = "vz" ]; then
        die "--no-rosetta given but the guest is amd64 on the vz backend.
       vz cannot execute a foreign architecture without Rosetta, so this
       combination cannot boot. Use --arch arm64, or allow Rosetta."
    fi
else
    QQ_ROSETTA="$rosetta_auto"
fi

# ---------------------------------------------------------------------------
# derived names / urls
# ---------------------------------------------------------------------------
case "$QQ_ARCH" in
    amd64) qq_deb_arch=amd64; qq_url="$LINUXQQ_URL_AMD64"; qq_sha="$LINUXQQ_SHA_AMD64" ;;
    arm64) qq_deb_arch=arm64; qq_url="$LINUXQQ_URL_ARM64"; qq_sha="$LINUXQQ_SHA_ARM64" ;;
esac

# Default image tag / container name carry the arch, so a container and a
# lima session for different architectures never collide.
[ -n "$QQ_IMAGE" ] || QQ_IMAGE="mac-qq-docker:${QQ_ARCH}"
if [ -z "$QQ_NAME" ]; then
    case "$QQ_RUNTIME:$QQ_DISPLAY" in
        container:wayland) QQ_NAME="qq-${QQ_ARCH}-wayland" ;;
        container:x11)     QQ_NAME="qq-${QQ_ARCH}-x11" ;;
        lima:*)            QQ_NAME="qq-limavm-${QQ_ARCH}" ;;
    esac
fi

PLATFORM="linux/${QQ_ARCH}"

# The VM architecture and the container architecture are NOT the same question,
# and lima spells neither of them the way docker does:
#
#   * limactl --arch takes x86_64 / aarch64 (docker says amd64 / arm64).
#   * vz cannot run a cross-architecture guest at all -- `limactl create
#     --arch x86_64` fails outright with "unsupported arch". So EVERY lima VM
#     on this host is aarch64; an amd64 QQ is an amd64 *container* inside an
#     aarch64 VM, translated by Rosetta. That is exactly how Apple `container`
#     behaves too, which is why both runtimes share QQ_ROSETTA.
#
# VM_ARCH is what limactl is told; the container inside is always built for
# $QQ_ARCH. CONTAINER_ARCH is kept for messages and the Apple `container` path,
# which DOES accept a real cross-arch guest.
CONTAINER_ARCH="$QQ_ARCH"
LIMACTL_ARCH=aarch64
if [ "$QQ_VM_TYPE" = "krunkit" ] && [ "$QQ_ARCH" != "arm64" ]; then
    # Unreachable (validated earlier), but never hand krunkit an amd64 wish.
    die "internal: krunkit cannot host $QQ_ARCH"
fi

# ---------------------------------------------------------------------------
# plan output
# ---------------------------------------------------------------------------
rosetta_txt="no"
[ "$QQ_ROSETTA" = "1" ] && rosetta_txt="yes (required for amd64 on vz)"

printf '\n%s%s%s\n' "$c_bold" "QQ launch plan" "$c_reset" >&2
printf '  runtime   : %s%s\n' "$QQ_RUNTIME" \
    "$([ "$QQ_RUNTIME" = lima ] && printf ' (vm-type=%s, os=%s)' "$QQ_VM_TYPE" "$QQ_LIMA_OS")" >&2
printf '  display   : %s\n' "$QQ_DISPLAY" >&2
printf '  arch      : %s (%s)\n' "$QQ_ARCH" "$PLATFORM" >&2
printf '  rosetta   : %s\n' "$rosetta_txt" >&2
printf '  package   : %s\n' "$QQ_PKG" >&2
case "$QQ_PKG" in
    url)   printf '              %s\n' "$qq_url" >&2 ;;
    local) printf '              %s\n' "$QQ_PKG_PATH" >&2 ;;
    apt)   printf '              distro repo (linuxqq)\n' >&2 ;;
esac
printf '  image     : %s\n' "$QQ_IMAGE" >&2
printf '  name      : %s\n' "$QQ_NAME" >&2
printf '  resources : %s cpus, %s ram, %s shm\n' "$QQ_CPUS" "$QQ_MEMORY" "$QQ_SHM_SIZE" >&2
printf '  ime       : %s\n' "$([ "$QQ_ENABLE_IME" = 1 ] && echo on || echo off)" >&2
printf '\n' >&2

# ---------------------------------------------------------------------------
# uninstall
#
# Reverses everything this project creates, newest-first, and is deliberately
# conservative: it only removes things it can prove belong to this project, and
# it never touches the shared tooling (Cocoa-Way, waypipe, XQuartz, Homebrew).
#
# Artefacts, and why each needs its own step:
#   1. the Cocoa-Way session -- only cocoa-wayctl can end it; killing the
#      container behind its back leaves the session believing it still runs.
#      It cannot be removed from the config file alone either, because
#      Cocoa-Way may be holding it in memory.
#   2. the container(s) it owns, named cocoa-way-<session>. A bare
#      `container delete qq-amd64-wayland` misses them entirely.
#   3. the images, for every arch this project tags (mac-qq-docker:amd64,
#      :arm64, :latest).
#   4. the generated [[session]] block in container-sessions.toml.
#   5. scratch state under /tmp (transport sockets, logs, the legacy
#      cocoa-way-qq runtime dir).
#
# ./QQ and ./shared are USER DATA (chat history, downloads) -- 488MB and 179MB
# on this machine -- so they survive unless --purge is explicit.
# ---------------------------------------------------------------------------
do_uninstall() {
    printf '%s==> uninstalling Linux QQ (project artefacts only)%s\n' "$c_bold" "$c_reset" >&2

    local sessions session container_name

    # --- 1. Cocoa-Way sessions -------------------------------------------
    # Ask Cocoa-Way which sessions exist rather than trusting $QQ_NAME: the
    # launcher names them after the arch (qq-amd64-wayland), so guessing the
    # default name silently leaves the real session running.
    local cwctl=""
    command -v cocoa-wayctl >/dev/null 2>&1 && cwctl="$(command -v cocoa-wayctl)"

    if [ -n "$cwctl" ]; then
        sessions="$("$cwctl" --json applications 2>/dev/null \
            | tr ',' '\n' \
            | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' \
            | grep '^qq' | sort -u || true)"
        # Also honour an explicitly requested name, in case the session is
        # tracked but not currently listed as an application.
        case " $sessions " in
            *" $QQ_NAME "*) ;;
            *) sessions="$sessions
$QQ_NAME" ;;
        esac

        for session in $sessions; do
            [ -n "$session" ] || continue
            if "$cwctl" --json stop "$session" >/dev/null 2>&1; then
                step "stopped Cocoa-Way session '$session'"
            fi
        done
    else
        warn "cocoa-wayctl not found; skipping session shutdown"
    fi

    # --- 2. containers ----------------------------------------------------
    # Both the bare name (X11 / lima paths) and cocoa-way-<name> (Wayland).
    if command -v container >/dev/null 2>&1; then
        for container_name in $(container list -a --format '{{.Names}}' 2>/dev/null \
                                | grep -E "^(cocoa-way-)?${QQ_NAME}$" || true); do
            container stop "$container_name" >/dev/null 2>&1 || true
            if container delete "$container_name" >/dev/null 2>&1; then
                step "removed container '$container_name'"
            else
                warn "could not remove container '$container_name'"
            fi
        done
        # Any other QQ container Cocoa-Way may have left behind.
        for container_name in $(container list -a --format '{{.Names}}' 2>/dev/null \
                                | grep -E '^(cocoa-way-)?qq-' || true); do
            container stop "$container_name" >/dev/null 2>&1 || true
            container delete "$container_name" >/dev/null 2>&1 \
                && step "removed leftover container '$container_name'"
        done

        # --- 3. images ---------------------------------------------------
        local img
        for img in "mac-qq-docker:amd64" "mac-qq-docker:arm64" "mac-qq-docker:latest"; do
            if container image list 2>/dev/null | grep -q "${img%%:*}"; then
                if container image delete "$img" >/dev/null 2>&1; then
                    step "removed image '$img'"
                fi
            fi
        done
    fi

    # --- 4. the generated session block ----------------------------------
    local cfg="$HOME/.config/cocoa-way/container-sessions.toml"
    if [ -f "$cfg" ]; then
        local py=""
        for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
            [ -x "$cand" ] && "$cand" -c 'import tomllib' 2>/dev/null && { py="$cand"; break; }
        done
        if [ -n "$py" ]; then
            if "$py" - "$cfg" "$QQ_NAME" <<'PY'
import re, sys
path, name = sys.argv[1], sys.argv[2]
import tomllib  # noqa: F401  (proves this interpreter can parse TOML)
src = open(path, encoding="utf-8").read()
blocks = re.split(r'(?m)^(?=\[\[session\]\])', src)
out, removed = [], 0
for b in blocks:
    if b.startswith("[[session]]") and re.search(r'(?m)^name\s*=\s*"%s"\s*$' % re.escape(name), b):
        removed += 1
        continue
    out.append(b)
if removed:
    open(path, "w", encoding="utf-8").write("".join(out))
sys.exit(0 if removed else 1)
PY
            then
                step "removed [[session]] '$QQ_NAME' from container-sessions.toml"
            fi
        else
            warn "no python3 with tomllib; leaving $cfg untouched"
        fi
    fi

    # --- 5. scratch state -------------------------------------------------
    rm -rf /tmp/cocoa-way-qq 2>/dev/null && step "removed /tmp/cocoa-way-qq"
    # Only our own transport dirs; a bare /tmp/cw-* would hit other tooling.
    rm -rf /tmp/cw-501-* 2>/dev/null || true

    # --- 6. user data (opt-in) --------------------------------------------
    if [ "$QQ_PURGE" = "1" ]; then
        for d in "$PROJECT_DIR/QQ" "$PROJECT_DIR/shared"; do
            if [ -e "$d" ]; then
                rm -rf "$d" && step "purged $d"
            fi
        done
        rm -f "$PROJECT_DIR/.env" "$PROJECT_DIR/.x11-cookie" 2>/dev/null || true
        rm -rf "$PROJECT_DIR/.x11-auth" 2>/dev/null || true
    else
        printf '\n  kept user data: %s (%s) and %s (%s)\n' \
            "$PROJECT_DIR/QQ" "$(du -sh "$PROJECT_DIR/QQ" 2>/dev/null | cut -f1)" \
            "$PROJECT_DIR/shared" "$(du -sh "$PROJECT_DIR/shared" 2>/dev/null | cut -f1)" >&2
        printf '  add --purge to delete them too\n' >&2
    fi

    printf '\n%s==> uninstall complete%s\n' "$c_bold" "$c_reset" >&2
}

if [ "$QQ_PURGE" = "1" ] && [ "$QQ_UNINSTALL" != "1" ]; then
    die "--purge only makes sense together with --uninstall"
fi

if [ "$QQ_UNINSTALL" = "1" ]; then
    if [ "$QQ_DRY_RUN" = "1" ]; then
        # --dry-run must stay side-effect free, so list what would go instead
        # of removing it.
        info "dry run: would uninstall"
        printf '  stop and forget Cocoa-Way session(s) matching qq*\n' >&2
        printf '  remove containers matching (cocoa-way-)qq*\n' >&2
        printf '  remove images mac-qq-docker:{amd64,arm64,latest}\n' >&2
        printf '  remove the [[session]] block for %s from container-sessions.toml\n' "$QQ_NAME" >&2
        printf '  remove /tmp/cocoa-way-qq and /tmp/cw-501-*\n' >&2
        if [ "$QQ_PURGE" = "1" ]; then
            printf '  purge ./QQ and ./shared (user data)\n' >&2
        else
            printf '  keep ./QQ and ./shared (pass --purge to delete)\n' >&2
        fi
        exit 0
    fi
    do_uninstall
    exit 0
fi

if [ "$QQ_DRY_RUN" = "1" ]; then
    info "dry run: not launching"
    exit 0
fi

# ---------------------------------------------------------------------------
# preflight: the chosen runtime must exist
# ---------------------------------------------------------------------------
need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

# ---------------------------------------------------------------------------
# build the image
# ---------------------------------------------------------------------------
# The Dockerfile takes the package location as build args, so all three
# package modes funnel through here. For `local` we stage the .deb next to the
# Dockerfile under a fixed name so the build context stays small and the
# cache key is stable.
build_image() {
    local dockerfile="Dockerfile" build_args=() stage_deb=""

    info "building $QQ_IMAGE for $PLATFORM"

    # Exactly one source argument is passed, so the Dockerfile never has to
    # guess (and can never silently fall back to the distro package).
    build_args+=(--build-arg "LINUXQQ_SOURCE=$QQ_PKG")
    case "$QQ_PKG" in
        url)
            build_args+=(--build-arg "LINUXQQ_URL=$qq_url")
            build_args+=(--build-arg "LINUXQQ_SHA512=$qq_sha")
            ;;
        local)
            stage_deb="qq-local-package.deb"
            cp -f "$QQ_PKG_PATH" "$PROJECT_DIR/$stage_deb"
            ;;
        apt)
            : # nothing extra; LINUXQQ_SOURCE=apt is the whole instruction
            ;;
    esac

    # Docker's COPY fails when a glob matches nothing, so a zero-byte
    # placeholder is always staged. The Dockerfile filters out empty files, so
    # this can never be mistaken for a real package.
    [ -f "$PROJECT_DIR/qq-local-package.deb" ] || : > "$PROJECT_DIR/qq-local-package.deb"

    local rc=0
    case "$QQ_RUNTIME" in
        container)
            build_args+=(--arch "$QQ_ARCH" --platform "$PLATFORM")
            container build "${build_args[@]}" \
                --build-arg "USER_ID=$(id -u)" \
                --build-arg "GROUP_ID=$(id -g)" \
                -t "$QQ_IMAGE" -f "$dockerfile" . || rc=$?
            ;;
        lima)
            # Inside the VM, build with the guest's own engine. Podman is what
            # the lima debian template ships, and it can build a Dockerfile.
            lima_build "$stage_deb" || rc=$?
            ;;
    esac
    [ -n "$stage_deb" ] && rm -f "$PROJECT_DIR/$stage_deb"
    rm -f "$PROJECT_DIR/qq-local-package.deb"

    # Keep mac-qq-docker:latest in step with the image we just built.
    #
    # :latest is not built here -- it is the tag produced by the older
    # ./build.sh, and it is what ~/.config/cocoa-way/container-sessions.toml
    # names as the session image, so `cocoa-wayctl launch QQ` runs it. That
    # made it possible for the Cocoa-Way path to keep working while qq.sh was
    # fixed, and then to silently run months-old code after the fact.
    #
    # It stays amd64-only, because that session passes --arch amd64
    # --platform linux/amd64: re-pointing the tag at an arm64 build would
    # make Cocoa-Way fail with "platform linux/arm64". So only retag when the
    # build we just did is the amd64 one, and never move an existing amd64
    # tag onto a different architecture.
    if [ $rc -eq 0 ] && [ "$QQ_RUNTIME" = "container" ]; then
        if [ "$QQ_ARCH" = "amd64" ]; then
            container image tag "$QQ_IMAGE" mac-qq-docker:latest >/dev/null 2>&1 \
                && info "tagged mac-qq-docker:latest -> $QQ_IMAGE" \
                || warn "could not re-tag mac-qq-docker:latest (cocoa-way sessions may run a stale image)"
        else
            info "not re-tagging mac-qq-docker:latest: it is pinned to amd64 for the Cocoa-Way session"
        fi
    fi

    return $rc
}

# ---------------------------------------------------------------------------
# lima plumbing
# ---------------------------------------------------------------------------
# lima gives us a whole Linux VM, not a container runtime, so "running QQ"
# means: make sure the VM exists, then run the same container inside it. The
# VM is where the architecture question is settled; the container inside is
# always native to that VM (so no nested Rosetta, no --rosetta on the inner
# engine).
lima_instance() { printf '%s' "$QQ_NAME"; }

# Emit a shell fragment (to be eval'd inside the guest) that applies the proxy
# policy. Everything runs through it so the build and the engine install agree.
lima_proxy_prelude() {
    case "$QQ_PROXY" in
        "")   # inherit: leave whatever lima injected alone
             printf '%s' ':' ;;
        off) printf '%s' 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; \
                          printf "Acquire::http::Proxy \\\"\\\";\\nAcquire::https::Proxy \\\"\\\";\\n" > /etc/apt/apt.conf.d/99qq-proxy 2>/dev/null || true' ;;
        *)   printf '%s' "export http_proxy='$QQ_PROXY' https_proxy='$QQ_PROXY' HTTP_PROXY='$QQ_PROXY' HTTPS_PROXY='$QQ_PROXY'" ;;
    esac
}

# debian-12 ships neither podman nor docker, and a fresh template has no engine.
# Both are in the guest's own repos. podman is preferred (rootless, no daemon),
# and it is also what `nerdctl`-free templates usually document.
#
# Must run as root inside the guest: limactl shell is passwordless sudo-capable
# but apt itself needs root.
lima_ensure_engine() {
    local inst="$1"
    if limactl shell "$inst" -- bash -lc 'command -v podman || command -v docker' \
         >/dev/null 2>&1; then
        return 0
    fi
    info "installing a container engine inside lima VM '$inst' (podman)"
    limactl shell "$inst" -- sudo bash -lc '
            set -eux
            export DEBIAN_FRONTEND=noninteractive
            '"$(lima_proxy_prelude)"'
            apt-get update
            apt-get install -y --no-install-recommends podman uidmap slirp4netns fuse-overlayfs
        ' </dev/null || die "could not install podman inside lima VM '$inst'"
    limactl shell "$inst" -- bash -lc 'command -v podman' >/dev/null 2>&1 \
        || die "podman is still missing inside lima VM '$inst'"
}

# limactl wants --memory as a bare number of GiB ("--memory float32  Memory in
# GiB"), not the docker-style "4g" that --memory uses everywhere else, and
# --cpus as a plain integer. Normalise here so one user-facing value works for
# both runtimes.
lima_memory_gib() {
    local m="$1"
    case "$m" in
        *[Gg][Ii][Bb]) printf '%s' "${m%???}" ;;
        *[Gg][Bb])     printf '%s' "${m%??}"  ;;
        *[Gg])         printf '%s' "${m%?}"   ;;
        *[Mm])         # sub-GiB: express as a decimal fraction of a GiB
                       printf '%s' "$(awk -v v="${m%?}" 'BEGIN{printf "%.3f", v/1024}')" ;;
        *)             printf '%s' "$m" ;;
    esac
}

lima_ensure_vm() {
    need limactl "Install with: brew install lima"
    local inst; inst="$(lima_instance)"

    if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$inst"; then
        local status
        status="$(limactl list --format '{{.Status}}' "$inst" 2>/dev/null || echo Unknown)"
        if [ "$status" != "Running" ]; then
            info "starting lima VM '$inst'"
            limactl start "$inst" </dev/null \
                || die "failed to start lima VM '$inst' (see: limactl info '$inst')"
        else
            step "lima VM '$inst' already running"
        fi
        return 0
    fi

    local mem_gib; mem_gib="$(lima_memory_gib "$QQ_MEMORY")"
    info "creating lima VM '$inst' ($QQ_VM_TYPE, $LIMACTL_ARCH, $QQ_LIMA_OS, ${QQ_CPUS} cpu, ${mem_gib}GiB)"
    local tmpl_args=(
        --name="$inst"
        --vm-type="$QQ_VM_TYPE"
        --arch="$LIMACTL_ARCH"
        --cpus="$QQ_CPUS"
        --memory="$mem_gib"
        --tty=false
    )
    # Rosetta is a property of the VM (vz only), not of the workload: the VM is
    # aarch64 and Rosetta is what lets an amd64 container run inside it. An
    # arm64 container needs no translation, so it is not requested.
    [ "$QQ_ROSETTA" = "1" ] && tmpl_args+=(--rosetta)

    # The template MUST carry the `template:` prefix. Without it the word is
    # read as an instance name, limactl rejects `--name` + instance name, and
    # the flags above are silently dropped -- producing a default aarch64 VM
    # that looks like `--arch`/`--memory` were ignored.
    local tmpl="$QQ_LIMA_OS"
    case "$tmpl" in
        *:*) : ;;                 # already qualified (template:foo, ./file.yaml)
        *.yaml|*.yml|/*) : ;;     # a path
        *) tmpl="template:$tmpl" ;;
    esac

    # A failed create must stop the whole run: without this the very next step
    # reports the confusing "instance `...` does not exist" instead of the
    # real cause.
    limactl start "${tmpl_args[@]}" "$tmpl" </dev/null \
        || die "failed to create lima VM '$inst' (try: limactl start --vm-type=$QQ_VM_TYPE --arch=$LIMACTL_ARCH $tmpl)"
}

lima_build() {
    local stage_deb="$1"
    lima_ensure_vm
    local inst; inst="$(lima_instance)"
    lima_ensure_engine "$inst"

    info "building $QQ_IMAGE inside lima VM '$inst'"
    # Ship the context in and build there. tar over ssh is the portable option
    # (the 9p/virtiofs mount of the project dir may be read-only).
    #
    # COPYFILE_DISABLE=1 stops bsdtar from writing AppleDouble `._name`
    # sidecars; the Dockerfile also filters them, but not creating them keeps
    # the 200 MB .deb from being accompanied by junk.
    COPYFILE_DISABLE=1 tar --no-mac-metadata -cf - \
        --exclude .git --exclude QQ --exclude shared \
        $stage_deb Dockerfile entrypoint.sh qq-wrapper.sh 2>/dev/null \
      | limactl shell "$inst" -- bash -lc '
            set -euo pipefail
            '"$(lima_proxy_prelude)"'
            rm -rf /tmp/qq-build && mkdir -p /tmp/qq-build && cd /tmp/qq-build
            tar -xf -
            engine=podman; command -v $engine >/dev/null 2>&1 || engine=docker
            # The VM already has the wanted architecture (lima refuses to make
            # a cross-arch VM), so the inner image is built for the guest arch
            # and never needs Rosetta.
            arch="$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)"
            $engine build --arch "$arch" \
                --build-arg USER_ID='"$(id -u)"' \
                --build-arg GROUP_ID='"$(id -g)"' \
                --build-arg LINUXQQ_SOURCE='"$QQ_PKG"' \
                --build-arg LINUXQQ_URL='"$qq_url"' \
                --build-arg LINUXQQ_SHA512='"$qq_sha"' \
                -t '"$QQ_IMAGE"' -f Dockerfile .
        ' \
        || die "build failed inside lima VM '$inst'"
}

lima_run() {
    lima_ensure_vm
    local inst; inst="$(lima_instance)"
    lima_ensure_engine "$inst"

    # The VM's ssh port is forwarded to the host, so X11 can simply point at
    # 127.0.0.1 on the guest and the host-side XQuartz sees a normal client.
    local display_env=() inner_cmd
    if [ "$QQ_DISPLAY" = "x11" ]; then
        display_env+=(--env QQ_DISPLAY_BACKEND=x11)
        display_env+=(--env DISPLAY="${QQ_X11_HOST:-host.lima.internal}:0")
        inner_cmd="/home/user/qq-wrapper.sh"
    else
        die "lima + wayland is not wired up yet.
       Cocoa-Way's transport is specific to Apple \`container\`'s published
       socket, which lima does not provide. Use --display x11 for lima, or
       --runtime container for the Wayland path."
    fi

    info "starting QQ in lima VM '$inst' (container '$QQ_NAME')"
    limactl shell "$inst" -- bash -lc "
        set -euo pipefail
        engine=podman; command -v \$engine >/dev/null 2>&1 || engine=docker
        \$engine rm -f '$QQ_NAME' >/dev/null 2>&1 || true
        mkdir -p /tmp/qq-config /tmp/qq-shared
        \$engine run --rm --name '$QQ_NAME' \
            -e QQ_DISPLAY_BACKEND=$(printf %q "$QQ_DISPLAY") \
            -e QQ_ENABLE_IME=$QQ_ENABLE_IME \
            -e QQ_EXTRA_ARGS=$(printf %q "$QQ_EXTRA_ARGS") \
            -e TZ=$(printf %q "$QQ_TZ") \
            -e LANG=zh_CN.UTF-8 \
            -v /tmp/qq-config:/home/user/.config/QQ \
            -v /tmp/qq-shared:/home/user/shared \
            --cap-drop ALL \
            $(printf '%s ' "${display_env[@]}") \
            '$QQ_IMAGE' ${inner_cmd}
    "
}

# ---------------------------------------------------------------------------
# container (Apple) plumbing
# ---------------------------------------------------------------------------
container_ensure_service() {
    if ! container system status >/dev/null 2>&1; then
        info "starting Apple container service"
        container system start --enable-kernel-install </dev/null
    fi
}

container_run() {
    need container "Install Apple's container CLI: https://apple.github.io/container/"
    container_ensure_service

    if ! container image list 2>/dev/null | grep -q "${QQ_IMAGE%%:*}"; then
        die "image '$QQ_IMAGE' not found. Build it first:  ./$SELF --build"
    fi

    # ---- display-specific preflight / wiring ------------------------------
    local run_args=() x11_mounts=() backend_cmd="/home/user/qq-wrapper.sh"

    if [ "$QQ_DISPLAY" = "wayland" ]; then
        need cocoa-way "Install with: brew tap J-x-Z/tap && brew install cocoa-way"
        need waypipe   "Install with: brew install J-x-Z/tap/waypipe-darwin"
        exec "$PROJECT_DIR/wayland-launch.sh" \
            --name "$QQ_NAME" --image "$QQ_IMAGE" --arch "$QQ_ARCH" \
            --cpus "$QQ_CPUS" --memory "$QQ_MEMORY" --shm-size "$QQ_SHM_SIZE" \
            --ime "$QQ_ENABLE_IME" --extra-args "$QQ_EXTRA_ARGS"
    fi

    # X11: XQuartz must be listening on TCP, and we pass an authenticated
    # cookie rather than resorting to the world-readable `xhost +`.
    local x11_port="${X11_PORT:-6000}"
    if ! nc -z 127.0.0.1 "$x11_port" 2>/dev/null; then
        die "no X server on 127.0.0.1:${x11_port}. Run:  ./x11-setup.sh"
    fi
    local x11_auth_dir="$PROJECT_DIR/.x11-auth"
    mkdir -p "$x11_auth_dir"
    if [ -f "$PROJECT_DIR/.x11-cookie" ]; then
        cp "$PROJECT_DIR/.x11-cookie" "$x11_auth_dir/.x11-cookie"
    else
        warn ".x11-cookie missing; run ./x11-setup.sh for authenticated X11"
    fi
    x11_mounts+=(--mount "type=bind,source=${x11_auth_dir},target=/home/user/.x11-auth,readonly")

    # ---- container lifecycle ---------------------------------------------
    if container list -a --format '{{.Names}}' 2>/dev/null | grep -qx "$QQ_NAME"; then
        step "removing previous container '$QQ_NAME'"
        container stop "$QQ_NAME" >/dev/null 2>&1 || true
        container delete "$QQ_NAME" >/dev/null 2>&1 || true
    fi

    mkdir -p "$PROJECT_DIR/QQ" "$PROJECT_DIR/shared"

    run_args+=(
        --name "$QQ_NAME"
        --arch "$QQ_ARCH" --platform "$PLATFORM"
        --detach
        --cpus "$QQ_CPUS"
        --memory "$QQ_MEMORY"
        --shm-size "$QQ_SHM_SIZE"
        --uid "$(id -u)" --gid "$(id -g)"
        --env "QQ_DISPLAY_BACKEND=x11"
        --env "HOST_GATEWAY=${HOST_GATEWAY:-192.168.64.1}"
        --env "X11_PORT=$x11_port"
        --env "QQ_ENABLE_IME=$QQ_ENABLE_IME"
        --env "QQ_EXTRA_ARGS=$QQ_EXTRA_ARGS"
        --env "TZ=$QQ_TZ"
        --env LANG=zh_CN.UTF-8
        --env GTK_IM_MODULE=fcitx
        --env XMODIFIERS=@im=fcitx
        --mount "type=bind,source=${PROJECT_DIR}/QQ,target=/home/user/.config/QQ"
        --mount "type=bind,source=${PROJECT_DIR}/shared,target=/home/user/shared"
        --cap-drop ALL
        --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
        --cap-add SETUID --cap-add SETGID --cap-add KILL
    )
    # Rosetta is a hard requirement for amd64 here, not a preference.
    [ "$QQ_ROSETTA" = "1" ] && run_args+=(--rosetta)
    run_args+=("${x11_mounts[@]}")
    run_args+=("$QQ_IMAGE" "$backend_cmd")

    info "starting container '$QQ_NAME'"
    set -- "${run_args[@]}"
    set -x
    container run "$@"
    set +x

    cat <<EOF

QQ started (X11).

  container : $QQ_NAME
  image     : $QQ_IMAGE
  display   : ${HOST_GATEWAY:-192.168.64.1}:${x11_port}
  logs      : ./logs.sh
  stop      : ./stop.sh

EOF
}

# ---------------------------------------------------------------------------
# go
# ---------------------------------------------------------------------------
if [ "$QQ_BUILD" = "1" ]; then
    build_image
fi

case "$QQ_RUNTIME" in
    container) container_run ;;
    lima)      lima_run ;;
esac
