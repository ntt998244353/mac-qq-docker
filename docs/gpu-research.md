# GPU / 图形加速调研记录

本文记录本项目为 QQ 争取 GPU 加速所做过的全部调研与实测，包括**已经证伪的方向**。
结论先行：**在当前环境下 QQ 拿不到任何可用的 GPU 加速路径**，软件渲染是唯一可用方案。
保留本文的目的是避免以后有人（包括我自己）重复走这些死路。

原始实测证据（dmesg / vulkaninfo 输出）另存于同目录
[`krunkit-gpu-facts.txt`](./krunkit-gpu-facts.txt)。

---

## 0. 先分清两件事

讨论 GPU 时最容易混淆的是「QQ 跑在哪个 VM」和「哪个 VM 有 GPU」。这两个是不同的问题：

| | Apple `container` VM | lima `krunkit` VM |
|---|---|---|
| 有 GPU 吗 | **没有，而且加不了** | **有，而且默认就开** |
| 为什么 | `container-apiserver` 没有任何 graphics-device 配置 API（二进制层面确认过） | krunkit（libkrun）默认启用 virtio-gpu |
| 能用吗 | 谈不上 | **当前不能**（见 §3 上游 bug） |

**QQ 现在跑在 Apple `container` VM 里**，所以 QQ 的实际情况是「第一列的没有」。

---

## 1. Apple `container`：VM 内无 GPU，且无 API 可加

- VM 内**没有 `/dev/dri` 节点**（整个目录都不存在，不是权限问题）。
- VM 内核是固定的、**不可加载内核模块**（实测无 `/lib/modules`、无 `/proc/modules`、
  无 `insmod`/`lsmod`/`modinfo`）。
- `container-apiserver` 二进制里**没有任何 graphics-device 配置类**
  （无 `VZGraphicsDeviceConfiguration` 相关类），CLI 也没有 `--gpu`/`--dri`/`--device` 选项。

这是一个**产品层面的缺失**，不是配置问题。想改只能给上游提 feature request。

---

## 2. lima `krunkit`：确实有 GPU，默认开启（事实澄清）

CNCF 博客（Lima v2.0 新特性）与 lima 官方文档说 krunkit 能给 guest 提供 GPU、
llama.cpp 能把 Apple 芯片识别为虚拟 GPU——**这些说法都是对的**。已在 krunkit 源码逐行核实：

`containers/krunkit` 的 `src/context.rs` 里**无条件**执行：

```rust
// Temporarily enable GPU by default
let virgl_flags = VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL;
krun_set_gpu_options2(id, virgl_flags, vram);
```

即每个 krunkit VM 启动时**默认就带 GPU**，不需要 lima 传任何 `--device` 参数。
所以 lima 的 `Cmdline()` 里看不到 GPU 相关 flag 是**正常的**，
`nerdctl run --device /dev/dri` 能工作也是真的。

要点：

- **Venus（Vulkan）专供**：`VIRGLRENDERER_NO_VIRGL` 明确**关掉了传统 OpenGL/virgl 路径**，
  只暴露 Vulkan。
- VRAM 按宿主内存自动分配（上限受 64 GB IPA 地址限制）。

> **早期误判的教训**：我们一度得出「krunkit 没有 GPU」的错误结论。原因是只看了
> `src/virtio.rs` 里 `--device virtio-gpu,...` 这个 **CLI 字符串解析**分支——它确实落到
> `_ => Ok(())`，注释还写着「virtio-gpu … currently not configured in krun」。但那是一个
> **旧的 2D framebuffer/scanout 占位，未实现**；真正的 3D GPU 是在 `context.rs` 里
> **默认就在跑**的。两者是两回事。

---

## 3. 实测结论：krunkit 的 GPU 当前**完全不可用**

「有没有」是有；关键在于「能不能用」。本项目**实际装了 krunkit 并在 VM 里跑完所有探测**。

**环境**：Apple M5 Pro / macOS 26.6.2，lima 2.2.0，krunkit 1.3.2，libkrun 1.19.6，
libkrunfw 5.6.2，virglrenderer-krun 0.10.4e，molten-vk 1.4.2，
guest Ubuntu 24.04.5 arm64，Mesa 25.2.8，libvulkan1 1.3.275。

### 3.1 `/dev/dri` 确实存在

```
/dev/dri/card0       (226,0)
/dev/dri/renderD128  (226,128)
[drm] features: +virgl +edid +resource_blob +host_visible +context_init
[drm] Initialized virtio_gpu 0.1.0 0
[drm] KMS disabled        <-- 没有 scanout/显示输出能力
```

