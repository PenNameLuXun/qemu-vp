# Linux TTY / fbcon / DRM 显示链路与 vt-restore 原理

> 项目场景：QEMU 自制 ARM64 SoC（JXL），bootargs `console=tty0 console=ttyAMA0`，
> 同时跑 fbcon 文字 console（→ VNC 窗口）和 Qt eglfs 图形 GUI（→ 同一 VNC 窗口）。
> 本文整理 vt-restore 工具的原理，以及它背后涉及的 TTY/VT/fbcon/DRM 知识。

## 一、TTY 是什么 — 三种典型 tty

"TTY" 历史上是 teletypewriter（电传打字机），现在指 Linux 里"终端"的统一抽象 ——
一类字符设备，加上行规程（line discipline）。主要三种：

| 类型 | 设备节点 | 物理来源 |
|---|---|---|
| 串口 tty | `/dev/ttyAMA0` `/dev/ttyS0` | 真实 UART 硬件 |
| 伪终端 (pty) | `/dev/pts/N` + `/dev/ptmx` | 用户空间模拟（SSH/xterm/screen 等）|
| 虚拟控制台 (VT) | `/dev/tty1..tty63` + `/dev/tty0` | 内核内置"屏幕+键盘"终端，由 `drivers/tty/vt/` 提供 |

本项目里同时存在两类：
- `/dev/ttyAMA0` — QEMU 的 PL011 UART → `-serial mon:stdio` → 宿主机终端
- `/dev/tty1` — VT，由 fbcon 渲染到 framebuffer → VNC/SDL 窗口
- `/dev/console` — 特殊别名，指向 bootargs 里**最后一个** `console=` 参数

## 二、VT 子系统 — 内核里的"伪屏幕"

VT 是 Linux 在 X 出现之前就有的概念：

- 内核在内存里维护多个 VT 缓冲区，每个就是一块字符矩阵（行 × 列 × 字符 + 属性）
- 任意时刻只有**一个** VT 是 active（在屏幕上显示）
- `/dev/tty0` 是个魔法别名，永远指当前 active VT；`chvt N` 切换
- 共享同一物理显示器 + 键盘

VT 有两个关键运行状态 —— 也就是 `vt-restore` 要改的两个 ioctl：

### `KDSETMODE` — 渲染模式

```
KD_TEXT     ← 默认。内核 fbcon 持续把 VT 字符缓冲渲染到屏幕
KD_GRAPHICS ← 用户空间接管。fbcon 闭嘴，让 X/Qt/eglfs 自己画
```

### `KDSKBMODE` — 键盘模式

```
K_UNICODE/K_XLATE ← 默认。kbd handler 把按键翻成 UTF-8/locale 字符，
                    送进 active VT 的输入缓冲；shell read /dev/tty1 拿到
K_RAW             ← 原始 scancode 直接给 VT 读者
K_MEDIUMRAW       ← 已映射成 KEY_* 的 keycode 给 VT 读者
K_OFF             ← 完全不送。kbd handler 照常处理事件，但不喂 VT。
                    Qt eglfs 用这个，自己 read /dev/input/event* 拿
```

## 三、fbcon — VT 的"显卡驱动"

`fbcon`（`drivers/video/fbdev/core/fbcon.c`）是 VT ↔ framebuffer 的桥：

```
   VT 字符缓冲(内存)                        framebuffer(内存)
   ┌─────────────────┐                      ┌────────────────┐
   │ H e l l o w o   │                      │ 像素位图        │
   │ ~ # _ . . . .   │  ───fbcon 用内置──►  │ ████ █ █ █     │
   │ . . . . . . .   │     8×16 位图字体    │ █  █ █ █ █     │
   └─────────────────┘     做光栅化         └────────────────┘
```

工作机制：

