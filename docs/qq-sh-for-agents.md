# qq.sh — agent 使用手册

面向自动化调用者（agent / CI / 脚本）。人工阅读请走 [`README.md`](../README.md)。

`qq.sh` 是仓库里**唯一**需要调用的入口。它负责推导配置、必要时构建镜像、准备运行环境，最后启动 QQ。下面所有断言都在本机实测过，含退出码和输出流行为。

---

## 0. 调用契约（先看这段）

| 事项 | 事实 |
| --- | --- |
| 幂等性 | 是。没加 `--build` 时不会构建镜像；VM/容器已存在则复用。 |
| 输出流 | **全部写 stderr**。stdout 恒为空（实测 dry-run：stdout 0 字节 / stderr 421 字节）。 |
| 退出码 | `0` 成功；`1` 任何错误（含参数校验、构建失败、运行时拒绝）。没有其它码。 |
| 交互 | 非交互。不需要 TTY。**不会**提问。 |
| 副作用 | 加 `--build` 会构建镜像；`--pkg local` 会在仓库根目录**临时**落一个 `qq-local-package.deb` 并在构建后删除（已在 `.gitignore`）。 |
| 工作目录 | 任意。脚本自己 `cd` 到仓库根，但 `--pkg-path` 的相对路径**按调用时的 cwd 解析**。 |
| 前置依赖 | `container`（runtime=container）或 `limactl`（runtime=lima）；Wayland 路径另需 `cocoa-way`。 |

**给 agent 的建议**：先跑 `--dry-run` 拿计划，确认无误再真跑。计划全部在 stderr，别只读 stdout。

---

## 1. 三个决策轴

配置由三个轴确定，轴之间**有硬性约束**（见 §4）：

| 轴 | 取值 | 默认 |
| --- | --- | --- |
| `--runtime` | `container` \| `lima` | `container` |
| `--display` | `wayland` \| `x11` | `wayland` |
| `--arch` | `amd64` \| `arm64` | `amd64` |

外加 `--pkg`（`url` \| `local` \| `apt`，默认 `url`）决定 linuxqq 来源。

### 组合合法性矩阵（实测）

| runtime | display | `--dry-run` | 真跑 |
| --- | --- | --- | --- |
| `container` | `wayland` | 通过 | 可用（推荐） |
| `container` | `x11` | 通过 | 可用 |
| `lima` | `x11` | 通过 | 可用 |
| `lima` | `wayland` | **通过** | **拒绝**，退出 1 |

注意最后一行：`lima + wayland` 的拒绝发生在**运行阶段**，`--dry-run` 不会报错。**别用 `--dry-run` 成功与否来判断该组合能否真跑。**

`--arch` 两种取值在两种 runtime 下都可用（语言的实现差别见 §3）。

---

## 2. 常用命令

```bash
# 先看计划，不产生任何副作用
./qq.sh --dry-run

# 默认：Apple container + Wayland + 官方 amd64 deb（首次需 --build）
./qq.sh --build

# 原生 arm64，不需要 Rosetta
./qq.sh --arch arm64 --build

# X11 替代 Wayland
./qq.sh --display x11

# lima VM + X11（lima 下唯一可用显示）
./qq.sh --runtime lima --display x11 --arch arm64 --build

# 用本地已有 .deb 构建（自动从 control 元数据读架构）
./qq.sh --pkg local --pkg-path ~/Downloads/linuxqq_3.2.34-53644_arm64.deb --build

# 用发行版仓库的包（非腾讯官方构建、无版本锁定）
./qq.sh --pkg apt --build

# 全量显式（agent 推荐：不依赖任何默认值）
./qq.sh --runtime container --display wayland --arch arm64 \
        --pkg url --cpus 4 --memory 4g --build
```

---

## 3. 参数表

每个选项都有 `QQ_` 前缀的环境变量等价形式；**flag 优先于 env**（已实测：`QQ_ARCH=amd64 ./qq.sh --arch arm64` → arm64）。

### runtime

| 选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `-r, --runtime <container\|lima>` | `QQ_RUNTIME` | 运行位置，默认 `container` |
| `--vm-type <vz\|krunkit>` | `QQ_VM_TYPE` | 仅 lima，默认 `vz`。`krunkit` 无 Rosetta 且 GPU 实测不可用，除非有明确理由否则别碰 |
| `--lima-os <template>` | `QQ_LIMA_OS` | 仅 lima，默认 `debian-12` |
| `--proxy <url\|off>` | `QQ_PROXY` | 仅 lima，默认 `inherit`。lima 会把宿主代理注入 guest，常导致 apt 502；`off` = 清除，或给 URL 覆盖 |
| `-n, --name <name>` | `QQ_NAME` | 容器 / VM 名，默认按 arch+display 推导（如 `qq-amd64-wayland`、`qq-limavm-amd64`） |

