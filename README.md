# uboot-learn

本仓库用来在本地 QEMU 上从零拼一条 ARM64 引导链，并把 firmware / SPL /
TF-A / OP-TEE / U-Boot / Xen / Linux / BusyBox / Qt 一段段串起来跑通。
所有组件都以子模块形式直接收纳进仓库，构建/启动逻辑由仓库内的
`Makefile` 一次性管完（`build.sh` / `start.sh` 是它的薄壳），没有
外部脚本和系统依赖外的设定。

主要用途：

- 教学 / 学习路径：从最小 `virt` U-Boot 一直堆到 `SPL → BL31 → OP-TEE → U-Boot → Xen → Dom0 Linux` 的完整安全 + 虚拟化链路
- 端到端调试：在同一台机器、同一份代码里走完 boot → kernel → userspace → Qt GUI
- 自定义 SoC 实验：仓库带一个虚构的 `jxl` 板级（QEMU machine + U-Boot board + Linux DTB），用作"自己造一个 SoC"的练习靶子

## 仓库布局

仓库根目录是构建/启动的入口（`Makefile` / `build.sh` / `start.sh`），所有
源码、子模块和构建产物分布如下：

| 路径 | 类型 | 作用 |
|---|---|---|
| `Makefile` | 入口 | 仓库内构建/启动逻辑的 **source of truth**。`make help` 列全部 target。所有依赖关系都写在 recipe 里，没有外部 build system 包裹 |
| `build.sh` | 入口（薄壳）| `./build.sh X` ≡ `make build-X`。子命令分发到对应 make target |
| `start.sh` | 入口（薄壳）| `./start.sh X` ≡ `make run-X`。额外支持 `--clean` / `--clean-all` 在启动前先清缓存 |
| `run.sh` | 入口（薄壳）| 给 JXL Linux GUI 模式的简易 wrapper，封装常见 VNC/SDL 组合，支持 `-p PORT` 覆盖 VNC 端口（WSL2 端口冲突兜底）|
| `qemu/` | 子模块 | QEMU fork。包含自定义 `jxl` machine（CPU/SRAM/SoC 模型 + PL111 LCD controller 改造）|
| `src/u-boot/` | 子模块 | U-Boot fork。多了 `jxl_defconfig` + 板级支持，能同时跑 direct boot / SPL / FIT 三种路径 |
| `src/linux/` | 子模块 | Linux 6.6.y（gregkh/linux 镜像）|
| `src/busybox/` | 子模块 | BusyBox，静态链接进 initramfs |
| `src/trusted-firmware-a/` | 子模块 | TF-A，`PLAT=jxl`。两套构建（有 SPD / 无 SPD），分别用于 OP-TEE 链和非 OP-TEE 链 |
| `src/optee_os/` | 子模块 | OP-TEE，`PLATFORM=vexpress PLATFORM_FLAVOR=jxl` |
| `src/xen/` | 子模块 | Xen，`arm64_defconfig` |
| `src/qtbase/` | 子模块 | Qt 6.8 跨编译源码，给 Qt GUI demo 用 |
| `src/qtwayland/` | 子模块 | Qt Wayland QPA plugin（v6.8.3 tag），让 GUI demo 能作为 wayland client 跑 |
| `src/virglrenderer/` | 子模块 | 本地 virglrenderer 1.1.1，给 SDL/Wayland 路径上的虚拟 GPU 用 |
| `src/glmark2/` | 子模块 | glmark2-es2-drm / glmark2-es2-gbm 基准测试 |
| `dts/` | 资产 | Linux 用的独立设备树（`jxl.dts` + 各 overlay：OP-TEE / Xen）。注意这套 DTB **不等同于** U-Boot 内嵌的 `src/u-boot/arch/arm/dts/jxl.dts` |
| `demo/qt-demo/` | 资产 | 一个 headless Qt 6 DNS lookup demo，验证 Qt cross-build 链 |
| `demo/qt-gui-demo/` | 资产 | 一个 Qt 6 GUI demo，能在 linuxfb / eglfs / wayland 三种 backend 下跑同一个二进制 |
| `demo/vt-restore/` | 资产 | 小工具：恢复 tty 的 `KD_TEXT` + `K_UNICODE`，用来在 Qt eglfs 被强杀后恢复 fbcon |
| `build/` | 构建输出 | 所有构建产物（kernel Image、U-Boot 各阶段、TF-A、Xen、OP-TEE、initramfs、各种 MMC / NOR flash 镜像、qt 安装树、weston sysroot 等）。全部 git-ignored |
| `*.md` | 文档 | 仓库根的若干学习笔记，见 [#相关文档](#相关文档) |

## 入口与快速上手

仓库根有四个入口（详见 [entry-scripts.md](entry-scripts.md)）：

| 入口 | 用途 |
|---|---|
| `Makefile` | source of truth — 所有 build/run target 的实际 recipe，`make help` 列全部 |
| `./build.sh X` | `≡ make build-X`（薄壳）|
| `./start.sh X` | `≡ make run-X`，外加 `--clean` / `--clean-all` |
| `./run.sh MODE` | GUI 专用 wrapper：预制 VNC/SDL 组合、`-p PORT` 端口覆盖、virgl/WSLg 自动探测 |

最快开搞：

```bash
make help                 # 列出全部 target
make build-all            # JXL 完整链路所需的全部产物（耗时较长，首次 ~1h）
make run-jxl-linux        # 起 QEMU 走 U-Boot → Linux 的最简单路径
```

### 推荐路径：第一次跑 Qt GUI demo

下面这套是日常用得最多、覆盖最完整（U-Boot → Linux → virtio-gpu → Qt
wayland）的路径，从零开始约 1 小时构建。

#### 1. 构建（首次较慢）

```bash
make build-qt-gui-demo            # 两轮 Qt 6 跨编译，host + target，~30 min
make build-qtwayland              # Wayland QPA plugin
make build-weston-sysroot         # 把 weston:arm64 .deb 一票拉进 build/weston-sysroot/
```

#### 2. 启动 guest

默认 VNC 端口是 5900。WSL2 上 Windows 内核会动态保留 5xxx/6xxx 端口段
（Hyper-V/Docker 抢占），所以推荐用 `-p` 换到 7900 或更高：

```bash
./run.sh gui-virtio -p 7900
```

启动后会打印 `[run] VNC :2000 -> virtio-gpu (/dev/fb0), connect to 127.0.0.1:7900`，
表示 QEMU 已经在 `127.0.0.1:7900` 监听 VNC 连接。

#### 3a. 在 WSL2（Windows host）上连 VNC

Windows 侧装 **RealVNC Viewer**（<https://www.realvnc.com/connect/download/viewer/>），
启动后在地址栏填：

```
127.0.0.1:7900
```

弹出 unencrypted connection 提示直接 continue 即可（127.0.0.1，回环网络，
没有 TLS 必要）。

#### 3b. 在 Ubuntu（native）上连 VNC

任挑一个 VNC 客户端：

```bash
# Remmina（GNOME / KDE 桌面默认推荐，UI 友好）
sudo apt install remmina remmina-plugin-vnc
remmina -c vnc://127.0.0.1:7900

# 或 TigerVNC（命令行更直接）
sudo apt install tigervnc-viewer
xtigervncviewer 127.0.0.1:7900
```

如果在 Wayland 桌面下不想走 VNC，也可以让 QEMU 直接开 SDL 窗口：

```bash
./run.sh sdl-virtio-gl              # SDL/Wayland 窗口，virtio-gpu virgl 路径
```

#### 4. 进入 guest，跑 demo

VNC 连上后看到的是 jxl rootfs 的串口 shell。跑 Qt GUI demo：

```sh
~ # ./qt-gui-demo.sh wayland          # 起 weston，demo 作为 wayland client（推荐）
# 或:
~ # ./qt-gui-demo.sh virtio           # 最薄的 linuxfb 路径，秒级启动
~ # ./qt-gui-demo.sh eglfs            # OpenGL ES + KMS+GBM
```

Wayland 首次启动约 20–30 秒（emulated llvmpipe 编 GL shader），后续会快。
三种后端的差别详见 [jxl-qt-display-backends.md](jxl-qt-display-backends.md)。

---

详细的启动模式 / 构建产物 / 镜像布局 / 启动链对比见
[jxl-run-modes.md](jxl-run-modes.md)。`run.sh` 全部参数和 env 变量见
[entry-scripts.md](entry-scripts.md)。

## 当前已打通的链路

- `QEMU → U-Boot`
- `QEMU → U-Boot → Linux`
- `QEMU → SPL → U-Boot proper → Linux`
- `QEMU → U-Boot proper → Xen → Dom0 Linux`
- `QEMU → SPL → BL31 → U-Boot proper → Xen → Dom0 Linux`
- `QEMU → SPL → BL31 → OP-TEE → U-Boot proper → Linux`
- `QEMU → SPL → BL31 → OP-TEE → U-Boot proper → Xen → Dom0 Linux`
- U-Boot 从 MMC ext4 分区加载 Linux / Xen payload
- SPL 通过 FIT 装载 BL31 + U-Boot proper
- SPL 通过 FIT 装载 BL31 + OP-TEE + U-Boot proper
- PL111 framebuffer + DRM/KMS + fbdev emulation，Qt 6 linuxfb demo 可在 VNC 中渲染
- virtio-gpu + Mesa llvmpipe + KMS+GBM，Qt 6 eglfs demo 走 OpenGL ES 路径
- Weston (drm-backend) + qtwayland，Qt 6 demo 作为 wayland client 在 tty2 上跑

## 相关文档

- [entry-scripts.md](entry-scripts.md) — 四个入口（Makefile / build.sh / start.sh / run.sh）的定位、相互关系、`run.sh` 全部模式 + `-p PORT` 参数 + 它读写的环境变量（`JXL_QEMU_DISPLAY` / `JXL_GPUDEV` / `JXL_INPUTDEV` / `JXL_NETDEV` / `JXL_GL_DEBUG` 等）以及 host 上的 virgl / WSLg 自动探测
- [jxl-run-modes.md](jxl-run-modes.md) — JXL 各启动模式（`virt` / `raspi3b` / `jxl` / `jxl-linux` / `jxl-linux-spl` / `jxl-xen` / `jxl-xen-atf` / `jxl-optee` / `jxl-xen-optee` / `linux`）的 QEMU 参数、启动链、镜像来源、地址布局，以及构建产物（每个 `build-X` target 输出什么）和启动链对比表
- [uboot-boot-chain.md](uboot-boot-chain.md) — U-Boot 的 SPL / proper 启动链笔记：链接脚本差异、重定位、global\_data、init\_fnc\_t 函数表、ATF + OP-TEE 安全启动扩展、ARM 异常级别等
- [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) — Linux TTY / VT / fbcon / DRM 显示链路全展开：`KDSETMODE` / `KDSKBMODE` 双 ioctl、fbcon 与用户态显示的冲突、`vt-restore` 工具原理、内核启动三个显示阶段、固件早期接力、串口 vs framebuffer 谁负责光栅化、fbdev/fbcon/linuxfb 三概念辨析
- [jxl-qt-display-backends.md](jxl-qt-display-backends.md) — Qt 三种显示后端（linuxfb / eglfs+KMS+GBM / wayland）在 JXL 上的渲染管线追踪、buffer 拷贝次数、tty 占用、启动序列对比，含 Weston 在 tty2 上启动而 VNC 仍展示 virtio-gpu scanout 的机制解释
- [jxl-atf-xen-plan.md](jxl-atf-xen-plan.md) — ATF + Xen 集成的早期规划文档（功能已基本落地）
