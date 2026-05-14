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

> **WSL 下 egl-kms-gbm 跑不起来** —— 见 § 十九，WSL2 是 headless，
> `/dev/dri/card0` 通常不存在；只能在物理机或带显示设备的 KVM/QEMU 里测。
> 本项目的 JXL VM 满足这个条件（virtio-gpu 注册了 `/dev/dri/card0` +
> KMS），qt-gui-demo 在里面跑的就是同一条 EGL/GBM/DRM 路径。

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