### display

| 选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `-d, --display <wayland\|x11>` | `QQ_DISPLAY` | 默认 `wayland`。wayland = Cocoa-Way（无 X11 键盘记录面）；x11 = XQuartz over TCP |

### package

| 选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `-p, --pkg <url\|local\|apt>` | `QQ_PKG` | 默认 `url`（腾讯官方包，sha512 锁定） |
| `--pkg-path <file.deb>` | `QQ_PKG_PATH` | `--pkg local` 时必填；相对路径按**调用时 cwd** 解析 |
| `-a, --arch <amd64\|arm64>` | `QQ_ARCH` | 默认 `amd64`。`--pkg local` 时从 deb 的 control 元数据自动读取（**包总是胜出**，与显式 `--arch` 冲突时打 `warn:` 并跟随包） |

### Rosetta

| 选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `--rosetta` | `QQ_ROSETTA=1` | 强制开 |
| `--no-rosetta` | `QQ_ROSETTA=0` | 强制关 |

**默认是 auto，通常不该设。** 规则：vz 后端无法运行异构架构 guest，所以 amd64 guest **必须**开 Rosetta，arm64 guest **必须**关。显式设置会做一致性校验并在冲突时报错。

### 资源与其它

| 选项 | 环境变量 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--cpus <n>` | `QQ_CPUS` | `4` | vCPU |
| `--memory <size>` | `QQ_MEMORY` | `4g` | 内存，接受 `4g` / `4GiB` / `4096m` / `3`；lima 内部换算成裸 GiB |
| `--shm-size <size>` | `QQ_SHM_SIZE` | `2g` | `/dev/shm`，仅 container |
| `--ime` | `QQ_ENABLE_IME=1` | 关 | 在 guest 内启动 fcitx5 |
| `--extra-args <args>` | `QQ_EXTRA_ARGS` | — | 透传给 QQ |
| `--tz <zone>` | `QQ_TZ` | `Asia/Shanghai` | 时区 |
| `--build` | — | 关 | 先构建镜像 / 准备 VM |
| `--dry-run` | — | 关 | 打印计划后退出 0 |
| `-h, --help` | — | — | 帮助 |

---

## 4. 约束与坑（agent 必须知道）

### 4.1 `--arch` 在 lima 下的真实语义

lima 的 `--arch` 词汇是 `x86_64` / `aarch64`（不是 docker 的 `amd64` / `arm64`），且 **vz 无法创建异构架构 VM** —— `limactl create --arch x86_64` 直接报 `unsupported arch`。

后果：**本机（Apple Silicon）上所有 lima VM 都是 aarch64**。`--arch amd64` 意味着**在 aarch64 VM 里跑 amd64 容器**，靠 Rosetta 翻译，与 Apple `container` 完全同构。脚本已按此模型实现，你不需要关心，但别指望 lima 能给出 x86_64 guest。

### 4.2 lima 构建的默认代理会坏

lima 把宿主代理（如 `192.168.5.2:7890`）注入 guest。该代理常对 apt 返回 502，表现为构建**中途**随机失败（实测：下完 290 MB 依赖后整步失败）。

**lima 构建失败时先加 `--proxy off` 重试**，这是最高频的假故障。

### 4.3 `--pkg local` 的 arch 推导与三个历史坑

`--arch` 与包内 `Architecture` 冲突时，**包总是胜出**，只打一行 `warn:`：

```
warn: local package says Architecture=arm64 but --arch=amd64; following the package
  arch      : arm64 (linux/arm64)
