# EGL backend 示例：X11 / Wayland / KMS+GBM

本目录三个 demo 展示同一件事 —— "在屏幕上画一个会变色的矩形" ——
但走 EGL 的三种不同 backend。读者可以并排对比 **EGL 怎么跟外部的"显示
载体"挂钩**，加深对 `jxl-tty-fbcon-display.md` § 十八（Mesa / X11 /
Wayland）那节的理解。

> 三个 demo 渲染的内容完全相同（`glClearColor` 加 sin/cos 调色），
> 不同点全在**初始化 EGL 之前**那一段 —— 也就是"如何拿到一个能交给
> mesa 的 native display + native window"。

## 三个 backend 的对比一览

```
┌─────────────────────────────────────────────────────────────────────────┐
│ backend       连谁                谁分配 buffer       谁 scanout         │
├─────────────────────────────────────────────────────────────────────────┤
│ egl-x11       X server (Xorg)     mesa (DRI3)         X server          │
│ egl-wayland   Wayland compositor  mesa (GBM)          compositor        │
│ egl-kms-gbm   /dev/dri/card0      自己 (GBM)          自己 (drmModeSet) │
└─────────────────────────────────────────────────────────────────────────┘
```

具体到代码，关键差异就在以下三行（每个 demo 都会用到，但实参不同）：

| API | egl-x11 | egl-wayland | egl-kms-gbm |
|---|---|---|---|
| `eglGetDisplay(?)` | `Display *` (Xlib) | `struct wl_display *` | `struct gbm_device *` |
| native window | `Window` (X11 XID) | `struct wl_egl_window *` | `struct gbm_surface *` |
| 显示载体 | X server 的 window | wl_surface | DRM CRTC + connector |

剩下的 GL 调用（`glClear` / `eglSwapBuffers`）三个 demo 完全一样 —— mesa
对上层屏蔽了 backend 差异，这也正是 EGL 设计的意义。

## 每个 demo 大概有什么

```
demo/other/
├── README.md              ← 你正在看的这份
├── egl-x11/
│   ├── main.c             ← ~110 行，Xlib + EGL
│   └── Makefile
├── egl-wayland/
│   ├── main.c             ← ~150 行，wl_compositor + xdg-shell + EGL
│   └── Makefile           ← 用 wayland-scanner 生成 xdg-shell 胶水代码
└── egl-kms-gbm/
    ├── main.c             ← ~200 行，DRM + GBM + EGL + page-flip
    └── Makefile
```

## 环境要求（构建+运行）

| demo | 构建依赖 | 运行环境要求 |
|---|---|---|
| egl-x11 | `libx11-dev libegl1-mesa-dev libgles2-mesa-dev` | X server 运行中（`DISPLAY=:0`）。WSL 下走 WSLg 的 XWayland 也行 |
| egl-wayland | `libwayland-dev wayland-protocols libegl1-mesa-dev libgles2-mesa-dev` | Wayland compositor 运行中（`WAYLAND_DISPLAY=wayland-0`）。WSL 下 WSLg 提供 weston |
| egl-kms-gbm | `libdrm-dev libgbm-dev libegl1-mesa-dev libgles2-mesa-dev` | **裸机或 VM 内**有 `/dev/dri/card0`；**没有其它进程持有 DRM master**（即不在 X/Wayland 桌面里跑）；通常需要 root |

## WSL2 上能跑哪些？—— 实测

WSL2 比 "完全 headless" 要复杂一点：它**有** `/dev/dri/card0`，但那是
**vgem**（Virtual GEM Provider），只提供 GPU buffer 分配，**没有 KMS**
（没有 connector、CRTC、可设的 mode）。WSLg 在用户态跑一个 weston
compositor，把所有 Wayland/X11 客户端的渲染结果通过 RDP 送回 Windows
桌面 —— 不依赖任何"真正的"显示输出。

