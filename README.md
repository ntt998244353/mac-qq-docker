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

### GPU 加速：局限与两条备选路线

`container` 虚拟机的内核是固定的、不可加载模块、也没有 `/dev/dri`，所以 VM 内无法直接出 GPU。

注意区分两件事：
- **QQ 现在跑在哪里**：Apple `container` VM。这个 VM **确实没有 GPU**，也**没法加**
  （`container-apiserver` 没有任何 graphics-device 配置 API，二进制层面查过）。
- **lima `krunkit` VM 是否有 GPU**：**有，而且默认就开**（见下）。但那是另一个 VM，把 QQ
  搬过去是另一条路线。

#### 事实澄清：lima 的 krunkit VM 确实有 GPU（默认开启）

CNCF 博客与 lima 官方文档说的都是对的：krunkit（基于 libkrun）给 guest 提供 GPU，
llama.cpp 在 guest 里能把 Apple 芯片识别成虚拟 GPU。已在 krunkit 源码里逐行核实：

- `src/context.rs` 里**无条件**调用：
  ```rust
  // Temporarily enable GPU by default
  let virgl_flags = VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL;
  krun_set_gpu_options2(id, virgl_flags, vram);
  ```
  即每个 krunkit VM 启动时**默认就带 GPU**，不需要 lima 传任何 `--device` 参数
  （所以 lima 的 `Cmdline()` 里没有 GPU 相关 flag 是正常的）。
- **但这个 GPU 是 Venus（Vulkan）专供**：`VIRGLRENDERER_NO_VIRGL` 明确**关掉了传统
  OpenGL/virgl 路径**，只暴露 Vulkan。VRAM 按宿主内存自动分配（上限受 64 GB IPA 限制）。

> 早期调研误判“krunkit 没有 GPU”的原因：只看了 `src/virtio.rs` 里
> `--device virtio-gpu,...` 这个 **CLI 字符串解析**分支（它确实落到 `_ => Ok(())`，是一个
> 旧的 2D framebuffer/scanout 占位，未实现），而漏看了 `context.rs` 里**默认就在跑**的
> 真正 3D GPU 初始化。两者是两回事。

#### 实测结论：krunkit 的 GPU 当前**无法使用**（上游 bug 卡死在 `vkCreateInstance`）

上面是“有没有”的问题（有）。真正关键的是“能不能用”——本项目已**实际装了 krunkit 并
在 VM 里跑通全部探测**（Apple M5 Pro / macOS 26.6.2，lima 2.2.0，krunkit 1.3.2，
libkrun 1.19.6，libkrunfw 5.6.2，virglrenderer-krun 0.10.4e，molten-vk 1.4.2，
guest Ubuntu 24.04.5 arm64，Mesa 25.2.8）。结果为：

**确实有 `/dev/dri`：**
```
/dev/dri/card0       (226,0)
/dev/dri/renderD128  (226,128)
[drm] features: +virgl +edid +resource_blob +host_visible +context_init
[drm] Initialized virtio_gpu 0.1.0 0
[drm] KMS disabled        <-- 没有 scanout/显示输出能力
```

**但 Vulkan (Venus) 连 instance 都建不起来：**
```
$ VN_DEBUG=all vulkaninfo --summary
MESA-VIRTIO: using DRM device /dev/dri/renderD128
MESA-VIRTIO: connected to renderer          <-- 通到宿主了
MESA-VIRTIO: VK_MESA_venus_protocol spec version 1
MESA-VIRTIO: failed to allocate/map ring shmem    <-- 死在这里
MESA-VIRTIO: vn_CreateInstance: VK_ERROR_OUT_OF_HOST_MEMORY
ERROR: vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY
```
内核侧同步报错（每次尝试）：
```
[drm:virtio_gpu_dequeue_ctrl_func] *ERROR* response 0x1200 (command 0x208)
[drm:virtio_gpu_dequeue_ctrl_func] *ERROR* response 0x1200 (command 0x209)
```

**根因已由上游维护者确认**（`libkrun/krunkit` issue #114，2026-08 开、当月由 slp 关闭）：
- Apple Silicon 的 **VM page size = 16384**。`resource_map_blob` 把**未对齐**的
  `resource.size`（135168）直接传进 `hv_vm_map()`，因非 16384 对齐被拒 → guest `mmap`
  返回 `EINVAL` → `VK_ERROR_OUT_OF_HOST_MEMORY`。
- Venus 的 ring shmem = **131268 字节**（guest 4 KiB 页圆整成 135168 = 33×4 KiB），
  需 144 KiB 才能让宿主映射成功。
- 维护者原话：*“Since 7.2, the kernel provides a way for userspace to read the minimum
  alignment requirements for the virtio-gpu driver (`VIRTIO_GPU_F_BLOB_ALIGNMENT`).
  We need to extend Mesa to make use of it align the BOs as required. **We can't fix this
  from neither krunkit nor libkrun.**”*