1. 任意 fb 注册（来自 fbdev 驱动或 DRM fbdev emulation）
2. fbcon 通过 `FB_NOTIFY` 机制收到通知
3. 当前 VT 若在 `KD_TEXT`，fbcon 接管这块 fb，开始绘制字符
4. 内核 printk + shell 输出 → VT 缓冲 → fbcon → fb → 屏幕

dmesg 里看到的 `Console: switching to colour frame buffer device 80x30` 就是
fbcon 接管的时刻。

## 四、日志显示链路（log → 窗口）

bootargs `console=tty0 console=ttyAMA0` 注册了两个 kernel console。printk 同时写两边：

```
                    ┌──── pl011 UART tx ──► QEMU -serial mon:stdio ──► 宿主机终端
                    │                                                     (打字的地方)
   ┌─────────┐      │
   │ printk  │──────┤
   └─────────┘      │
                    │     ┌─ 写入 active VT(tty1) 字符缓冲
                    └────►│         ↓
                          │ fbcon: 字符 → 位图
                          │         ↓
                          │ /dev/fb0 (virtio_gpudrmfb)
                          │         ↓
                          │ DRM fbdev emulation:
                          │   DRM_IOCTL_MODE_DIRTYFB
                          │         ↓
                          │ virtio-gpu DRM 驱动:
                          │   TRANSFER_TO_HOST_2D + RESOURCE_FLUSH
                          │         ↓ virtqueue
                          │ host QEMU virtio-gpu 设备
                          │         ↓ 更新内部 pixmap
                          └─► VNC server → VNC client 窗口
```

特点：**走 VT 层，用内核位图字体，性能不高但通用**。每个 printk 都同步走完这条链。

## 五、图像显示链路（Qt eglfs → 窗口）

Qt eglfs 完全**绕开** VT/fbcon：

```
   Qt eglfs 进程
       │
       ├─ open("/dev/dri/card0")         ← DRM 子系统
       ├─ drmSetMaster(fd)               ← 抢 KMS 控制权
       ├─ 枚举 connector → CRTC → plane → mode
       ├─ gbm_create / dma-buf 申请 GPU buffer
       ├─ EGL/GL 在 buffer 上绘制（CPU 或 GPU）
       ├─ drmModeAddFB / drmModePageFlip ← 设为 scanout
       │
       ▼
   DRM core → virtio-gpu 驱动
       │
       │  RESOURCE_CREATE_2D + SET_SCANOUT
       │  TRANSFER_TO_HOST_2D + RESOURCE_FLUSH
       ▼ virtqueue
   host QEMU virtio-gpu → 同一个 pixmap → VNC/SDL
```

特点：**走 DRM/KMS，用 GPU/CPU 绘制，性能高，全帧 page-flip 切换**。

## 六、两条链路冲突 — 为什么 Qt 要"借走" VT

整个虚拟机里 physical resource 只有一份：一块 framebuffer、一个键盘流。
fbcon 和 Qt 都要：

|  | fbcon (内核里) | Qt eglfs (用户态) |
|---|---|---|
| 想画什么 | VT 字符 | 自己 GUI |
| 屏幕所有权 | `KD_TEXT` 时一直占 | 把 VT 切 `KD_GRAPHICS`，自己接 |
| 键盘流 | `K_UNICODE` 时塞 VT | 把 VT 切 `K_OFF`，自己读 evdev |
| DRM | 通过 fbdev emulation 间接占 | `drmSetMaster` 显式接管 |

所以 Qt eglfs 启动序列大致是：

```c
fd = open("/dev/tty1", O_RDWR);
ioctl(fd, KDSETMODE, KD_GRAPHICS);   // 让 fbcon 别画了
ioctl(fd, KDSKBMODE, K_OFF);         // 让 VT 不收键盘了
drmSetMaster(card0);                 // KMS 我接管了
// ... GUI 主循环 ...
// 正常退出时反向还原
ioctl(fd, KDSKBMODE, K_UNICODE);
ioctl(fd, KDSETMODE, KD_TEXT);
drmDropMaster(card0);
```

