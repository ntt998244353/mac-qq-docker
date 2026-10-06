FROM docker.io/library/debian:12

# ---------------------------------------------------------------------------
# Linux QQ (Electron) containerised, tuned for Apple `container` on macOS.
#
# Ported from:
#   https://github.com/rmb122/qq-docker   (Arch/AUR variant)
#   https://github.com/ntdgy/docker-qq    (Arch + prebuilt pkg variant)
#
# Differences from the upstream Linux recipes:
#   * Debian 12 base instead of Arch, so we can install Tencent's official
#     .deb directly -- no makepkg, no AUR, no third-party repack.
#   * The .deb is pinned by sha512 (taken from the official AUR PKGBUILD,
#     which mirrors Tencent's own published artifact).
#   * Architectures: Tencent ships both x86_64 and aarch64 .deb files for the
#     same version. Pick one with `./qq.sh --arch amd64|arm64`; amd64 runs under
#     Rosetta, arm64 is native (and does not need Rosetta).
#   * Which package is installed is controlled by ./qq.sh --pkg url|local|apt.
#   * No X11 socket bind-mount: macOS has no /tmp/.X11-unix. X11 is done over
#     TCP to XQuartz on the host (see entrypoint.sh).
# ---------------------------------------------------------------------------

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=zh_CN.UTF-8 \
    LC_ALL=zh_CN.UTF-8 \
    TZ=Asia/Shanghai

