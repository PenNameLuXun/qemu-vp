# 入口脚本：Makefile / build.sh / start.sh / run.sh

> 仓库根有四个入口：`Makefile` + 三个壳脚本（`build.sh` / `start.sh` /
> `run.sh`）。本文整理它们各自负责什么、互相之间是什么关系、以及
> `run.sh` 的全部参数和它读写的环境变量。
>
> 项目仓库：<https://github.com/PenNameLuXun/qemu-vp>
> 本文路径：<https://github.com/PenNameLuXun/qemu-vp/blob/main/entry-scripts.md>

## 一、四个入口的定位

| 入口 | 类型 | 用途 | 是否能脱离其他入口独立用 |
|---|---|---|---|
| `Makefile` | 实质构建/启动逻辑 | source of truth — 所有 build/run target 的实际 recipe 都在这里 | 是 |
| `./build.sh X` | 薄壳脚本 | `≡ make build-X`，子命令一对一映射 | 是（不依赖 Makefile，但功能子集 < Makefile） |
| `./start.sh X` | 薄壳脚本 | `≡ make run-X`，外加 `--clean` / `--clean-all` | 是（不依赖 Makefile，但功能子集 < Makefile） |
| `./run.sh MODE` | 进阶 GUI wrapper | 给 JXL Linux GUI 模式的"日常使用"封装：预制 VNC/SDL 组合、`-p PORT` 端口覆盖、host 上的 virgl/WSLg 自动探测 | 否，最终 `exec make run-jxl-linux` |

四者关系：

```
                          Makefile
                       (recipe 实体)
                            ▲
                ┌───────────┼───────────┐
                │           │           │
            build.sh     start.sh     run.sh
            (dispatch)   (dispatch)   (preset env + dispatch)
                                          │
                                          ▼
                                   make run-jxl-linux
                                          │
                                          ▼
                                       QEMU
```

`build.sh` / `start.sh` 是手动写的 `case "$1" in ... esac` 分发到对应的
make target，没有自己的构建逻辑（早期是先有壳脚本、后把逻辑迁进
Makefile 的，所以保留作为友好入口）。

`run.sh` 比 `start.sh` 多了一层：它**只针对 `run-jxl-linux` 这一个
target**，把常用的 VNC/SDL 组合、显卡设备、host 上的 virglrenderer
预备工作打包好，然后透传到 make。

## 二、`Makefile`

仓库的 source of truth。所有 target 都直接写在 recipe 里，没有外部
build system 包裹。

最常用的 target：

```bash
make help                          # 列全部 target
make build-all                     # 一次性把 jxl 完整链路所需都构建出来
make build-qt-gui-demo             # ~30 min 首次（两轮 Qt 6 跨编译）
make build-qtwayland               # Wayland QPA plugin（依赖 build-qt-host + build-qt）
make build-weston-sysroot          # 把 Ubuntu weston:arm64 .debs 解到 build/weston-sysroot/
make run-jxl-linux                 # 起 QEMU 走完整的 U-Boot → Linux
make run-jxl-linux-gui             # 同上 + 默认 VNC :0（works on WSL2）
make run-jxl-optee                 # SPL → BL31 → OP-TEE → U-Boot → Linux
make run-jxl-xen-optee             # SPL → BL31 → OP-TEE → U-Boot → Xen → Dom0
make clean                         # 清固件 / U-Boot / jxl artifact，保留 kernel/rootfs cache
make distclean                     # wipe 整个 build/
```

全部 `build-*` / `run-*` target 在 `make help` 输出里。每个 target 的
作用、镜像来源、启动链详情见 [jxl-run-modes.md](jxl-run-modes.md)。

## 三、`build.sh`

```bash
./build.sh {qemu|virt|raspi3b|jxl|jxl-dtb|tfa|xen|optee|kernel|busybox|rootfs|initramfs|qt-host|qt|qt-demo|all}
```

每个子命令映射到对应的 `make build-X`。比如 `./build.sh kernel`
等价于 `make build-kernel`。

设计上是 Makefile 的功能子集 —— 仓库后续加入的 target（如
`build-qtwayland`、`build-weston-sysroot`、`build-glmark2`、`build-qt-gui-demo`）
没有都补回到 build.sh，因为 Makefile 才是 source of truth。
**新功能优先走 `make build-X`**。