### 3.2 但 Vulkan (Venus) 连 instance 都建不起来

```
$ VN_DEBUG=all vulkaninfo --summary
MESA-VIRTIO: using DRM device /dev/dri/renderD128
MESA-VIRTIO: connected to renderer            <-- 已经通到宿主的 renderer 了
MESA-VIRTIO: wire format version 1
MESA-VIRTIO: vk xml version 1.3.252
MESA-VIRTIO: VK_MESA_venus_protocol spec version 1
MESA-VIRTIO: failed to allocate/map ring shmem    <-- 死在这里
MESA-VIRTIO: vn_CreateInstance: VK_ERROR_OUT_OF_HOST_MEMORY
ERROR: vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY
```

guest dmesg 里对应的内核错误（每次尝试都报）：

```
[drm:virtio_gpu_dequeue_ctrl_func] *ERROR* response 0x1200 (command 0x208)
[drm:virtio_gpu_dequeue_ctrl_func] *ERROR* response 0x1200 (command 0x209)
```

（`0x208`/`0x209` = `RESOURCE_CREATE_BLOB` / `CONTEXT_INIT`；`0x1200` = `ERR_UNSPEC`。）

guest 内核广告的 capset 也印证 Venus 已退化：

```
cap set 0: id 1 (VIRGL)        max-version 1, max-size 308
cap set 1: id 2 (VIRGL2)       max-version 2, max-size 1384
cap set 2: id 4 (VENUS)        max-version 0, max-size 156   <-- 退化/stub
cap set 3: id 6 (DRM)          max-version 0, max-size 0
cap set 4: id 5 (CROSS_DOMAIN) max-version 0, max-size 16
```

### 3.3 根因：上游 libkrun blob 对齐 bug（issue #114）

已由上游维护者确认（`libkrun/krunkit` issue **#114**，2026-08-08 建，2026-08-24 由维护者
slp 关闭）。标题：

> *virtio/gpu: host-visible blob mappings fail unless the size is a multiple of
> 16384 on macOS, breaking Mesa's Venus driver in guests*

机制：

- Apple Silicon 的 **VM page size = 16384**。
- `resource_map_blob` 把**未对齐**的 `resource.size`（135168）直接传进
  `HvfVm::map_memory` → `hv_vm_map()`，因非 16384 对齐被拒 → `ErrUnspec` →
  guest `mmap` 返回 `EINVAL` → `VK_ERROR_OUT_OF_HOST_MEMORY`。
- Venus 的 ring shmem = **131268 字节**（guest 4 KiB 页圆整成 135168 = 33×4 KiB），
  需要 144 KiB 才能让宿主映射成功。

维护者原话：

> *"Since 7.2, the kernel provides a way for userspace to read the minimum alignment
> requirements for the virtio-gpu driver (`VIRTIO_GPU_F_BLOB_ALIGNMENT`). We need to
> extend Mesa to make use of it align the BOs as required. **We can't fix this from
> neither krunkit nor libkrun.**"*

即：**krunkit/libkrun 侧修不了，必须改 guest Mesa。**

**唯一 workaround**：用 slp 的下游补丁重新编译 **guest Mesa**（4 处 hunk 都需要）：
<https://gitlab.freedesktop.org/slp/mesa/-/commit/761ef1ec5ff2aae1cc3dc8bbc22b3d06ef04b549>

（注：只改 `vn_ring.c` 那一处能过 `vkCreateInstance`，但紧接着会在设备内存分配时再失败，
所以 4 处都要。）

---

## 4. 关于「Vulkan 可直接从 DRM 分配 GBM 并显示、不需要 GL/EGL」

这个说法**本身成立**（`VK_EXT_image_drm_format_modifier` + `VK_KHR_display` /
`VK_EXT_acquire_drm_display`，Venus 也确实有 no-GL 模式）。但在 krunkit 上这条路
**当前根本走不到**：Vulkan instance 就建不起来（见 §3.2）。

而且**即使 Venus 修好了**，仍有额外障碍：

- **`[drm] KMS disabled`** —— 这块 virtio-gpu **没有 scanout/显示输出**，是 render-only
  设备，「通过 DRM 直接显示」在 guest 内不成立（只能当离屏/headless 渲染节点）。