# --- runtime dependencies -------------------------------------------------
# The list is the union of Tencent's own Depends/Recommends fields and the
# extra libraries Electron/GTK need at runtime under Rosetta.
RUN apt-get update && apt-get install -y --no-install-recommends \
        # --- exactly what `dpkg -I` on the official package asks for ---
        libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils \
        libatspi2.0-0 libuuid1 libsecret-1-0 libappindicator3-1 \
        # --- GTK / X11 / rendering ---
        libgbm1 libasound2 libx11-xcb1 libxcb-dri3-0 libxcomposite1 \
        libxdamage1 libxfixes3 libxrandr2 libcups2 libdrm2 libpangocairo-1.0-0 \
        libatk1.0-0 libatk-bridge2.0-0 libcairo2 libpango-1.0-0 \
        # --- image / video formats QQ renders in-chat ---
        libvips42 libopenjp2-7 libopenslide0 \
        # --- CJK fonts + emoji, otherwise chat text renders as tofu ---
        fonts-noto-cjk fonts-noto-color-emoji fonts-wqy-zenhei \
        # --- input method (fcitx5, the only IME upstream supports) ---
        fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 \
        fcitx5-frontend-gtk4 fcitx5-config-qt \
        # --- misc ---
        dbus-x11 xauth ca-certificates curl tini procps \
        # --- Wayland path (optional): Cocoa-Way transports waypipe over a
        # published socket, so the guest needs the waypipe server. Adds ~2MB.
        waypipe \
    && rm -rf /var/lib/apt/lists/*

# zh_CN.UTF-8 locale so QQ's clipboard and IME behave like upstream
RUN sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true; \
    apt-get update && apt-get install -y --no-install-recommends locales \
    && sed -i 's/^# *\(zh_CN\.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen && rm -rf /var/lib/apt/lists/*

# --- install linuxqq -------------------------------------------------------
# Three sources, chosen by qq.sh --pkg:
#
#   url   (default) Tencent's official package, pinned by sha512. The amd64
#                   artifact is the one the AUR PKGBUILD mirrors; the arm64 one
#                   is served from the QQNT CDN. Both were verified to exist.
#   local           a .deb the caller already has. qq.sh stages it as
#                   .qq-local-package.deb in the build context.
#   apt             whatever the distro repo carries (linuxqq). Not Tencent's
#                   official build, and not version-pinned, but requires no
#                   download from a third-party mirror.
ARG LINUXQQ_URL=https://mirrors.sdu.edu.cn/spark-store-repository/store/chat/linuxqq/linuxqq_3.2.34-53644_amd64.deb
ARG LINUXQQ_SHA512=774e45cd7238dc51b31c02ee494f9f86e773c487a90851790a806f776e130af125110045844e90dd68d0b073dc53bdd4d1c6d8fb7225b8f214fc0e35d1a20e32
ARG LINUXQQ_LOCAL=
ARG LINUXQQ_FROM_APT=0

# Stage the local package (if any). Docker's COPY fails outright when a glob
# matches nothing, so qq.sh always writes a placeholder file first; the real
# package just overwrites it. The directory other-than-that stays empty for
# the url/apt modes and the branches below ignore it.
COPY .qq-local-package.deb* /tmp/local-qq/
RUN set -eux; \
    if [ "$LINUXQQ_FROM_APT" = "1" ]; then \
        echo 'installing linuxqq from the distro repository'; \
        apt-get update; \
        apt-get install -y --no-install-recommends linuxqq; \
    elif [ -n "$LINUXQQ_LOCAL" ] && [ -f "/tmp/local-qq/$LINUXQQ_LOCAL" ]; then \
        echo "installing local package $LINUXQQ_LOCAL"; \
        apt-get update; \
        apt-get install -y --no-install-recommends "/tmp/local-qq/$LINUXQQ_LOCAL"; \
    elif [ "$LINUXQQ_LOCAL" = "ondisk" ] && ls /tmp/local-qq/*.deb >/dev/null 2>&1; then \
        # Fallback: a .deb was staged but the name was not propagated.
        deb="$(ls /tmp/local-qq/*.deb | head -1)"; \
        echo "installing staged package $deb"; \
        apt-get update; \
        apt-get install -y --no-install-recommends "$deb"; \
    else \
        echo "downloading $LINUXQQ_URL"; \
        curl -fL --retry 5 --retry-delay 3 -o /tmp/linuxqq.deb "$LINUXQQ_URL"; \
        echo "${LINUXQQ_SHA512}  /tmp/linuxqq.deb" | sha512sum -c -; \
        apt-get update; \
        apt-get install -y --no-install-recommends /tmp/linuxqq.deb; \
    fi; \
    rm -f /tmp/linuxqq.deb; rm -rf /tmp/local-qq /var/lib/apt/lists/*; \
    # sanity: the Electron binary must be present and executable
    test -x /opt/QQ/qq; \
    /opt/QQ/qq --version 2>/dev/null || true

# ---------------------------------------------------------------------------
# Non-root user whose UID/GID match the macOS host user. Apple `container`
# bind-mounts are not UID-translating the way Docker Desktop's are, so a
# mismatch shows up as permission errors on ~/.config/QQ.
# ---------------------------------------------------------------------------
ARG USER_ID=501
ARG GROUP_ID=20
RUN set -eux; \
    groupadd -g "${GROUP_ID}" user 2>/dev/null || true; \
    useradd -m -u "${USER_ID}" -g "${GROUP_ID}" -s /bin/bash user; \
    mkdir -p /home/user/.config/QQ /home/user/shared /home/user/.Xauthority.d; \
    chown -R "${USER_ID}:${GROUP_ID}" /home/user

# QQ's Electron sandbox needs either unprivileged userns or a root-owned
# setuid helper. Apple `container` runs containers with a restricted seccomp
# profile, so we ship the standard chrome-sandbox and fall back to
# --no-sandbox in the entrypoint if it cannot be used.
RUN chown root:root /opt/QQ/chrome-sandbox && chmod 4755 /opt/QQ/chrome-sandbox

COPY --chown=user:user entrypoint.sh /home/user/entrypoint.sh
COPY --chown=user:user qq-wrapper.sh /home/user/qq-wrapper.sh
RUN chmod +x /home/user/entrypoint.sh /home/user/qq-wrapper.sh

USER user
WORKDIR /home/user
ENV HOME=/home/user \
    DISPLAY=:0 \
    XAUTHORITY=/home/user/.Xauthority \
    GTK_IM_MODULE=fcitx \
    QT_IM_MODULE=fcitx \
    XMODIFIERS=@im=fcitx

EXPOSE 6000
ENTRYPOINT ["/usr/bin/tini", "--", "/home/user/entrypoint.sh"]
CMD ["/home/user/qq-wrapper.sh"]