- 唯一 workaround：用 slp 的下游补丁重编译 **guest Mesa**（4 处 hunk 都需要）：
  <https://gitlab.freedesktop.org/slp/mesa/-/commit/761ef1ec5ff2aae1cc3dc8bbc22b3d06ef04b549>
  （注：仅改 `vn_ring.c` 能过 `vkCreateInstance`，但接着会在设备内存分配时再失败。）

##### 后续：补丁已实测——16 KiB bug 确实修好了，但 Venus 仍然不可用

本项目按上面的 workaround **实际重编了 guest Mesa**（Mesa 25.2.8，4 处 hunk 全部应用，
只编 `-Dvulkan-drivers=virtio`），并在 VM 里重测。结论是：**补丁有效，但不够**。

- **16 KiB 对齐 bug —— 已确认修好。** 把宿主 krunkit 提到 trace 级别
  （`--krun-log-level 5`，lima 写死 3，用一个 shim 覆盖）后可以看到宿主侧的 blob 映射：

  ```
  virtio_gpu] mapping: map_ptr=103c30000, guest_addr=280000000, size=147456
  vstate]    add_mapping: host_addr=103c30000, guest_addr=280000000, len=147456   <- 成功
  virtio_gpu] mapping: map_ptr=108674000, guest_addr=280024000, size=1048576
  vstate]    add_mapping: host_addr=108674000, guest_addr=280024000, len=1048576  <- 成功
  ```

  `147456 = 9 × 16384`（补丁前是 `135168 = 33 × 4096`，非对齐 → `hv_vm_map` 拒绝）。
  整轮测试 **零** `vstate] Error adding/removing memory map`（打补丁前每轮 11 次失败）。
  宿主内核报错 `response 0x1200 (command 0x208/0x209)` 也消失了。

- **进展对比：**

  | | 打补丁前 | 打补丁后 |
  | --- | --- | --- |
  | `vkCreateInstance` | `VK_ERROR_OUT_OF_HOST_MEMORY` | **`VK_SUCCESS` (0)** |
  | 宿主 blob 映射 | 11 次 `MemoryMap` 失败 | **全部成功** |
  | wire-format / 协议版本协商 | 卡在 ring shmem 分配 | **通过** |

- **但出现了第二个、独立的上游缺陷：**

  ```
  vkEnumeratePhysicalDevices(count) = -3, n=0      # VK_ERROR_INITIALIZATION_FAILED
  ```

  - 失败点全在 **guest 用户态**：`vn_call_vkEnumeratePhysicalDeviceGroups()` 这一步。
    guest `dmesg` **完全静默**（无任何 `virtio_gpu` 报错）→ 不是传输层问题。
  - 宿主侧 libkrun trace **也没有任何报错**；rutabaga **没有**打出
    “Failed to create virtio_gpu backend ... Falling back to safe defaults”，
    说明 GPU 后端是按请求正常建起来的。
  - 关键：`VIRGL_LOG_FILE=/tmp/virgl-venus.log`（配 `VIRGL_LOG_LEVEL=debug`）
    **文件从未被创建** → `virgl_log_init()` 从未执行 → 宿主的 Venus 渲染器
    根本没走到 `vkr_*` 上下文路径，也就是说 **virglrenderer-krun 0.10.4e 里那套
    宿主侧 Venus 实现没有成功应答 `vkEnumeratePhysicalDeviceGroups`**。

  → **结论：issue #114 的 16 KiB 对齐是必要条件，但不充分。**

- 宿主栈已逐一验证健康：`virglrenderer-krun 0.10.4e` 直接链接 `libMoltenVK.dylib`
  （Venus 符号 `_vkr_context_add_instance`、`_vkr_allocator_*` 确实编进去了），
  且宿主 MoltenVK 本身可用：

  ```
  VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json vulkaninfo --summary
  -> Vulkan Instance Version: 1.4.363   （正常枚举）
  ```

  即**宿主 Vulkan 没问题，问题出在 guest↔host 的 Venus 协议实现**。

- 复现环境已保留（细节记录见 `docs/krunkit-venus-patched-mesa-result.txt`）：
  krunkit trace shim 在 `/tmp/krunkit-shim/krunkit`；启动方式
  `env PATH="/tmp/krunkit-shim:$PATH" VKR_DEBUG=1 VIRGL_LOG_LEVEL=debug \
     VIRGL_LOG_FILE=/tmp/virgl-venus.log limactl start qq-gpu-test`；
  guest 侧 `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.json ~/vk_enum`。
  （注意 guest 的 `/tmp` 在重启后清空，源码要放 `$HOME`；原始库备份在
  `/usr/lib/aarch64-linux-gnu/libvulkan_virtio.so.orig`。）

#### 关于“Vulkan 可直接从 DRM 分配 GBM 并显示、不需要 GL/EGL”

这个说法**本身是成立的**（`VK_EXT_image_drm_format_modifier` + `VK_KHR_display` /
`VK_EXT_acquire_drm_display`，Venus 也确实有 no-GL 模式）。但在 krunkit 上这条路
**当前根本走不到**：Vulkan instance 就建不起来（见上）。而且即使 Venus 修好了，
还有两个额外障碍：
- `[drm] KMS disabled` —— 这块 virtio-gpu **没有 scanout/显示输出**，是 render-only 设备，
  “通过 DRM 直接显示”在 guest 内不成立（只能当离屏/headless 渲染节点）。