- **Qt/Electron 的实际渲染路径不是 Vulkan**。QQ(NT) 是 Electron，Linux 下窗口合成走
  GL/EGL/GBM；就算 Vulkan 可用，也得 QQ/Chromium 主动走 Vulkan 后端（`--use-vulkan`）
  才谈得上受益。而 krunkit 用 `VIRGLRENDERER_NO_VIRGL` **把 OpenGL 路径关了**。

所以「Venus-on-krunkit + Electron 显示合成」是一个**没有验证过**的组合，
不是一条已知可行的路。

---

## 5. 即使 GPU 修好，把 QQ 搬到 krunkit 仍有别的成本

1. **没有 Rosetta**（Rosetta 是 lima `vz` 驱动专有，krunkit 不接）。搬过去就必须用
   **原生 aarch64 QQ**——好消息是官方确实有 arm64 包（见 [README](../README.md) 的
   「接入方式说明：Rosetta」）。
2. **lima 的 krunkit 驱动是外部驱动、仍为 experimental，且 `CanRunGUI=false`**
   （没有 GUI 集成）。搬过去得自己在 guest 里搞 Wayland/compositor（把 cocoa-way 那套
   搬进 guest，或 guest 里跑 Weston），属于**原型级工作量**。

本项目实测创建过一个 `qq-gpu-test` krunkit 实例；若要继续实验，它保留在
`~/.lima/qq-gpu-test`（配置见该目录下 `lima.yaml`）。

---

## 6. 已排除的备选：GPU-over-IP（remote-virtio-gpu 桥）

**思路**：把 GPU 渲染拆成 server/client。`rvgpu-renderer` 在一台有 GPU 的 Linux 主机上
渲染；`rvgpu-proxy`（app 侧）通过加载 `virtio-gpu` + `virtio-lo`（自研
`virtio-loopback-driver` 内核模块）在本地**新建一个 `/dev/dri/cardX` 节点**，经 TCP
（默认 55667）把绘制命令转发到 server 端真实 GPU。

**结论：客户端在 `container` VM 里无法工作。** 决定性阻断：

- `rvgpu-proxy` 必须 `modprobe virtio-gpu; modprobe virtio-lo` 加载内核模块才能创建
  `/dev/dri/cardX`。
- 但 Apple `container` VM 的内核**固定、不可加载模块**（见 §1）。没有 `virtio-lo`，
  `cardX` 节点根本造不出来，client 侧直接死掉。
- 两个端点都必须是 Linux（server 要 mesa/virgl/GBM/EGL/Wayland + `virtio-lo` 模块，
  **macOS 当不了 server**）。且 virgl+TCP 对交互式 QQ 延迟不理想（官方建议 1 Gbps 网络），
  QQ 是否真的吃这个 DRM/virgl 节点也无人验证。

---

## 7. 小结

| 路线 | 能否给 QQ 拿到 GPU | 阻断点 |
|---|---|---|
| 现状（`container` + Wayland / X11） | ❌ | VM 无 GPU，且无法加（无 API） |
| lima `krunkit` | ❌（已实测） | 有 `/dev/dri`，但 **Venus 当前完全不可用**（上游 #114：ring shmem 16384 对齐 bug）；`KMS disabled`；`NO_VIRGL` 关了 GL；无 Rosetta |
| GPU-over-IP | ❌ | `container` VM 无法加载 `virtio-lo` 内核模块 |

**对本项目实际可用的真相**：即使 GPU 完全用不上，QQ 在 cocoa-way 下的渲染仍然正常——
Electron 会回退到软件 GL（`GLSurfaceEglReadbackWayland`，wl_shm readback）。
这个「无 GPU」路径是目前**已验证可用**的方案，对聊天应用足够。

---

## 8. 如果还想继续拔

按价值排序：

1. **在 guest 里用 slp 的 Mesa 补丁重编 Mesa**（§3.3 的 commit，4 处 hunk），然后
   `vulkaninfo --summary` 和 `vkcube` 看能否成功。这是唯一可能突破 Venus 的路径。
   能成功再谈 GBM/DRM/KMS（注意目前 KMS 是关的）。
2. **给 Apple `container` 提 feature request**，要求暴露 VZ 的 graphics device 配置。
   这是让 QQ 在 `container` 里直接获得 GPU 的唯一正路。
3. **等 Cocoa-Way 支持给 rootless 会话提供虚拟渲染节点**。

在做到其中任何一步之前，把 QQ 搬到 krunkit **不会带来任何 GPU 收益**，
只会引入一个 experimental、无 GUI 集成的外部驱动。
