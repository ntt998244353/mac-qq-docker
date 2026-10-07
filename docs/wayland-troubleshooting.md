# Wayland 模式故障排查（白屏闪退）

> **先读这一段。** 下面记录的三个 bug 都是真的，也都已修好，但它们只让 QQ
> **不再崩溃**，并**没有**让它显示出来。
>
> `wayland-launch.sh` 把 waypipe 直接接到 Cocoa-Way 的内部 socket
> `wayland-1` 上，而 Cocoa-Way **只呈现通过它自己的控制 API 分配出来的
> 会话显示（session display）**。结果就是：QQ 的帧确实送到了 relay，
> 然后被静默丢弃 —— 不报错、不崩溃，只是屏幕上什么都没有。
>
> 对比证据（同一台机器、同一时刻）：
>
> | | `./qq.sh`（无窗口） | `cocoa-wayctl launch QQ`（有窗口） |
> | --- | --- | --- |
> | `cocoa-wayctl displays` → `active` | **`[]`** | `[{display_slot: "rootless-qq", display_pid: …, waypipe_pid: …}]` |
> | waypipe client 连到 | 无（只有自己的 listener fd） | 每会话 socket `qq-<id>.sock-client-*.sock` |
> | QQ 窗口 | 不呈现 | 呈现 |
>
> 也就是说：**能显示的那条路走的是 Cocoa-Way 的会话机制
> （`presentation = "rootless"` + `profile = "single-app"`，由 compositor
> 分配 display slot），而 `wayland-launch.sh` 自己另写了一套并行的
> transport（`wl/wl-transport.pl` + `wl/host-relay.pl`），完全绕开了这套机制。**
> 它从不调用 `cocoa-wayctl` / `control.sock`（`grep` 结果为 0）。
>
> 要让 `qq.sh` 真正显示窗口，得让它走 Cocoa-Way 的会话/控制 API，而不是
> 自己拼 transport。这一步**尚未完成**。

## 症状

Wayland 模式下 `./qq.sh --display wayland` 启动后，窗口出现约一秒的**白屏**，
随后整个会话退出，日志尾部只有一句：

```
[wayland] shutting down
```

表面上看像是 Wayland 打通失败了。实际上 Wayland 是通的 —— 窗口确实被
创建并渲染过至少一帧 —— 真正的崩溃发生在更靠前的位置。

（本节及其后的三个真因描述的是「会话直接崩掉」这个已经修好的问题。
修完之后呈现的新症状是「不崩了，但也没有窗口」，见开头那段。）

## 三个独立的真因

故障是三个独立问题叠加的结果，任何单个问题都能单独杀死会话。它们之所以
难查，是因为**最终报错信息全部指向错误的方向**。

### 1. `/dev/shm` 只有 64 MB

Apple `container` 默认给容器的 `/dev/shm` 只有 64 MB，而 Chromium 的渲染
进程需要的远不止这些。渲染器在提交第一帧后不久就死掉。

```
$ container exec <name> df -h /dev/shm      # 默认 → 64M
$ container exec <name> df -h /dev/shm      # 传了 --shm-size 1G → 1.0G
```

`wayland-launch.sh` 从来没有传过 `--shm-size`，而那份**能正常工作**的
Cocoa-Way 配置（`~/.config/cocoa-way/container-sessions.toml`）里明确写了
`--shm-size 1G`，注释还专门说明「默认 64M 对 QQ 来说太小」。这正是
`cocoa-wayctl launch QQ` 能用、而仓库自带脚本不能用的原因之一。

**修复**：`wayland-launch.sh` 增加 `--shm-size`（新增 `QQ_SHM_SIZE` /
`--shm-size`，默认 1G），`qq.sh` 负责透传。

### 2. 没有 `/dev/dri`，Chromium 的 GPU 进程必死

容器里**根本不存在 `/dev/dri`**（Apple `container` 不提供 GPU 直通，
而且它的 VM 无法加载内核模块，所以也没法绕过）：

```
$ container exec <name> ls /dev/dri
ls: cannot access '/dev/dri': No such file or directory
```

Chromium 的 Wayland 后端仍然会去探测 DRM 渲染节点：

```
ERROR:ui/ozone/platform/wayland/common/drm_render_node_path_finder.cc:45]
    drmGetDevices2() has not found any devices: 没有那个文件或目录 (2)
ERROR:gpu/command_buffer/service/context_group.cc:130]
    ContextResult::kFatalFailure: WebGL1 blocklisted
```

GPU 进程死掉时，**它会把 Wayland 连接一起带走**。于是 waypipe 中止会话：

```
libwayland: wl_display#1: error 3: waypipe internal error
```

GTK 随即发现自己的 display 没了，抛出那句极具误导性的报错：