`SIGTERM/SIGKILL` 把它一刀切掉时，"反向还原"这步永远不会跑 → tty1 卡在
`KD_GRAPHICS + K_OFF`，表现就是 VNC 窗口里 fbcon 不再画字、按键也送不到 shell。

## 七、`vt-restore` 干了什么

就两行 ioctl，等于把 Qt 没做的"还原"步骤补做一遍：

```c
fd = open("/dev/tty1", O_RDWR);
ioctl(fd, KDSETMODE, KD_TEXT);       // fbcon 重新接管，开始刷字符
ioctl(fd, KDSKBMODE, K_UNICODE);     // kbd handler 重新送字符进 tty1
close(fd);
```

执行后：

- fbcon 看到 `KD_TEXT`，扫一遍 VT 字符缓冲重新画到 fb → VNC 窗口里 shell prompt 重现
- 按键 → 内核 input subsystem → kbd handler → `K_UNICODE` 翻成字符 → tty1
  input buffer → `/bin/sh` 的 read 解阻塞 → 可交互

为什么 busybox 没现成的？因为这种工具传统上在 `kbd` 包里（叫 `kbd_mode` /
`setvtmode`），busybox 极简路线把它归到"嵌入式没必要"，干脆不收。

## 八、对照本项目两条路径

**`./run.sh gui-virtio` 启动后**：

- printk 经 `console=tty0` → tty1 → fbcon → fb0 (virtio_gpudrmfb) → host QEMU → VNC 窗口出现 boot log
- init 脚本 fork 两个 shell：
  - 主：`/dev/console = ttyAMA0` → 串口 → 宿主机终端
  - 副：`/dev/tty1`（`setsid -c` 让 tty1 成它的 ctty）→ 通过 fbcon 投到 VNC

**VNC 里跑 `./qt-gui-demo.sh eglfs`**：

- Qt 把 tty1 切 `GRAPHICS + OFF` → fbcon 停画，VNC shell 看起来"卡住"
- Qt 接管 DRM，自己往 fb0 上画 GUI → VNC 窗口里出现 Qt demo
- 那个 VNC shell 还在，只是输出看不见、输入收不到

**Qt 正常退出**：自己还原 → VNC shell 复活
**Qt 被 kill (SIGTERM)**：`qt-gui-demo.sh` 的 `trap cleanup EXIT INT TERM HUP`
触发 → wrapper 调用 `vt-restore /dev/tty1` → 同上还原
**Qt 被 kill -9 (SIGKILL)**：没机会 trap → 串口里手动 `vt-restore /dev/tty1`
→ 还原

## 九、相关代码索引

- `demo/vt-restore/main.c` — 工具源码（30 行）
- `Makefile`
  - `$(VT_RESTORE_BIN)` 构建规则
  - `$(ROOTFS_STAMP)` 加 `vt-restore` 依赖 + 拷到 `/usr/bin/`
  - `qt-gui-demo.sh` launcher heredoc 的 `trap cleanup EXIT INT TERM HUP`
- `dts/jxl.dtsi` — `bootargs = "console=tty0 console=ttyAMA0 ..."`，让 printk 同时写
  fbcon 和串口

## 十、扩展阅读

- Linux 内核源码：`drivers/tty/vt/vt.c`、`drivers/tty/vt/keyboard.c`、
  `drivers/video/fbdev/core/fbcon.c`
- Linux 内核文档：`Documentation/fb/fbcon.rst`、`Documentation/admin-guide/kernel-parameters.txt`（`fbcon=` 参数）
- ioctl 头：`include/uapi/linux/kd.h`（`KDSETMODE` `KDSKBMODE` 等定义）
- Qt 源码：`qtbase/src/plugins/platforms/eglfs/api/qeglfsintegration.cpp`
  里能看到对应的 VT 接管/还原代码