## 四、`start.sh`

```bash
./start.sh [--clean|--clean-all] {virt|raspi3b|jxl|jxl-linux|jxl-linux-spl|jxl-xen|jxl-xen-atf|jxl-optee|jxl-xen-optee|linux}
```

子命令对应 `make run-X`。多了两个清缓存开关：

- `./start.sh --clean MODE` ≡ `make clean && make run-MODE`
- `./start.sh --clean-all MODE` ≡ `make distclean && make run-MODE`

跟 `build.sh` 一样，新功能优先走 Makefile —— 比如
`run-jxl-linux-gui` / `run-jxl-linux-sdl` 这两个不在 `start.sh` 的子命令
列表里，要么用 `make run-jxl-linux-gui`，要么就直接用 `run.sh`。

## 五、`run.sh`

`./run.sh` 是仓库里**对一次完整的 "起 guest + 看到 Qt GUI" 体验**做
封装的最高层入口。所有模式最终都 `exec make run-jxl-linux`，不同
之处只是预先 export 了不一样的 `JXL_QEMU_DISPLAY` / `JXL_GPUDEV` /
`SDL_VIDEODRIVER`，让 Makefile 看到的 QEMU 命令行就是该模式想要的
形态。

### 5.1 模式列表

```bash
./run.sh MODE [-p PORT] [extra make args...]
```

| MODE | 显示后端 | guest 见到的 fb / GPU | 何时用 |
|---|---|---|---|
| `gui-pl111` (`pl111` / `fb1`) | VNC | `/dev/fb1` (PL111) | 看 PL111 LCD controller 真路径 |
| `gui-virtio` (`virtio` / `fb0`) | VNC | `/dev/fb0` (virtio-gpu) | **默认推荐**，能跑所有三种 Qt 后端 |
| `gui-virtio-gl` (`virtio-gl` / `gl`) | VNC + EGL headless | virtio-gpu **gl** (host OpenGL 加速) | 需要 host virglrenderer 加速 |
| `sdl-virtio-gl` (`sdl-gl`) | SDL (Wayland) | virtio-gpu gl | 原生 Linux 桌面，无需 VNC 客户端 |
| `sdl-virtio-gl-x11` (`sdl-gl-x11`) | SDL (X11) | virtio-gpu gl | 上面那条在 Wayland 桌面下黑屏时的备选 |
| `gui-dual` (`dual`) | 两个 VNC | 同时挂 `/dev/fb1` + `/dev/fb0` | 对比 PL111 和 virtio-gpu 两套链路 |
| `sdl-pl111` (`sdl`) | SDL | `/dev/fb1` | 原生 Linux 桌面看 PL111（WSL2 上黑屏，不推荐）|
| `headless` (`none`) | 无 | 无 | 纯串口 shell，不需要 GUI |

每个 MODE 都有几个别名（如 `pl111` ≡ `fb1` ≡ `gui-pl111`），方便 muscle
memory；canonical 是 `gui-*` / `sdl-*` 形式。

### 5.2 `-p PORT` 端口覆盖

默认 VNC 端口是 5900（`vnc :0`）。WSL2 上 Windows 内核会动态保留
5xxx / 6xxx 端口段（Hyper-V / Docker / IIS 等抢占），QEMU 启动时偶尔
会报 `Failed to find an available port`。`-p PORT` 让你换一个：

```bash
./run.sh gui-virtio -p 7900       # VNC :2000 — 监听 127.0.0.1:7900
./run.sh gui-virtio -p=7900       # 等价写法
./run.sh gui-dual -p 7900         # 第一窗口 :2000=7900，第二窗口 :2001=7901
```

约束：`PORT >= 5900`（VNC display = port − 5900）。

`-p` 一定是 `run.sh` 自己消化、不会透传到 make。

### 5.3 透传给 make 的额外参数

`-p` 处理完之后，剩下所有参数原样透传给 `make run-jxl-linux`。比如
要加 host port-forward：

```bash
./run.sh gui-virtio -p 7900 \
    JXL_NETDEV='-netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0'
```

任何 Makefile 能读的变量（包括 `make` 自己识别的 `-j` / `V=1`）都
可以这么塞过去。

### 5.4 `run.sh` 读写的环境变量