- **Qt/Electron 的实际渲染路径不是 Vulkan**。QQ(NT) 是 Electron，Linux 下窗口合成走
  GL/EGL/GBM；就算 Vulkan 可用，也得 QQ/Chromium 主动走 Vulkan 后端（`--use-vulkan`）
  才谈得上受益。而 krunkit 用 `VIRGLRENDERER_NO_VIRGL` **把 OpenGL 路径关了**。

> 补充：slp 那支下游 Mesa 补丁本项目**已经实测过了**（见上文“后续”小节）：16 KiB
> 对齐 bug 确实被修好，`vkCreateInstance` 从 `OUT_OF_HOST_MEMORY` 变成 `VK_SUCCESS`，
> 但随即卡在 `vkEnumeratePhysicalDevices` 返回 `VK_ERROR_INITIALIZATION_FAILED`——
> 宿主侧 Venus 没能完成物理设备枚举。所以这条路的下一跳不在 Mesa，而在
> **virglrenderer 的 Venus 实现**（或等上游修）。

#### 即使 GPU 修好了，QQ 还有别的障碍

假设 slp 的 Mesa 补丁让 Venus 能跑（或上游修了桶），要真的给 QQ 用上还有：

1. **KMS disabled**：这块 virtio-gpu 没有 scanout，是 render-only 设备，“从 DRM 直接显示”
   在 guest 内不成立；且 krunkit 用 `VIRGLRENDERER_NO_VIRGL` **把 OpenGL 路径关了**，
   而 Electron/Chromium 在 Linux 的窗口合成默认走 GL/EGL/GBM。要受益得让 QQ 走 Vulkan
   后端（`--use-vulkan`）+ 自建 Wayland/compositor，是个原型级工程。
2. **krunkit 不提供 Rosetta**（Rosetta 是 lima `vz` 驱动专有）。所以搬过去就必须用
   **原生 aarch64 QQ**——好消息是**官方确实有 arm64 包**（同上文，`3.2.34-53644_arm64.deb`，
   实测可下载）。

> lima 的 krunkit 驱动是**外部驱动、仍为 experimental**，且 `CanRunGUI=false`。
> 本项目已实测创建一个 `qq-gpu-test` 实例；若你要继续实验，它保留在 `~/.lima/qq-gpu-test`。

#### 备选 2：GPU-over-IP（remote-virtio-gpu 桥）——客户端在 container 里不可行

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
  **macOS 当不了 server**）。且 virgl+TCP 对交互式 QQ 延迟不理想（官方建议 1 Gbps 网络），
  QQ 是否真的吃这个 DRM/virgl 节点也无人验证。

#### 小结

| 路线 | 能否给 QQ 拿到 GPU | 阻断点 |
| --- | --- | --- |
| 现状（`container` + Wayland） | ❌ | VM 无 GPU，且无法加（无 API） |
| lima `krunkit` | ❌（已实测，两轮） | 有 `/dev/dri`，但 **Venus 完全不可用**：修完上游 #114 的 16384 对齐 bug 后，仍卡在 `vkEnumeratePhysicalDevices` = `INITIALIZATION_FAILED`（宿主 Venus 不应答）；`KMS disabled`；`NO_VIRGL` 关了 GL；无 Rosetta |
| GPU-over-IP | ❌ | `container` VM 无法加载 `virtio-lo` 内核模块 |

另外补充一个对本项目**实际可用**的真相：即使 GPU 完全用不上，QQ 在 **cocoa-way** 下的渲染
仍然正常——因为 Electron 会回退到软件 GL（`GLSurfaceEglReadbackWayland`，wl_shm readback）。
这个“无 GPU”路径是目前已验证可用的方案，对聊天应用足够。

上面整套步骤本项目已经**完整跑过两轮**：第一轮在未打补丁的 guest Mesa 上卡在
`vn_CreateInstance`（`OUT_OF_HOST_MEMORY`，上游 #114）；第二轮按 workaround 重编了
guest Mesa，`vkCreateInstance` 成功，但 `vkEnumeratePhysicalDevices` 返回
`VK_ERROR_INITIALIZATION_FAILED`——宿主 Venus 渲染器没能应答设备枚举（细节见上文）。
所以目前**两个上游缺陷叠加**，Venus 仍不可用。把 QQ 搬到 krunkit 不会带来任何 GPU 收益。

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
3. 备选 GPU 加速方案（lima krunkit）虽有默认开启的 GPU，但那是 **Venus/Vulkan 专供**；
   已实际重编 guest Mesa 验证过：即使修好上游 #114 的 16 KiB 对齐 bug，仍卡在物理设备
   枚举（`VK_ERROR_INITIALIZATION_FAILED`），且 `KMS disabled`（无显示输出）、
   `NO_VIRGL`（GL 路径关闭）、无 Rosetta。**实质上拿不到可用 GPU**，详见「### GPU 加速」。

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