```
(qq:12): Gtk-ERROR **: Can't create a GtkStyleContext without a display connection
```

**修复**：Wayland 分支强制走软件渲染 —— `--disable-gpu`
`--disable-gpu-compositing` `--in-process-gpu` `--disable-dev-shm-usage`。

> `--in-process-gpu` 是关键：它让 GPU 工作不再作为一个**独立的、可以被杀死
> 的 Wayland 客户端**存在，因此它的失败不会连累 Wayland 连接。

#### 曾经走过弯路：Wayland 下「不传任何 GL 开关」

早期版本在 Wayland 下故意**不传** GL 开关，想让 Chromium 自己选到
`GLSurfaceEglReadbackWayland`（CPU 渲染 + 通过 `wl_shm` 上屏）。在有
DRM 节点的环境里这条路可行，但在没有 `/dev/dri` 的环境里它**是一场竞争**
（race）：有时能跑，有时 GPU 进程探测失败后整个会话被拆掉。这正是这个
bug 看起来「时好时坏」的原因。现已放弃该策略。

### 3. Crashpad 残留会毒死下一次启动

`/home/user/.config/QQ` 是从宿主机 bind mount 进来的，所以崩溃转储会跨次
运行累积，而且从来没有清理逻辑 —— 实测长到过 **764 MB**。

更麻烦的是，进程被强杀时 Crashpad 会在 `pending/` 里留下 `*.lock`，下一次
启动就直接失败：

```
ERROR:third_party/crashpad/crashpad/util/file/file_io_posix.cc:153]
    open /home/user/.config/QQ/Crashpad/pending/<id>.lock: File exists (17)
```

容器随即退出，看起来**和渲染／Wayland 毫无关系**，极容易误判成「又坏了」。

**修复**：`entrypoint.sh` 每次启动清空 `Crashpad/pending/`（含残留 lock），
保留 `completed/` 里已经归档的报告。

## 验证方式

不要只看进程活没活着，也不要拿 `fps` / `commits_per_second` 当判据 ——
空转的窗口本来就可能是 0。以**窗口服务器查询**为准：

```bash
./windows.sh          # 应能看到 QQ 自己的窗口（如「控制中心」）
```

一次健康的 Wayland 启动应当同时满足：

| 检查项 | 期望值 |
| --- | --- |
| `container ls` | 容器处于 running |
| `container exec <name> pgrep -c qq` | 5（而非 0） |
| 日志中 `forcing software GL` | 出现 1 次 |
| 日志中 `Gtk-ERROR` | 0 |
| 日志中 `waypipe internal error` | 0 |
| 日志中 `lock: File exists` | 0 |
| `--ozone-platform=wayland` | 出现，且**没有** X11 回退 |
| `du -sh QQ/Crashpad` | 几 KB 量级 |

## 已知假象

- **镜像／日志陈旧**：`--build` 之后立刻启动，可能跑的还是旧镜像，日志里会
  出现已经删掉的旧字符串（例如 `leaving GL implementation to Chromium`）。
  判断「修复是否生效」前，先确认镜像里真的有新代码：
  `container run --rm <image> -- /bin/sh -c 'grep -c "forcing software GL" /home/user/qq-wrapper.sh'`
- **日志是追加写的**：多次启动的日志混在一个文件里，靠后的 `Gtk-ERROR` 可能
  属于已经阵亡的那一次。排查前先 `rm -f /tmp/cocoa-way-qq/container.log`。
- **日志含 NUL 字节**，`grep` 会当二进制处理，需要 `grep -a`。

## 与 waypipe 版本无关

曾经怀疑是宿主 `waypipe 0.11.2` 与容器内 `waypipe 0.8.4` 的协议不匹配。
**这个方向是错的** —— 上述三个问题修完之后，0.11.2 ↔ 0.8.4 的组合工作正常，
无需在镜像里从源码编译新版 waypipe。

## 还有一个假象：进程活着 ≠ 有窗口

修完上面三点后，会话不再崩溃，`pgrep -c qq` 也能数到 5 个进程，
`windows.sh` 里甚至能看到一个 `cocoa-way 800x632` 的窗口 —— 但那**是
compositor 自己的空窗口**，不是 QQ。

所以判断「到底有没有显示出来」，不能只看进程数或窗口列表里出现了
`cocoa-way`，而要直接问 compositor 有没有为这次会话分配 display：

```bash
cocoa-wayctl --json displays     # active 必须是非空，且 display_slot 形如 rootless-qq
cocoa-wayctl --json applications # state 必须是 Running
```

`displays` 的 `active` 是 `[]` 而 `windows.sh` 里有个 `cocoa-way` 窗口 ——
这就是「看起来可以、实际没显示」的典型状态。