下面这些都可以在调 `run.sh` 之前 `export`、或在命令行前缀：

| 变量 | 默认 | 作用 |
|---|---|---|
| `JXL_QEMU_DISPLAY` | 各 mode 自己设 | QEMU `-display` / `-vnc` / `-serial` 串 |
| `JXL_GPUDEV` | 各 mode 自己设 | QEMU `-device virtio-gpu-*` 串 |
| `JXL_INPUTDEV` | 默认带 virtio keyboard + virtio tablet | 设为空字符串可关掉 |
| `JXL_NETDEV` | 无 | 额外 `-netdev` + `-device virtio-net-device` 串 |
| `JXL_GL_DEBUG` | `0` | 设 `1` 打开 `LIBGL_DEBUG=verbose` / `EGL_LOG_LEVEL=debug` / `VIRGL_LOG_LEVEL=debug` / `VREND_DEBUG` 等一票 GL 诊断日志 |
| `SDL_VIDEODRIVER` | `wayland`（sdl-virtio-gl）或 `x11`（sdl-virtio-gl-x11） | 强制 SDL 用某个后端 |
| `LIBGL_ALWAYS_SOFTWARE` | WSL2 上自动设 `0`（让 mesa 走 d3d12 fallback）| 设 `1` 强制 host 软光栅 |
| `LD_LIBRARY_PATH` | 自动追加 `src/virglrenderer/build/src` | 让 QEMU 拿到本地 virglrenderer 1.1.1（系统 0.9.1 跑 Qt 6 GL 4.1 core 会炸 fence）|

### 5.5 host 上的自动探测

`run.sh` 启动时会做几件事，无须用户参与：

1. **检测本地 virglrenderer**：仓库内 `src/virglrenderer/build/src/libvirglrenderer.so.1` 存在就把它放到 `LD_LIBRARY_PATH` 最前。系统 libvirglrenderer 0.9.1（Ubuntu 22.04 自带）会让 Qt 6 GL 4.1 core profile 报 illegal fence object —— 这是踩过的坑。
2. **检测 WSLg**：看到 `/dev/dxg` 就把 mesa 切到 d3d12 fallback 路径。原因是 dxgkrnl 不暴露 KMS 节点，强制 DRI2 反而走不通；默认链 `vgem → kms_swrast → dxcore` 才能落到 d3d12_dri.so。
3. **default virtio-input**：`-device virtio-keyboard` + `-device virtio-tablet`（不是 mouse —— VNC 用绝对坐标，relative-mouse 会漂）。

## 六、关系图（再过一遍）

```
                ┌─────────────────────────────────┐
                │  Makefile  ← source of truth    │
                │  build-X / run-X / clean / ...  │
                └─────┬───────────┬──────────┬────┘
                      │           │          │
        ┌─────────────┘           │          └────────────────┐
        │                         │                           │
        ▼                         ▼                           ▼
   build.sh X            start.sh X (+ --clean)        run.sh MODE [-p P]
   case→make             case→make                     case→preset env→make
                                                       run-jxl-linux
                                                                │
                                                                ▼
                                                              QEMU
                                                                │
                                                                ▼
                                                  guest jxl shell
                                                       │
                                                       ▼
                                              ./qt-gui-demo.sh ...
                                              (linuxfb / eglfs / wayland)
```

`run.sh` 是日常用得最多的（GUI 模式），但它**永远不会比 Makefile 强**
—— 任何 Makefile 能做的事，`run.sh` 后面 cat 一下 `make run-jxl-linux`
的 recipe 都能复现出来。当 `run.sh` 不够灵活时（比如要换 QEMU
machine、要走 Xen 路径），直接 `make run-jxl-xen` / `make run-jxl-xen-optee`
等等。

## 七、相关文档

- [README.md](README.md) — 项目入口、子目录布局、快速上手
- [jxl-run-modes.md](jxl-run-modes.md) — JXL 各启动模式的 QEMU 参数、启动链、镜像来源、地址布局，以及 `build-X` 各 target 产生什么
- [jxl-qt-display-backends.md](jxl-qt-display-backends.md) — `./qt-gui-demo.sh {linuxfb|eglfs|wayland}` 三种后端的渲染路径
- [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) — guest 内核侧 fbcon / VT / DRM 显示链路