```

即 agent 若刻意要某一架构，不要指望 `--arch` 压过包；要换架构就换包。

三个历史坑（已修，勿改回）：

1. 暂存文件名**不能点开头**。POSIX glob 的 `*` 不匹配开头的点，`ls /tmp/local-qq/*` 会看到空目录，apt 便把这名字当**包名**去仓库装发行版 `linuxqq`。
2. 必须用**单一显式** `LINUXQQ_SOURCE` 选源，不能"测试哪个变量非空"——否则一个零字节占位文件就能静默改道。
3. Debian 的 **GID 20 已被 `dialout` 占用**（恰是 macOS 宿主 GID），`groupadd -g 20 user` 会失败；属主必须用数字 ID 而非 `user:user`。

### 4.4 参数解析器的限制

手写解析器（macOS BSD `getopt` 不支持长选项，不引入 Homebrew 依赖）：

- 值必须**空格分隔**：`-r lima` ✅ / `-rlima` ❌（报 `unknown option`）
- 长选项支持 `=` 形式：`--runtime=lima` ✅
- 不支持短选项黏连

### 4.5 镜像改动不落盘

`container cp` 改 `qq-wrapper.sh` **不会持久化**，必须 `./qq.sh --build` 重建。

---

## 5. 输出解析

`--dry-run` 的计划（全部在 stderr）形如：

```
QQ launch plan
  runtime   : container
  display   : wayland
  arch      : amd64 (linux/amd64)
  rosetta   : yes (required for amd64 on vz)
  package   : url
              https://...linuxqq_3.2.34-53644_amd64.deb
  image     : mac-qq-docker:amd64
  name      : qq-amd64-wayland
  resources : 4 cpus, 4g ram, 2g shm
  ime       : off

==> dry run: not launching
```

注意 `resources` 是**一行聚合**（cpus / ram / shm），不是三个独立字段；结尾有 `==> dry run: not launching`。

agent 建议用 `2>&1 | grep` 抓字段，例如断言架构：

```bash
plan="$(./qq.sh --arch arm64 --dry-run 2>&1)"
grep -q '^  arch *: arm64' <<<"$plan" || { echo "计划不符" >&2; exit 1; }
```

**错误信息统一为 `error: ...` 前缀**，可直接按前缀分流：

```bash
if ! out="$(./qq.sh --dry-run 2>&1)"; then
    echo "qq.sh 失败: $(grep -m1 '^error:' <<<"$out")" >&2
fi
```

---

## 6. 错误分支速查（实测文案）

| 触发 | stderr |
| --- | --- |
| 未知选项 | `error: unknown option: --nope (try --help)` |
| `--runtime` 非法取值 | `error: --runtime must be container or lima (got 'bogus')` |
| lima + wayland | `error: lima + wayland is not wired up yet.`（**只在运行时报，`--dry-run` 不报**） |
| krunkit + amd64 | `error: krunkit cannot run an amd64 guest on this host:` |
| arm64 + `--rosetta` | `error: --rosetta given but the guest is arm64; Rosetta only translates` |
| `--pkg local` 缺 `--pkg-path` | `error: --pkg local needs --pkg-path <file.deb>` |
| `--pkg-path` 非 .deb | `error: --pkg-path must be a .deb file (got '/etc/hosts')` |
| `--pkg-path` 不存在 | `error: no such file: <abs-path>` |

全部退出码 `1`。

---

## 7. 验证构建是否真的是你要的包

构建后**务必**核对包来源。曾出现过"指定本地包却装了发行版包"的静默改道。

```bash
# Apple container
container run --rm mac-qq-docker:arm64 -- /bin/sh -c \
  'dpkg -s linuxqq | grep -E "^(Version|Maintainer|Architecture)"'
```

（会先打印 `[0/6] ...` 拉取/启动进度，以及 entrypoint 的几行日志；真结果在后面。）

期望（`--pkg local` 传腾讯官方 arm64 包时）：

```
Maintainer: Tencent <QQ-Team@tencent.com>
Architecture: arm64
Version: 3.2.34-53644
```

lima：

```bash
limactl shell qq-limavm-arm64 -- podman run --rm mac-qq-docker:arm64 -- \
  /bin/sh -c 'dpkg -s linuxqq | grep -E "^(Version|Architecture)"'
```

`--pkg apt` 时 `Maintainer` **不是** Tencent —— 这正是需要警惕的情况。

---

## 8. 相关文件

| 路径 | 作用 |
| --- | --- |
| `qq.sh` | 统一入口（本手册对象） |
| `Dockerfile` | 镜像定义；包源由 `LINUXQQ_SOURCE` 单一参数选择 |
| `entrypoint.sh` | 容器内后端选择（`QQ_DISPLAY_BACKEND` = `x11` \| `wayland`） |
| `qq-wrapper.sh` | 容器内 QQ 启动包装（GL 开关等） |
| `wayland-launch.sh` | Wayland 路径实现，被 `qq.sh` 调用 |
| `.env` | 环境默认值（`USER_ID`/`GROUP_ID`/`X11_PORT` 等） |
| `docs/gpu-research.md` | GPU 调研（为何不追 virtio-gpu / krunkit Venus） |

---

## 9. 给 agent 的最小推荐流程

```bash
set -euo pipefail
cd ~/projects/mac-qq-docker

# 1. 计划（无副作用）
./qq.sh --runtime container --display wayland --arch arm64 --dry-run

# 2. 构建（首次或改了 Dockerfile/wrapper 后）
./qq.sh --runtime container --display wayland --arch arm64 --build

# 3. 核验包来源
container run --rm mac-qq-docker:arm64 -- /bin/sh -c \
  'dpkg -s linuxqq | grep -E "^(Version|Maintainer)"'
```

需要 lima 时：把 `--runtime container --display wayland` 换成 `--runtime lima --display x11`，并在构建失败时先加 `--proxy off` 重试。