```
WSL2 实测（Ubuntu 22 + 最近 WSL 版本）：

DISPLAY=:0                    ✓  WSLg 的 XWayland
WAYLAND_DISPLAY=wayland-0     ✓  WSLg 的 weston
/dev/dri/card0                ✓  driver=vgem (虚拟 GPU buffer)
/dev/dri/renderD128           ✓  渲染 node (走 d3d12 → Windows GPU)
/dev/dri/card0 上的 KMS       ✗  drmModeGetResources 返回 NULL (ENOTSUP)
/dev/fb*                      ✗  完全没有 framebuffer 节点
/dev/dxg                      ✓  WSL 私有 D3D12 内核接口
```

| demo | WSL2 上 | 备注 |
|---|---|---|
| **egl-x11**     | ✅ 跑通 | 渲染走 vgem buffer → WSLg → RDP → Windows 弹窗 |
| **egl-wayland** | ✅ 跑通 | Wayland 协议直接给 WSLg weston，零拷贝 dma-buf |
| **egl-kms-gbm** | ❌ 跑不了 | vgem 无 KMS，`drmModeGetResources` 返 NULL，demo 报 "no connected connector" 退出 |

**这正好印证了 § 十八 / § 十九 的核心区分**：

* WSL 给了你**渲染能力**（vgem + dxgkrnl + d3d12 mesa → 跑 GL/Vulkan 没问题）
* WSL 没给**显示能力**（无 KMS connector/CRTC —— VM 根本没接虚拟显示器）

所以前两个 demo 能跑（它们把渲染交给 display server 处理上屏），
KMS+GBM demo 跑不了（它要"自己 scanout"，但没有可 scanout 的输出）。

要想看第三个 demo 跑起来，三种选择：

1. **跑进本项目的 JXL VM**：virtio-gpu 在 JXL 里注册了完整的 KMS（connector
   + CRTC + mode），qt-gui-demo 在里面跑的就是同一条 EGL/GBM/DRM 路径。
   把 demo 交叉编译进 rootfs（Makefile 仿 `demo/qt-gui-demo` 加进
   `ROOTFS_INIT_BODY` 即可）。
2. **物理机 Linux + free VT**：Ctrl-Alt-F3 切到 tty3 登录，确保 X/Wayland
   session 没占住 DRM master，`sudo ./egl-kms-gbm-demo` 即可。
3. **物理机 KVM/QEMU**：起一个有 virtio-gpu 的 VM，里面跑。

## 怎么构建运行

```sh
# Debian/Ubuntu 上一次装齐
sudo apt install libx11-dev libwayland-dev wayland-protocols \
                 libdrm-dev libgbm-dev libegl1-mesa-dev libgles2-mesa-dev \
                 pkg-config

# 编译
make -C demo/other/egl-x11
make -C demo/other/egl-wayland
make -C demo/other/egl-kms-gbm

# 跑
DISPLAY=:0          ./demo/other/egl-x11/egl-x11-demo            # X11
WAYLAND_DISPLAY=wayland-0 ./demo/other/egl-wayland/egl-wayland-demo  # Wayland
sudo                ./demo/other/egl-kms-gbm/egl-kms-gbm-demo    # KMS+GBM（需独占 DRM）
```

## 读 demo 的建议顺序

1. **egl-x11** 最短，先看清"native display = X Display *，native window
   = X Window XID"是怎么塞进 EGL 的。
2. **egl-wayland** 注意 `wl_egl_window` 这个**中间层** —— Wayland 协议
   本身不传 buffer，需要这个 mesa 提供的"假窗口"对象。
3. **egl-kms-gbm** 最长，因为没有 display server 帮忙，**KMS 翻页要应用
   自己做**（`drmModeSetCrtc` + `drmModePageFlip`）—— 这就是 Qt eglfs
   在做的事，本项目 JXL 跑 qt-gui-demo 时也是同一条路径。

读完三个 demo，可以回去再读一遍 `jxl-tty-fbcon-display.md` § 十八，
对照应该会清晰很多。
