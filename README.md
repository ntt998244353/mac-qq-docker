# mac-qq-docker

在 macOS 上用 Apple 的 [`container`](https://apple.github.io/container/documentation/)
运行 Linux 版 QQ（Electron / NT 版）。

移植自：

- [rmb122/qq-docker](https://github.com/rmb122/qq-docker) — 最初的 Arch + AUR 方案
- [ntdgy/docker-qq](https://github.com/ntdgy/docker-qq) — 预打包 deb 的改进版

目标是同一套思路（把 QQ 关进容器，聊天记录和共享目录用 bind mount 拿出来），
但把底层从 Docker Desktop 换成 Apple `container`：每个容器是一个独立的轻量虚拟机，
隔离性比 Docker Desktop 的共享 Linux 虚拟机好得多。

---

## 为什么不是简单地把 Dockerfile 搬过来

上游是 Linux（Arch）方案，直接照搬在 macOS 上跑不起来。主要差异：

| 项目 | 上游（Linux + Docker） | 本项目（macOS + Apple container） |
|---|---|---|
| X11 | bind mount `/tmp/.X11-unix` | **macOS 根本没有这个目录**，改用 XQuartz 的 TCP 6000 |
| 网络 | `host` / 自定义 bridge | vmnet，宿主在网关 `192.168.64.1` |
| D-Bus | 挂载宿主的 session bus socket | **容器内起私有 bus**（更安全，见下） |
| 音频 | 挂载宿主 PulseAudio socket | 可选，走 TCP（见「音频」） |
| 架构 | 原生 x86_64 | amd64 镜像 + **Rosetta**（本项目用 x86_64 版；官方也有 arm64 版，见「接入方式说明：Rosetta」） |
| 输入法 | fcitx5 + 宿主 X | fcitx5，但 IME 在容器内（见「输入法」） |
| 打包 | AUR `makepkg` 或第三方仓库 | **腾讯官方 deb + sha512 校验** |

### 关于隔离性：比上游更严格的地方

上游 README 里那段免责声明说得很实在：X11 协议本身允许客户端监听整个键盘，
所以只要 QQ 能画在你的 X server 上，理论上就能记录你的按键。**这一点在 macOS 上同样成立，
本项目无法消除它**。如果这对你不可接受，请用虚拟机跑 QQ，不要用本项目。

在这个前提下，本项目在能力范围内做了这些收紧：

- **不挂载宿主 D-Bus**。上游把宿主的 session bus socket 挂进容器，等于把宿主上每个进程
  都暴露给 QQ。本项目在容器内起一个私有 session bus。
- **`--cap-drop ALL`**，再按需加回 6 个必要 capability（原来 Docker 默认给 14 个）。
- **限制资源**：`--cpus` / `--memory`，上游没做。默认 4 核 / 4G，可用 `QQ_CPUS`、`QQ_MEMORY` 覆盖。
- **内核隔离**：Apple `container` 每个容器一个 VM 和独立内核，而 Docker Desktop 是共享内核。
  容器逃逸的难度不在一个量级。
- **只挂载两个目录**（`QQ/`、`shared/`），宿主文件系统其余部分完全不可见。

QQ 仍然能通过 X11 看到你的输入、以及通过 XQuartz 的剪贴板读写做文章。这是 X11 的固有属性。

---

## 前置要求

- Apple Silicon Mac（M 系列）
- macOS 26 或更新（`container` 要求）
- 已安装 [`container`](https://apple.github.io/container/documentation/)：
  `brew install --cask container`
- 已安装 [XQuartz](https://www.xquartz.org/)：`brew install --cask xquartz`

磁盘空间：镜像约 3GB（Debian + 190MB 的 QQ deb 解包后更大），预留 6–8GB 比较稳。

### 一次性准备

```bash
# 1. 启动 container 服务（第一次会下载 Linux 内核）
container system start

# 2. 装 XQuartz（会要密码），装完【注销重新登录】或重启
brew install --cask xquartz

# 3. 配置 XQuartz（开 TCP + 装 cookie）
./x11-setup.sh

# 4. 构建镜像（约 190MB 下载 + 编译，第一次比较久）
./build.sh

# 5. 生成 .env 并创建目录
./init.sh
```

第 2 步装完后**一般不需要注销**：XQuartz 2.8.6 装完会自己开 TCP 监听，
`x11-setup.sh` 会负责启动它并确认端口通了。如果脚本报「not listening」，
那就注销重登（或重启）一次再跑。

---

## 使用

```bash
./run.sh      # 启动 QQ
./logs.sh     # 看日志
./status.sh   # 查看状态
./shell.sh    # 进容器调试
./stop.sh     # 停止并删除容器
```

### Wayland 模式（推荐，安全）

默认走 X11（XQuartz）。X11 的设计是任何客户端都能读到整个输入流，
所以容器里的 QQ 在原理上可以记录你在宿主上的一切按键。Wayland 没有这个问题：
客户端只能看到自己窗口的事件。

```bash
QQ_MODE=wayland ./run.sh   # 走 Wayland（不需要先跑 x11-setup.sh）
./stop-wayland.sh          # 停止
./logs-wayland.sh          # 看日志
```

前置条件（一次性）：

```bash
brew tap J-x-Z/tap && brew trust --tap J-x-Z/tap
brew install cocoa-way waypipe-darwin
```

> **版本要求：cocoa-way > 2.0.3，或 ≥ commit `f7eca85c`**（第一个修指针 bug 的
> 提交）。brew 当前装的 **2.0.3 有指针消失 bug**，必须按下一节打补丁。

```bash
cocoa-way &             # 保持运行，它就是宿主上的合成器
```

会话定义在 `~/.config/cocoa-way/container-sessions.toml`，本项目已经按
QQ 的需要写好（关键在于 `--arch amd64 --rosetta`、`presentation = "rootless"`、
以及 `env` 这个键名）。也可以用 `cocoa-wayctl launch QQ` 启动。

Cocoa-Way 必须保持运行：`cocoa-way &`（它就是宿主上的合成器）。

### ⚠️ 必须打补丁：brew 装的 cocoa-way 2.0.3 有指针消失 bug

> **版本要求**：cocoa-way **必须 ≥ (修复指针 bug 的 commit)**，即要么用
> `> 2.0.3` 的正式发布版，要么用包含以下 commit 的构建：
> `f7eca85c`（Balance NSCursor hide/unhide）、`d6895dac`（Show a hidden
> cursor when the pointer leaves）、`3e2f631c`（Restore the cursor when its
> Wayland surface closes）。**v2.0.3 及其之前的版本全部不含此修复**，必须打补丁。

**症状**：QQ 窗口正常显示、能操作，但**鼠标指针不可见**。点一下 macOS
菜单栏指针会回来，可是在 QQ 里**打开新窗口**（比如「合并转发的聊天记录」）
指针又消失。窗口内的普通点击不会影响指针。

**原因**：这是 cocoa-way 上游的 bug，不是本项目的问题。发布版 v2.0.3 的
`src/state.rs::cursor_image()` 长这样：

```rust
CursorImageStatus::Hidden  => NSCursor::hide(),   // 引用计数 +1
CursorImageStatus::Named   => { ...cursor.set()... }  // 从不 unhide
CursorImageStatus::Surface => { ... }                 // 从不 unhide
```

`NSCursor::hide()/unhide()` 是**引用计数**的。v2.0.3 调了 `hide()`，却**整个
代码库里一次 `unhide()` 都没有**（已用官方 v2.0.3 tarball 核对：0 次），也没有
`show_hidden_cursor` 这个辅助函数。所以任何 Wayland 客户端只要发过一次
`CursorImageStatus::Hidden`，指针就被永久隐藏。唯一能让它回来的是 winit 在
`CursorLeft` 时内部调的 `set_cursor_visible(true)`——这正好解释了「点菜单栏
（指针离开窗口）就恢复，每开一个新窗口又消失」。

这是**普遍 bug**：Chromium/Electron 应用（包括 QQ）在弹新窗口、视频空闲期
都会发 `Hidden`，所以任何 Electron 应用在发布版 cocoa-way 上都会踩到，与
本项目的容器/Rosetta 配置无关。

**修法**：上游 master 已经修好了（用引用计数的 `CursorVisibility` 原子量把
`hide()`/`unhide()` 配对），但**还没有发布任何包含该修复的 tag**（最新就是
v2.0.3）。所以自己从 master 编译：

```bash
cd cocoa-way-patch
./install-cocoa-way-head.sh   # clone master → 校验修复存在 → 编译 → 替换 Cellar 二进制
```

装完必须重启 cocoa-way：

```bash
pkill -f '^/opt/homebrew/Cellar/cocoa-way/.*/cocoa-way$'
nohup cocoa-way > /tmp/cocoa-way.log 2>&1 &
```

> 注意：`brew upgrade cocoa-way` 会把二进制换回有 bug 的版本，升级后重跑
> `install-cocoa-way-head.sh` 即可。详见 `cocoa-way-patch/README.md`。

### 手动跑 Wayland 模式的两种方式

**方式 A：让 Cocoa-Way 管（推荐）**

```bash
cocoa-way &                    # 1. 确保合成器在跑
cocoa-wayctl launch QQ         # 2. 启动（后台，立即返回）

cocoa-wayctl --json applications   # 看状态
cocoa-wayctl --json logs QQ        # 看日志（只保留最后100行）
cocoa-wayctl stop QQ               # 停止
```

`launch` 不会把日志流给你，它只把任务排到合成器的事件循环里。

### 改完配置必须重启 cocoa-way（两个坑）

**坑 1：`container-sessions.toml` 是启动时读一次的。**
改完文件后 `cocoa-wayctl` 看不到任何变化，甚至会让 `applications`
变成空列表。必须重启合成器：

```bash
cocoa-wayctl stop QQ
pkill -f '^/opt/homebrew/bin/cocoa-way$'
nohup cocoa-way > /tmp/cocoa-way.log 2>&1 &
```

**坑 2：写错字段名会让整个文件被丢掉。** 这个 struct 对
**不认识的字段是硬报错**，一旦报错，**里面所有 session 全部消失**
（不只是写错的那个）。启动日志里会有一行：

```
WARN cocoa_way::container_sessions: Failed to parse container-sessions.toml:
     TOML parse error at line 75, column 11
```

所以改完配置后，先看这行有没有出现，再确认 `applications` 里
session 还在：

```bash
grep -iE 'parse|container_sessions' /tmp/cocoa-way.log
cocoa-wayctl --json applications
```

合法的字段只有：`name`、`image`、`runtime`、`display`、`presentation`、
`profile`、`app`、`socket`、`container_socket`、`waypipe_path`、
`waypipe_compress`、`waypipe_threads`、`audio`、`runtime_args`、`mounts`、`env`。
没有 `command`、也没有 `environment`。

> 还有个反直觉的点：Cocoa-Way 会给容器注入宿主代理变量
> （容器命令行里能看到 `HTTP_PROXY=socks5://192.168.64.1:52335`
> 及对应的 `HTTPS_PROXY`/小写版本）。X11 模式没有这个行为，
> 如果你不想让流量走宿主代理，需要自己覆盖这几个变量。

**方式 B：用本项目的脚本（自包含）**

```bash
./wayland-launch.sh    # 前台运行，Ctrl-C 退出
```

日志在 `/tmp/cocoa-way-qq/container.log`，另开一个终端用 `./logs-wayland.sh`
看。停止用 `./stop-wayland.sh`。也可以 `QQ_MODE=wayland ./run.sh`。

两种方式不要同时跑，它们会抢同一堆 host socket。

### 判断到底出没出图

**不要看 `cocoa-wayctl diagnostics` 的 `redraw_fps` / `commits_per_second`。**
一个静态、没人碰的窗口本来就不提交新帧，这两个值经常是 0，
拿它们判断会得出错误结论。直接问 macOS 窗口服务器：

```bash
./windows.sh cocoa-way     # 列出 cocoa-way 的窗口和尺寸
```

QQ 正常出图的话，这里会多出一个尺寸接近 800x600 的窗口。
（AppleScript/System Events 在这个场景下用不了：没有 Automation 授权，
会报 error -1743。`windows.sh` 走 `CGWindowListCopyWindowInfo`，不需要授权。）

> **实测结论**：Wayland 通路的每一段都验证过了——传输层（CWV2 分帧）、
> 合成器（`wl_shm`/`xdg_wm_base` 等 global 齐全）、窗口呈现（用最小客户端
> `foot` 做对照，屏幕上真的出现了 macOS 窗口）、以及 QQ 作为原生 Wayland
> 客户端。
> **但 QQ 自己出不了图**：它能连上合成器、看到屏幕（800x600）、建 surface、
> 跑起 renderer 加载网页，却在提交首帧前**空指针崩溃**（Crashpad minidump：
> `ExceptionCode 0xC000000C`，地址 `0x0`）。因为 Apple `container` 的虚拟机
> 里根本没有 `/dev/dri`，Chromium 拿不到 DRM render node，
> `wayland_buffer_manager_gpu` 初始化失败。
> 而 `foot` 是纯 `wl_shm` 客户端、不走 GPU 缓冲路径，所以它能正常显示。
> **X11 模式可用；Wayland 模式通路已验证、但 QQ 因无 GPU 节点而无法出图。**
> 详见下面的「Wayland 已知问题」。

首次启动时 QQ 会同步历史消息，窗口可能整个消失或卡住很久。**这不是崩溃**，
上游 README 也特别提到了，耐心等。

聊天记录在 `./QQ/`，共享文件放 `./shared/`（容器内是 `/home/user/shared`）。
两个目录的文件属主会是你自己的 UID/GID（镜像里的 `user` 账户就是按宿主 UID 建的），
宿主直接读写不会有权限问题。

### 重启后

XQuartz 的 auth 文件路径带 pid（`~/.serverauth.<pid>`），重启后就失效了。
重新跑一次 `./x11-setup.sh` 即可（cookie 会复用 `.x11-cookie`，不会变）。

---

## 验证情况

本项目已在以下环境实际跑通：

- Apple M 系列 Mac，macOS 26.6.2，`container` 1.5.0
- XQuartz 2.8.6
- 镜像 `mac-qq-docker:latest`（amd64 / Rosetta）
- QQ 3.2.34-53644

验证到的结果：

- 容器内 `uname -m` 返回 `x86_64`，QQ 的 Electron 二进制在 Rosetta 下正常执行
- QQ 主进程 + zygote + 网络/音频 utility 子进程完整拉起
- 宿主机 `xwininfo -root -tree` 能看到 QQ 的窗口（960x640 主窗口等）已映射
- 宿主机 `xlsclients` 显示 `Machine: qq`，即容器通过 X11 cookie 认证连上了宿主 X server
- 聊天记录目录 `./QQ/` 正确写入（MMKV 数据库文件已生成）

### 可以忽略的报错

日志里会有这些，不影响使用：

```
ERROR:dbus/bus.cc: Failed to connect to the bus:
     Failed to connect to socket /run/dbus/system_bus_socket
```

这是 QQ 在找 **system bus**（不是我们起的 session bus）。容器里没有 system dbus，
QQ 用它只是为了注册休眠抑制（`login1.Manager.Inhibit`），失败后会自动降级。
同理还有：

```
libGL error: No matching fbConfigs or visuals found
libGL error: failed to load driver: swrast
```

因为没有 GPU 直通，走的是软件渲染路径。Electron 会自己回退到 SwiftShader，
窗口照常显示，只是动画会慢一点。

---

## 关于 X11 / 显示

macOS 没有 X11，所以走 XQuartz：

```
容器 (amd64 VM)  --TCP 6000-->  192.168.64.1 (宿主, XQuartz)
```

macOS 上的 `container` VM 通过 vmnet 连接，宿主机在网关地址（默认 `192.168.64.1`）
可达。`entrypoint.sh` 会自动探测并设置 `DISPLAY=192.168.64.1:0`。

### 访问控制：用 cookie，不用 `xhost`

网上大多数教程会教你 `xhost +`。**不要那么做**——它等于关闭 X server 的访问控制，
任何能连到你 6000 端口的机器都能读你的屏幕、记录你的键盘。

`xhost +192.168.64.1` 这种写法虽然安全，但 Apple `container` 每次启动给容器分配的
IP 都不一样（192.168.64.7、.8、.9……），所以会反复失效。而且 XQuartz 的 `xhost`
不认 `192.168.64.0/24` 这种 CIDR 写法（试过，会报 `bad hostname`）。

所以 `x11-setup.sh` 用的是 **X11 cookie（`xauth`）**，既能精确授权又不受 IP 变化影响。

有一个坑值得说一下：XQuartz 是通过 `startx` 启动的，命令行上带着
`-auth /Users/<你>/.serverauth.<pid>`。也就是说，**往 `~/.Xauthority` 里加 cookie 是没用的**，
必须写进 X server 真正加载的那个文件。`x11-setup.sh` 会自动从进程参数里把这个路径找出来。

重启或重新登录之后，`.serverauth.<pid>` 会变，重跑一次 `./x11-setup.sh` 即可
（cookie 本身保存在 `.x11-cookie` 里，会复用）。

需要确认 XQuartz 真的在监听：

```bash
nc -z 127.0.0.1 6000 && echo 'X11 OK'
```

### 显卡

Apple `container` 没有 GPU 直通，所以 `qq-wrapper.sh` 里强制软件渲染
（`--disable-gpu`、`LIBGL_ALWAYS_SOFTWARE=1`）。QQ 的动画会略卡，但能正常用。

> 说明：上面的旧版强制软件渲染描述主要针对 **X11** 模式。**Wayland 模式**（本项目当前默认，
> via cocoa-way）走的是另一个更顺的路子：`qq-wrapper.sh` 在 Wayland 下**故意不加任何 GL 开关**，
> 让 Chromium 自己选软件 fallback，走 `GLSurfaceEglReadbackWayland`（wl_shm readback），
> 实测窗口可渲染、可交互（窗口约 900×700，可缩放）。两个模式都能用，只是 Wayland 对鼠标键盘事件更安全（无 X11 键盘记录风险）。

### GPU 加速：两条备选路线已调研（结论：暂不可行）

`container` 虚拟机的内核是固定的、不可加载模块、也没有 `/dev/dri`，所以 VM 内无法直接出 GPU。
为了给 QQ 争取 GPU 加速，调研了两种替代拓扑，都因硬性阻断而**不可行**。

#### 备选 1：lima `krunkit` 虚拟机（Virtio-gpu 直通）

思路：把 QQ 挪到一个 lima `vmType: krunkit` 的 VM 里（krunkit 基于 libkrun + Apple
Virtualization.framework），据说能带 virtio-gpu，从而在 guest 里有 `/dev/dri`。

**结论：不行，krunkit 既无 GPU、也无 Rosetta。** 已按 lima v2.2.0 + krunkit 源码逐条核实：

- lima 的 krunkit 驱动 `Cmdline()` 只发射 `virtio-serial / virtio-blk / virtio-vsock /
virtio-net / virtio-fs`，**没有 `virtio-gpu`**（`pkg/driver/krunkit/krunkit_darwin_arm64.go`）。
- 就算手动给 krunkit 传 `--device virtio-gpu,width=..,height=..`，krunkit 的 `src/virtio.rs`
  对 `Gpu` 直接落到 `_ => Ok(())` —— 注释明言 “virtio-gpu … currently not configured in krun”，
  **是个 no-op**。
- 之前二进制 `strings` 里见到 `VZVirtioGraphicsDeviceConfiguration` / Rosetta 的 CDI 配置，
  其实是 `lima-driver-krunkit` 因 import `pkg/driver/vz`（仅为 `PassFDToUnix`）而**链接进来的
  vz 驱动惰性符号**，krunkit 虚拟机根本不会执行它们。
- **Rosetta 只有 vz 驱动支持**（`vmOpts.vz.rosetta`），krunkit 不接。所以 x86_64 QQ 在
  krunkit guest 里跑不了，只能跑原生 aarch64 QQ —— 而我们已确认官方有 arm64 包（见上文）。
- 但即便用原生 arm64 QQ，krunkit 仍没有 `/dev/dri` 的 virtio-gpu，QQ 还是软件渲染，
  **毫无 GPU 收益**，反而引入一个还是 beta、headless、没有 GUI 支持的外部驱动。

结论：保持现状（vz + Rosetta + Wayland）是最稳的；krunkit 要等 lima 真发射 virtio-gpu、
并且 krunkit/libkrun 在 macOS 上真的配置 virtio-gpu 之后再考虑。

#### 备选 2：GPU-over-IP（remote-virtio-gpu 桥）

思路：将 GPU 渲染拆成 server/client。`rvgpu-renderer` 在一台有 GPU 的 Linux 主机上渲染，
`rvgpu-proxy`（app 侧）通过加载 `virtio-gpu` + `virtio-lo`（自研 `virtio-loopback-driver`
内核模块）在本地**新建一个 `/dev/dri/cardX` 节点**，经由 TCP（默认 55667）把 QQ 的绘制命令
转发到 server 端真实 GPU。

**结论：客户端在 `container` VM 里无法工作。** 决定性阻断：

- `rvgpu-proxy` 必须 `modprobe virtio-gpu; modprobe virtio-lo` 加载内核模块才能创建
  `/dev/dri/cardX`。
- 但 Apple `container` VM 的内核**固定、不可加载模块**（实测无 `/lib/modules`、无
  `/proc/modules`、无 `insmod/lsmod/modinfo`、无 `/dev/dri`）。没有 `virtio-lo`，
  `cardX` 节点根本造不出来，client 侧直接死掉。
- 两个端点都必须是 Linux（server 要 mesa/virgl/GBM/EGL/Wayland + `virtio-lo` 模块，
  **macOS 当不了 server**）。即便两端都用 Linux 虚拟机，virgl+TCP 对交互式 QQ 延迟也不理想
  （官方建议 1 Gbps 网络），且 QQ 是否真的吃这个 DRM/virgl 节点也无人验证。

结论：只有当一个能证明 `container` VM 能加载 `virtio-lo` 时，这条才有戏——目前做不到。

---

## 接入方式说明：Rosetta

> 更正：**官方确实发布了 arm64（aarch64）版 Linux QQ**，版本号和 x86_64 同步。
> 下载例：`https://qqdl.gtimg.cn/qqfile/QQNT/9.9.36/beta/9ee04bef/linuxqq_3.2.34-53644_arm64.deb`
> （实测可下载，包内 `Architecture: arm64`，与 x86_64 同为 `3.2.34-53644`，
> sha512 `fa1424d4...a5d1`）。早期结论“只有 amd64”是因为 `im.qq.com` 的
> `linuxQQDownload` API 只回 `x64DownloadUrl`，而 arm64 走的是腾讯的 QQNT CDN
> 路径（`qqdl.gtimg.cn/qqfile/QQNT/...`），不在那个 JSON API 字段里。

本项目仍按 `linux/amd64` + Rosetta 构建，顺着已有的 x86_64 流程走（稳定性优先）。

tldr：**你不需要为它换 arm64 包**。本项目之所以不切 arm64：

1. 当前 x86_64 + Rosetta + cocoa-way Wayland 方案已经**实测可用**（cocoa-way 转发窗口可渲染、可交互）。
2. Electron 的 x86_64→arm64 切换，QQ 登录态/缓存目录不通用，没必要为没收益的架构切换去折腾。
3. 备选 GPU 加速方案（lima krunkit）也无法给 QQ 提供 GPU，即便用原生 arm64 版也还是软件渲染
   （详见「### 显卡」的调研）。

若未来你想用原生 arm64，把 `Dockerfile`/`run.sh` 里的 `--arch amd64 --rosetta` 换成
`--arch arm64`，并把 apt 源/依赖换成 arm64 即可（仓库里没有内置这条路径，因为调通了毫无额外收益，
反而多一层风险）。

`./build.sh` 和 `./run.sh` 都带了 `--rosetta`，无需额外配置。

Rosetta 需要宿主安装 Rosetta（一般装过一次其它软件就有了）。macOS 27 之后系统直接内置。
如果报错，手动装：`softwareupdate --install-rosetta --agree-to-license`。

---

## 输入法

上游只支持 fcitx5，本项目也一样。但 macOS 的情况和 Linux 不同：
你不能把宿主的输入法「接」进容器，因为宿主的输入法是 macOS 的原生 IME，
和 XIM/fcitx 协议不互通。

两个选择：

1. **用容器内的 fcitx5**（默认关闭）。在 `init.sh` 或 `.env` 里设 `QQ_ENABLE_IME=1`，
   容器启动时会拉起 fcitx5。但它没有配置好的中文输入方案，需要用 `fcitx5-config-qt`
   在容器里配（`./shell.sh` 进去跑）。折腾一次就固定了。
2. **复制粘贴**（推荐，最省事）。在 macOS 上打好字，用 XQuartz 的剪贴板粘贴进 QQ。
   `Cmd+V` 在 XQuartz 里会映射过去。

顺带一提，上游提到的「粘贴图片后输入法小概率失效」在 cut/copy-paste 方案下基本不会遇到。

---

## 音频

默认没有声音。要开的话需要一条 macOS → 容器的音频通路，且 `container` 不能挂载
宿主 socket，只能走 TCP：

```bash
# 宿主：装一个 TCP 模式的 PulseAudio 服务端
brew install pulseaudio
# 让它监听 4713 端口，并把输出接到 macOS 的音频设备（通常配合 BlackHole）
```

然后在 `.env` 里设 `QQ_PULSE_SERVER=tcp:192.168.64.1:4713`，并在 `run.sh` 里
作为 `PULSE_SERVER` 传进容器。

这一步跨 macOS 的 HAL 插件、BlackHole 虚拟声卡和 PulseAudio 的 TCP 模块，
坑比较多，所以没做成默认开启。QQ 的文字聊天完全不需要音频。

---

## 和上游一样的已知问题

这些是 Linux QQ 自身或 X11 方案的局限，移植后依然存在：

1. **不能拖拽传文件**。用 `./shared/` 目录中转。
2. **截图功能不可用**。QQ 的截图走 dbus 调 `org.gnome.Shell.Screencast`，容器里没有 GNOME。
   变通：在 macOS 上截图，然后粘贴进 QQ。
3. **QQ 邮箱 / QQ 空间等内嵌网页打不开**，因为容器里没有能用的 `xdg-open`。
4. **X11 的固有风险**（见上）。
5. 只在这台 M 系列 Mac + macOS 26 + `container` 1.5.0 上验证过。

### Wayland 模式的已知问题

**显示通路完全正常，卡在 QQ 自己身上。** 这是靠一组对照实验定下来的。

同一台机器、同一个合成器、同一套 `rootless` + `single-app` 配置、
同样的 Rosetta 参数，两个 session 同时跑：

| session | 状态 | 进程数 | macOS 窗口 |
|---------|------|--------|------------|
| `foot`（纯 `wl_shm` 客户端） | Running | 存活 | ✅ **有，960x752** |
| **QQ** | Running | 6 | ❌ 没有 |

`foot` 能出窗口，QQ 不能。而 `foot` 是纯软件客户端、**不走 GPU 缓冲路径**，
QQ 要走。这就是分界线。

先确认合成器没问题。直接向 Cocoa-Way 的 socket（`$TMPDIR/cocoa-way/wayland-1`）
发 `wl_display.get_registry`，把它广播的 global 都读出来：

```
wl_compositor v5      wl_shm v2             wl_subcompositor v1
xdg_wm_base v7        wl_seat v9            wl_output v4
wp_viewporter v1      zwlr_data_control_manager_v1 v2
xdg_decoration_manager_v1 v1                 …
```

QQ 软渲染需要的 `wl_shm`、建窗口需要的 `xdg_wm_base`、`wl_compositor` 全部都在。

然后看 QQ 内部。用 `--enable-logging=stderr --v=1` 把它的日志打开，
会发现它其实走得比想象的远得多：

```
ERROR drm_render_node_path_finder.cc:45  drmGetDevices2() has not found any devices
WARNING ozone_platform_wayland.cc:325    Failed to find drm render node path
WARNING wayland_buffer_manager_gpu.cc:458 Failed to initialize drm render node handle
Display: EVENT: wayland_screen.cc:146 Displays updated, count: 1
Display[7] bounds=[0,0 800x600]
VERBOSE render_widget_host_view_base.cc:520 UpdateScreenInfo: Overriding scale
        for screen 'Smithay - Winit - winit'
VERBOSE wayland_surface.cc  Server doesn't support zcr_alpha_compositing_v1 …
VERBOSE extensions/renderer/script_context.cc:150  context_type: WEB_PAGE
NetworkDelegate: https://otheve.beacon.qq.com/analytics/v2_upload …
```

也就是说：QQ **看到了合成器的屏幕（800x600）**、**建了 Wayland surface**、
**真的跑起了 renderer 并加载了网页**，连网络请求都发出去了。它并不是没启动。

但**只有 2 条 stream，而且永远是 2 条**，`displays.managed` 始终为空 ——
没有任何窗口/surface 被注册给合成器。

关键证据在 `QQ/Crashpad/completed/`：有一个 14 MB 的 minidump，
手工解析出来是：

```
Signature        = MDMP
ExceptionCode    = 0x0000000c   (SIGSEGV / 空指针)
ExceptionAddress = 0x0
模块列表          = 0 个
```

`/opt/QQ/qq` 在地址 0 上空指针崩溃。配合上面
`wayland_buffer_manager_gpu.cc:458 Failed to initialize drm render node handle`
一起看，因果链就很清楚了：

**根本原因：Apple `container` 的 Linux 虚拟机里没有 `/dev/dri` 节点**
（整个 `/dev/dri` 目录都不存在，不是权限问题）。Chromium 拿不到
DRM render node，`wayland_buffer_manager_gpu` 初始化失败，
于是无法分配 buffer、无法提交首帧。

测试过的所有对策及结果：

| 尝试 | 结果 |
|------|------|
| `--shm-size 1G`（默认 64M 太小） | renderer 确实能起来，仍不出图；已保留在配置里 |
| `--use-gl=angle --use-angle=swiftshader` | GPU 进程跑到 gles2 decoder，仍不出图 |
| `--use-gl=disabled --disable-gpu-compositing --disable-software-rasterizer` | 不再崩溃，但也不出图 |
| `--disable-features=WaylandLinuxDrmSyncobj,Vulkan` | 无变化（本意是绕开 syncobj 缓冲路径） |
| `GALLIUM_DRIVER=llvmpipe` + `MESA_LOADER_DRIVER_OVERRIDE=swrast` | 无变化；已保留（省得白耗时间探测 GPU） |
| `mknod /dev/dri/renderD128 c 226 128` | 无变化（且重启容器就没了） |
| 补一个私有 session D-Bus | 消除了 dbus 报错，但不是出图的原因；已保留 |

镜像里 `swrast_dri.so` 和 `libGL`/`libEGL` 都是齐的，所以不是缺软件渲染库。

顺带确认的一个真实限制：Cocoa-Way 的 global 列表里**没有
`zwp_text_input_manager_v3`**，所以日志会出现 `text-input-v3 not available`，
Wayland 模式下**输入法用不了**（X11 模式走 XIM，是好的）。

结论：**日常用 X11 模式（能用，只是有 X11 固有的按键可见性）；
Wayland 模式通路已完整验证（foot 能出窗口就是证据），但 QQ 因虚拟机无
GPU/DRM 节点而在提交首帧前崩溃，本机无法出图。**

要继续推的话，方向只剩一个：给 `container` 换一个带 virtio-gpu/DRM 的内核，
或者等 Cocoa-Way 支持给 rootless 会话提供虚拟渲染节点。
这两条都超出改配置能解决的范围了。

> 小工具：`./windows.sh [过滤]` 列出屏幕上真实的窗口。**不要**用
> `cocoa-wayctl diagnostics` 的 `redraw_fps`/`commits_per_second` 判断有没有出图 ——
> foot 的窗口明明在屏幕上，这两个值仍然是 0。

---

## 排查

移植过程中实际踩到的坑，记下来省得重复：

**`Error: unknown: "open /tmp/xxxx: read-only file system"`（构建时）**

builder VM 的 virtiofs 挂载挂了。通常是磁盘写满之后出现的（builder 不会自动恢复）。
重启 builder 即可：

```bash
container builder stop && container builder delete && container builder start
rm -rf ~/Library/Application\ Support/com.apple.container/builder/*
```

**`ResourceExhausted: no space left on device`**

宿主磁盘满了。`container prune` 回收不了快照（实测 reclaimed 0 KB），
要手动看 `~/Library/Application Support/com.apple.container/` 下面的
`snapshots/` 和 `containers/`。

**QQ 窗口没出现**

按顺序确认：

```bash
nc -z 127.0.0.1 6000 && echo 'XQuartz listening'
DISPLAY=:0 xlsclients            # 应该能看到 qq
```

`xlsclients` 里没有 `qq` 就说明 X 认证没过，重跑 `./x11-setup.sh`。
如果是 `Invalid MIT-MAGIC-COOKIE-1 key`，几乎总是因为 cookie 写到了
`~/.Xauthority` 而不是 XQuartz 真正加载的 `~/.serverauth.<pid>`。

**`xhost: bad hostname "192.168.64.0/24"`**

XQuartz 的 `xhost` 不支持 CIDR，只认单个主机名/IP。这也是本项目改用
`xauth` cookie 的原因之一。

**窗口出现了但拖不动 / 点不动**

首次登录时 QQ 在同步消息，会暂时无响应，等一会儿。若超过很久还是卡死的，
看 `./logs.sh` 里有没有渲染进程崩溃。

---

## 目录结构

```
Dockerfile        镜像定义（Debian 12 + 官方 linuxqq deb）
entrypoint.sh     容器入口：探测 X11、起私有 D-Bus、设置软件渲染
qq-wrapper.sh     启动 QQ，处理 sandbox / GPU 参数
init.sh           生成 .env，创建 QQ/ 和 shared/
build.sh          构建 amd64 镜像（Rosetta）
run.sh            启动容器（docker-compose.yml 的等价物）
x11-setup.sh      配置 XQuartz 允许容器连接
stop.sh logs.sh status.sh shell.sh view.sh   日常运维
```

---

## 关于软件来源

镜像里的 linuxqq 来自腾讯官方发布的 deb。AUR 的 `linuxqq` PKGBUILD 记录了这个包的
sha512，本项目用同一个值做校验：

```
774e45cd7238dc51b31c02ee494f9f86e773c487a90851790a806f776e130af125110045844e90dd68d0b073dc53bdd4d1c6d8fb7225b8f214fc0e35d1a20e32
```

和上游 `ntdgy/docker-qq` 直接从某个 GitHub 仓库拉预打包文件、或 `rmb122` 在构建时
跑 `makepkg` 从 AUR 拉源码相比，这里只从官方渠道下载一个固定版本，并在 `apt-get install`
之前校验完整性。校验不通过构建直接失败。

腾讯官方 CDN 上的直链会随版本更新失效（页面 JSON 里的链接已经 404 了），
所以 `Dockerfile` 里的 URL 指向一个镜像站。要换版本就改 `LINUXQQ_URL` 和
`LINUXQQ_SHA512` 两个 build arg，sha512 可以从
[AUR 的 PKGBUILD](https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=linuxqq) 拿。

## 🚫 **免责声明**
以上内容由ai生成。本程序**按原样提供**，作者**不对程序的正确性或可靠性提供保证**。
