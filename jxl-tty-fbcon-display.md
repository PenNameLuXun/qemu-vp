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

## 九、内核启动时显示的三个阶段

"`console=tty0 + fbcon`" 这条链路并不是从 `t=0` 就工作的，整个启动过程分三段：

```
时间轴 ─────────────────────────────────────────────────────►
   t=0                t=fbcon_bind                t=init_takeover
    │                       │                          │
    ├───────┬───────────────┬──────────────────────────┤
    │ 阶段1 │     阶段2      │           阶段3          │
    │ 黑屏  │  fbcon 在画字  │  用户态可能接管          │
    │       │                │  (plymouth / Qt / X /    │
    │       │                │   fbcon 继续画)          │
```

### 阶段 1：fb 驱动还没起来 → 屏幕全黑

- 从 `start_kernel()` 到第一个 fb 驱动 probe 完成之间
- printk 此时走向：
  - `earlycon=...` → 串口 / EFI fb / debug UART（看得见）
  - `console=tty0` → 写进 VT 字符缓冲，但**没人渲染**（看不见）
- 早期日志只在串口能看到

### 阶段 2：fb 注册，fbcon 绑定

dmesg 关键标志：

```
[    1.576650] Console: switching to colour frame buffer device 80x30
[    1.617380] virtio-mmio a021000.virtio_mmio: [drm] fb0: virtio_gpudrmfb frame buffer device
```

此后 printk + VT 字符缓冲所有内容通过 fbcon 渲染到 fb 内存。`CONFIG_LOGO=y` 时
小企鹅 logo 也在此刻被 fbcon 顺带画到左上角。阶段 1 累积在 VT 里的日志大部分被
覆盖（缓冲有限）。

### 阶段 3：init 接管之后

看用户态做什么：

| 做什么 | fbcon 状态 |
|---|---|
| 啥都不做（busybox shell on tty1）| fbcon 继续工作 |
| plymouth / fbsplash | 用户态接管 fb，盖住 fbcon 输出 |
| Qt eglfs / X / Wayland | VT 切 `KD_GRAPHICS`，fbcon 闭嘴 |

### "fbcon 写 /dev/fb0" 的精度澄清

常见误解：fbcon 是不是 `open("/dev/fb0") + write()`？**不是**。

| 主体 | 怎么访问 fb |
|---|---|
| 用户态进程（Qt linuxfb、`dd of=/dev/fb0`）| 通过 `/dev/fb0` 设备节点 |
| fbcon（内核代码）| 直接调 `fb_ops` 里的 `fb_imageblit` 等函数指针 |

但**两者写的是同一块像素内存** —— `/dev/fb0` 的 mmap 把这块内存映射给用户态。
从结果（屏幕像素）看没区别，只是访问路径不同。

### 本项目实际时间线

```
t=0.000000  Booting Linux ...                       │ 阶段 1 (~1.5s)
t=0.014442  Console: colour dummy device 80x25      │ VT 起来但 fb 还没
t=0.015043  printk: console [tty0] enabled          │ console=tty0 注册成功
t=1.226007  [drm] Initialized virtio_gpu            │ DRM 驱动 probe
t=1.576650  Console: switching to colour frame...   │ ◄── 阶段 2 开始
t=1.617380  [drm] fb0: virtio_gpudrmfb              │
t=2.580892  EXT4-fs (mmcblk0p1): recovery complete  │ ...继续 boot
t=2.705518  Run /init as init process               │ ◄── 阶段 3 开始
            jxl rootfs up.                          │ tty1 上有 busybox shell
```

阶段 1 那 ~1.5 秒的日志只有串口能看到；VNC 窗口里看到的"半截"boot log 就是因为
阶段 1 内容根本没渲染。

## 十、串口 vs framebuffer —— 谁负责光栅化

前面 4、5 两节描了两条日志显示路径，还有一个本质区别没明说：
**"字符 → 像素"这步光栅化发生在哪边**。

### 串口路径：guest 只送字节，host 终端渲染

```
guest kernel printk("Hello\n")
         │
         │  字符字节: 0x48 0x65 0x6c 0x6c 0x6f 0x0a
         │  (UTF-8/ASCII，没有像素)
         ▼
guest pl011 UART 驱动 → QEMU 模拟的 PL011
         │
         ▼
QEMU -serial mon:stdio → host stdout pipe
         │
────── host/guest 边界 ──────
         │
host 终端模拟器 (Windows Terminal / xterm / iTerm2 / ...)
         │  1. 读字节流
         │  2. 解析 ANSI/VT100 转义序列 (颜色/光标/清屏)
         │  3. 用 host 字体光栅化 → 像素
         │  4. 通过 host GUI 系统画到窗口
         ▼
host 屏幕
```

**关键：传输的是字节，host 终端模拟器做光栅化。**

### framebuffer 路径：guest 已经把像素准备好了

```
guest kernel printk("Hello\n")
         │
         ▼
VT 字符缓冲 + fbcon 用内核 8×16 位图字体光栅化
         │  得到一堆像素
         ▼
DRM fbdev emulation → virtio_gpu DRM 驱动 → virtqueue
         │  搬运的是像素数据
         ▼
────── host/guest 边界 ──────
         │
host QEMU virtio-gpu pixmap → VNC server / SDL backend
         │  raw 像素照搬，不"理解"内容
         ▼
host VNC client / SDL 窗口
```

**关键：传输的是像素，host 只负责显示。**

### "终端模拟器" 是什么

host 上的进程关系：

```
host 进程树:
  Windows Terminal (或任何终端) ───── 终端模拟器（emulator）
    └── bash
          └── ./run.sh ...
                └── qemu-system-aarch64 ─── stdout pipe
                                            连终端模拟器的输入
```

"终端模拟器"这名字来自历史：1970~80 年代有物理终端（VT100、VT220，xterm 最早
是 X terminal 硬件）。后来用程序"模拟"它们的行为：

| 老物理终端 | 现代终端模拟器 |
|---|---|
| 物理屏幕 | 一个 GUI 窗口 |
| 阴极射线管 + 硬件 ROM 字体 | TTF/OTF + harfbuzz 渲染 |
| 串口物理线缆 | pipe / pty |
| 解释 VT100 escape 控制硬件 | 解释 VT100 escape 控制窗口 |

启动日志里的彩色 `[  OK  ] Started ...` 是这样实现的：

```
guest 发出的原始字节:
  \x1b[32m[  OK  ]\x1b[0m Started ...

host 终端模拟器解读:
  \x1b[32m  → 切换前景色为绿色
  [  OK  ]  → 渲染（绿色）
  \x1b[0m   → 还原默认色
  Started   → 渲染（默认色）
```

### 两条路径的"谁干活"对比

| 工作 | 串口/终端路径 | framebuffer 路径 |
|---|---|---|
| 字符 → 像素光栅化 | **host 终端模拟器** | **guest 内核 fbcon** |
| 字体来源 | host TTF/OTF | guest 内核位图字体 (8×16) |
| 颜色/光标控制 | host 解释 ANSI 转义 | guest fbcon 实现 VT 控制 |
| guest → host 传什么 | 字符字节 + ANSI 转义 | 像素数据 |
| 带宽消耗 | 极低（一行 ~几十字节）| 高（一帧 800×600×4 ≈ 1.9MB）|
| host 是否理解内容 | 是（解析 escape）| 否（raw 像素照搬）|
| 字体好不好看 | 看 host 终端的字体设置 | guest 内核字体（默认很丑）|

### 推论

- **服务器/嵌入式默认走串口**：guest 只塞字节，省力省带宽
- **同一份日志，串口窗口和 VNC 窗口里字体不一样**：渲染方完全不同
- **串口日志能 grep**：本来就是文本；VNC 截图只能 OCR
- **彩色 systemd 启动消息**：guest 塞 `\x1b[32m`，host 终端上色
- **`screen` / `tmux` 也是终端模拟器**：在终端模拟器里又模拟了一层

## 十一、fbdev / fbcon / linuxfb —— 三个容易混的概念

前面几节交替出现"fbdev"、"fbcon"、"linuxfb"，它们的关系：

```
                       /dev/fbN
                  (fbdev 子系统提供的设备节点)
                          ▲
                          │ 读写、mmap、ioctl
              ┌───────────┴────────────┐
              │                        │
        fbcon (内核态)            linuxfb (用户态)
        kernel framebuffer       Qt 的 QPA 平台插件
        console                   "platform"
        把 VT 字符画到 fb         把 QWidget 画到 fb
        drivers/video/            qtbase/src/plugins/
          fbdev/core/fbcon.c        platforms/linuxfb/
```

| 名字 | 类别 | 干什么 |
|---|---|---|
| **fbdev** | 内核**子系统** | 提供 `/dev/fbN` 设备节点 + mmap + 基本 mode set ioctl |
| **fbcon** | 内核**消费者** | 把 VT 字符缓冲 + 内置位图字体 → 像素 → 写到 fb |
| **linuxfb** | 用户态**消费者** | Qt 的 QPA 插件，直接 mmap `/dev/fbN` 把 QWidget 画上去 |

两个消费者完全平行、互不知情；同时画同一块 fb 会互相覆盖。本项目里：

- `console=tty0` + fbcon → boot 日志显示路径
- `./qt-gui-demo.sh virtio` / `pl111` → 走 linuxfb (`QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0`)
- `./qt-gui-demo.sh eglfs` → **不**走 fbdev，走 DRM/KMS（见下一节）

## 十二、fbdev vs DRM/KMS —— 两代显示子系统

```
1999 -- fbdev (framebuffer device) ----------------- /dev/fbN
        一块线性像素 buffer + 简单 mode set
        够用了：CGA/VGA、嵌入式 LCD

2008 -- DRM/KMS (Direct Rendering Manager /
                  Kernel Mode Setting) ------------- /dev/dri/cardN
                                                     /dev/dri/renderDN
        多 buffer + page flip + GPU 命令队列 +
        DMA-BUF + 完整的 CRTC/connector/plane 模型
```

内核里两套并存，路径独立：

- `drivers/video/fbdev/` — fbdev 老接口
- `drivers/gpu/drm/` — DRM 新接口

### 关键区别

| 维度 | fbdev (`/dev/fbN`) | DRM/KMS (`/dev/dri/cardN`) |
|---|---|---|
| 缓冲数量 | 1 个，原地改 | 多个，page flip 切换 |
| Mode set | `FBIOPUT_VSCREENINFO`，弱 | CRTC + connector + plane + encoder，完整 |
| Vsync / 无撕裂 | 大多没有 | `drmModePageFlip` 原子切换 |
| 多进程共享 | 互斥占用 | DRM master + render node 分离 |
| GPU 渲染 | 没有概念 | GEM/BO 命令提交 |
| 跨进程零拷贝 | 没有 | DMA-BUF |
| 热插拔 | 弱 | uevent + 重新枚举 connector |
| Cursor / overlay plane | 没有 | 独立 plane，硬件合成 |

### 现代驱动只写 DRM

几乎没有"纯 fbdev 驱动"了。新驱动都注册到 DRM，`/dev/fbN` 由 DRM 的
**fbdev emulation** 模块（`drm_fb_helper.c`）伪造出来：

```
                    DRM driver
                  (virtio_gpu, pl111, i915, ...)
                          │
        ┌─────────────────┼───────────────────┐
        ▼                 ▼                   ▼
   /dev/dri/card0   /dev/dri/renderD128   /dev/fb0
   原生 DRM/KMS     纯 GPU 渲染节点       兼容老接口
   接口            (无 KMS 权限)         由 DRM fbdev
   (Qt eglfs)      (offscreen GPU)       emulation 生成
                                         (fbcon, busybox)
```

dmesg 里能看到 `[drm] fb0: virtio_gpudrmfb frame buffer device` —— `[drm]`
前缀就在说"这个 fb0 其实是 DRM 假装出来的 fbdev"。

### "DRM 是不是最终也写某个 fb？"

要分两层看：

- **物理层**：是的。不管走哪条路，硬件 scanout engine 终归要从 RAM 某地址逐行读像素。
- **软件层**：不是。DRM 操作的是 `drm_framebuffer`（DRM 自己的对象，绑定 GEM BO + 像素格式 + stride 等元数据），不是 `/dev/fbN`。
  - fbdev 的 framebuffer ≈ "那块固定的线性内存"
  - DRM 的 framebuffer ≈ "任意一块被注册成可显示的 buffer 对象"，可以同时存在很多个，KMS 决定哪个被 scanout，可以 `drmModePageFlip` 原子切换

## 十三、DRM 是框架，不是单一驱动 —— 如何支持那么多硬件

前面第十二节讲了 DRM/KMS 跟 fbdev 是两代设计。这里展开"它**是怎么**支持
那么多家硬件的" —— DRM 本身**不操作任何硬件寄存器**，它是一套抽象 + uAPI +
通用 helper，每家硬件各自写一个驱动模块来填硬件细节。

### "现代图形显示都走 DRM 吗" 的细分

```
                                       ┌── 桌面 Linux GPU
                                       │   (Intel/AMD/Nouveau/NVIDIA 新版)
                                       │     ─→ 全部走 DRM
                                       │
                                       ├── 嵌入式带 GPU
                                       │   (Mali/PowerVR/Adreno/...)
                                       │     ─→ 走 DRM
                                       │        (panfrost/lima/etnaviv/freedreno)
       Linux 现代图形显示 ─────────────┤
                                       ├── 嵌入式无 GPU 只 display controller
                                       │   (PL111/SimpleFB/imx-lcdc/...)
                                       │     ─→ 多数走 DRM (drm_simple_helper)，
                                       │        少数遗留只有 fbdev
                                       │
                                       └── 极少数遗留：efifb / simplefb 纯 fbdev
                                             ─→ 没 KMS、没 GPU 命令，能用而已

       其他系统:
         Windows         ─→ WDDM (Windows Display Driver Model)
         macOS / iOS     ─→ IOKit / Metal
         Android         ─→ HWComposer + gralloc + SurfaceFlinger
                            (底层在主线 kernel 上仍是 DRM)
         FreeBSD         ─→ 移植了部分 Linux DRM 驱动
```

严格说"现代图形显示是不是都走 DRM"不对（macOS/Windows 不走），但**在 Linux 世界
里新写的驱动几乎一定基于 DRM**。fbdev 在 2017 年前后就基本不再接受新驱动了。

### "框架 + 驱动 plugin" 分层架构

```
┌──────────────────────────────────────────────────────────────┐
│ 用户态: mesa / Qt eglfs / weston / X 服务器 ...              │
└─────────────────────────┬────────────────────────────────────┘
                          │ DRM uAPI (一组标准 ioctl)
                          │ /dev/dri/cardN, /dev/dri/renderDN
┌─────────────────────────┴────────────────────────────────────┐
│ DRM core (drivers/gpu/drm/drm_*.c)                            │
│  • 设备模型 (drm_device, drm_minor)                            │
│  • ioctl 分发                                                  │
│  • 文件操作 (open/close/mmap/poll)                             │
│  • DMA-BUF / fence / sync                                      │
└─┬─────────────────────────┬──────────────────────────┬───────┘
  │                          │                          │
  │ KMS helpers              │ GEM helpers              │ ...
  │ drm_atomic_helper_*      │ drm_gem_shmem_*          │
  │ drm_simple_*             │ drm_gem_dma_*            │
  │ (通用 modeset 流程)      │ (通用 buffer 管理)        │
┌─┴──────────────────────────┴──────────────────────────┴───────┐
│ 具体驱动 (drivers/gpu/drm/<vendor>/)                          │
│                                                                │
│  i915/    amdgpu/    nouveau/   panfrost/   lima/             │
│  virtio/  pl111/     vc4/       msm/        ...                │
│                                                                │
│  每个驱动:                                                    │
│    • 实现 struct drm_driver 里的 callback                     │
│    • 实现 CRTC / plane / connector / encoder 的 funcs         │
│    • 真正访问硬件寄存器 / 发命令                              │
└────────────────────────────────────────────────────────────────┘
                          ▼
                       硬件
```

这是 Linux 内核子系统标准设计模式。可以类比：

| 子系统 | "VFS 等价物" | 各家"驱动 plugin" |
|---|---|---|
| 文件系统 | VFS (`fs/`) | ext4 / xfs / btrfs / tmpfs |
| 块设备 | block layer | nvme / virtio_blk / scsi |
| 网卡 | net core | e1000 / virtio_net / mlx5 |
| 声卡 | ALSA | hda / virtio_snd / es1370 |
| 图形 | **DRM core** | **i915 / virtio_gpu / pl111 / amdgpu** |

上层 `mesa` / `Qt` 看到的 `/dev/dri/cardN` 接口跟硬件无关 —— **后端是 PL111 还
是 i915，用户态写一份代码就够了**。

### DRM 的核心抽象 —— 驱动需要填的对象

```
┌─────────────────────────────────────────────────────────────────┐
│  drm_device  ←──  代表一个 DRM 实例（通常对应一块卡）            │
│   │                                                              │
│   ├── drm_crtc          ─→ 像素生成器（哪个 buffer + mode）      │
│   ├── drm_plane         ─→ 显示平面（primary/cursor/overlay）    │
│   ├── drm_connector     ─→ 物理接口（HDMI/eDP/DSI/VGA/...）       │
│   ├── drm_encoder       ─→ 信号编码器（CRTC ↔ connector 中间层） │
│   ├── drm_framebuffer   ─→ 一个可显示 buffer（绑 GEM BO）        │
│   ├── drm_gem_object    ─→ buffer object，GPU 显存抽象           │
│   └── fence / syncobj   ─→ 同步原语                              │
└─────────────────────────────────────────────────────────────────┘
```

### 驱动具体要"填"什么

驱动**必须**实现的关键 callback：

| 类别 | 关键 callback | 干什么 |
|---|---|---|
| 全局 | `drm_driver.probe` | 注册 drm_device、申请资源 |
| 全局 | `drm_driver.fops` | open/close/mmap/poll |
| GEM | `drm_driver.gem_create_object` | 分配 buffer object |
| GEM | BO 的 `vmap/pin/get_pages` | 把 BO 映射给 GPU/CPU 用 |
| KMS | `drm_crtc_funcs.set_config` | 设置 mode（多数走 atomic_helper）|
| KMS | `drm_plane_helper_funcs.atomic_update` | 把 fb 真正提交到硬件 |
| KMS | `drm_connector_helper_funcs.get_modes` | 探测显示器支持哪些分辨率 |
| KMS | `drm_encoder_helper_funcs.enable/disable` | 开关编码器（如 HDMI PHY）|

典型代码长这样：

```c
/* 1. 注册一个 drm_driver */
static const struct drm_driver virtio_gpu_drm_driver = {
    .driver_features = DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC,
    .fops      = &virtio_gpu_fops,
    .ioctls    = virtio_gpu_ioctls,    /* 驱动私有 ioctl */
    .num_ioctls = ...,
    .gem_create_object = virtio_gpu_create_object,
    .name      = "virtio_gpu",
};

/* 2. 为 CRTC 提供操作函数 —— 大量直接用通用 helper */
static const struct drm_crtc_funcs virtio_gpu_crtc_funcs = {
    .set_config  = drm_atomic_helper_set_config,   /* ← 通用 helper */
    .page_flip   = drm_atomic_helper_page_flip,    /* ← 通用 helper */
    .destroy     = drm_crtc_cleanup,
    .reset       = drm_atomic_helper_crtc_reset,
};

/* 3. 硬件相关的部分：plane 真正把帧提交到硬件 */
static const struct drm_plane_helper_funcs virtio_gpu_plane_helper_funcs = {
    .atomic_check  = virtio_gpu_plane_atomic_check,   /* 验参数 */
    .atomic_update = virtio_gpu_primary_plane_update, /* 发 virtio 命令 */
};
```

`drm_atomic_helper_*` 是 DRM core 提供的通用代码，**所有原子 modesetting 驱动都
共用同一份**。驱动只要把"我硬件真正能做什么"实现进 `atomic_check`（参数能不能干）
+ `atomic_update`（怎么真正下发）。

### 真实驱动复杂度对比 —— 600 倍差距，对外接口一致

本项目里两个 DRM 驱动 + 桌面 i915 的代码量对比：

| 驱动 | 代码量 | 干什么 |
|---|---|---|
| `pl111/` | ~1000 行 | 简单 LCD 控制器，用 `drm_simple_*` helper，主要是寄存器读写 |
| `virtio/` | ~3000+ 行 | virtio 命令队列 + 2D + 3D (virgl) + 共享 buffer |
| `i915/` | ~60 万行 | 真 GPU 驱动：命令提交 + 多代硬件 + 显存 + HDCP + HDMI 协议 + 电源管理... |

**三个驱动复杂度差 600 倍，但它们都对外暴露同一套 `/dev/dri/cardN` 接口**。这
就是 DRM 抽象的价值：上层 mesa / Qt / X 完全不需要知道是 PL111 还是 i915。
你 grep `i915/` 里能找到大量 `drm_atomic_helper_*` 调用 —— modesetting 流程跟
PL111 共用同一套代码。

### 不走 DRM 的情况

| 场景 | 走什么 |
|---|---|
| 极简嵌入式只有 LCD 控制器、内核老/简陋 | 纯 fbdev (`drivers/video/fbdev/`) |
| 引导阶段 EFI 提供的 framebuffer | `simplefb` / `efifb`（纯 fbdev，没 KMS）|
| Linux < 5.x 的 NVIDIA 闭源驱动 | 自家 `nvidia.ko`，DRM 节点是壳子 |
| Android 用户态合成 | SurfaceFlinger，但底下还是 DRM |
| AMD ROCm 纯 GPU 计算 | 还是 amdgpu DRM 驱动，只是不开 KMS |

### 一句话总结

> **DRM 不是"一个支持所有硬件的驱动"，而是一个"驱动框架"**：定义 device / CRTC /
> plane / connector / encoder / framebuffer / BO 这一套抽象，提供通用 helper
> 做大部分繁琐流程；每家硬件只要写一个**填空式**驱动 —— 在标准 callback 里
> 翻译成自己硬件的寄存器/命令。所以 mesa / Qt / X 一份代码能跑遍 Intel / AMD /
> NVIDIA / Mali / virtio-gpu / PL111，因为它们对外都"长得一样"。跟 VFS 之于文
> 件系统、ALSA 之于声卡是完全同构的设计模式。

## 十四、GBM —— 渲染端和显示端的胶水

**GBM (Generic Buffer Management)** 是 mesa 提供的用户态库（`libgbm.so`），
负责分配"既能 GPU 渲染、又能直接 scanout"的图形 buffer。它是连接 EGL/GL（画画的）
和 DRM/KMS（显示的）的中间层。

### 它解决的问题

用 GPU 画一帧送显示，buffer 要同时满足两边：

```
┌─────────────────────┐         ┌─────────────────────┐
│  GPU 渲染端         │         │  KMS 显示端          │
│  (EGL/OpenGL)       │         │  (drmModeAddFB)     │
├─────────────────────┤         ├─────────────────────┤
│ - GPU 可访问        │         │ - 物理连续/可 DMA   │
│ - tiled / 压缩布局  │         │ - 显示器支持的格式  │
│   最好（性能）      │         │ - 特定 stride 对齐  │
│ - 任意格式          │         │                     │
└─────────────────────┘         └─────────────────────┘
              │                          │
              └──────────┐    ┌──────────┘
                         ▼    ▼
                    必须是同一块内存
                    (否则就得 CPU copy，废掉 GPU 加速)
```

`malloc()`、`/dev/fb0 mmap()` 都不满足。GBM 给出**厂商无关**的分配 API。

### 核心 API

```c
// 1. 把 DRM fd 包成 GBM device（buffer 分配器）
struct gbm_device *gbm = gbm_create_device(drm_fd);

// 2. 分配 surface（双/三缓冲队列，专为 EGL 用）
struct gbm_surface *surf = gbm_surface_create(gbm,
        1920, 1080, GBM_FORMAT_XRGB8888,
        GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);

// 3. 拿 bo 出来注册成 DRM framebuffer
struct gbm_bo *bo = gbm_surface_lock_front_buffer(surf);
uint32_t handle = gbm_bo_get_handle(bo).u32;
drmModeAddFB(drm_fd, ..., handle, &fb_id);

// 4. 翻页
drmModePageFlip(drm_fd, crtc_id, fb_id, ...);
```

`gbm_bo` 底层就是一个 **GEM BO**（DRM 的 buffer object）；GBM 套了厂商无关
的壳子，并告诉 GPU 驱动"这块要兼顾 scanout 用途"。

### 在显示栈里的位置

```
┌────────────────────────────────────────────────────────────┐
│ 用户态应用 (Qt eglfs, kmscube, weston, glmark2-es2-drm)     │
└─────────┬──────────────────────┬───────────────────────────┘
          │                      │
          │  画画                 │  显示
          ▼                      ▼
   ┌──────────────┐       ┌──────────────┐
   │ EGL / GL     │       │ libdrm (KMS) │
   │ (libEGL.so)  │       │              │
   └──────┬───────┘       └──────┬───────┘
          │                      │
          │ 需要 render target   │ 需要 fb_id
          └──────────┬───────────┘
                     ▼
              ┌──────────────┐
              │   GBM        │  ← 它来分配
              │ (libgbm.so)  │     双方都能用的 buffer
              └──────┬───────┘
                     ▼ 包装的是 GEM BO
              ┌──────────────────┐
              │ DRM driver       │  (i915, virtio_gpu, ...)
              │ (kernel)         │
              └──────────────────┘
```

GBM 是**纯用户态库**，不是内核子系统 —— 它就是一个聪明的 BO 分配器。

### 跟项目里的对应

build 出来的两个 glmark2 flavor 名字就反映了用法：

| flavor | 用 GBM 干嘛 |
|---|---|
| `glmark2-es2-gbm` | 用 GBM 分配 surface，**只渲染不显示**（offscreen 跑分） |
| `glmark2-es2-drm` | GBM 分配 + KMS scanout，**真显示出来**（用 page flip） |

Qt eglfs (`eglfs_kms` integration) 走完整的"GBM + EGL + DRM page flip"循环：

- `/etc/qt-eglfs-virtio.json` 配置 DRM 节点
- 启动时 `gbm_create_device(/dev/dri/card0)` + `gbm_surface_create(...)`
- 每帧 `glDrawArrays(...) + eglSwapBuffers(...) + drmModePageFlip(...)`

也是为什么 Qt eglfs 必须强占 KMS（`drmSetMaster`）+ 关掉 fbcon（`KD_GRAPHICS`）：
page flip 不能让 fbcon 同时也改 scanout buffer，否则两边争锋帧不稳。

### 跟 DMA-BUF 的关系

DMA-BUF 是 buffer 的**跨进程/跨驱动共享机制**（一个 fd 代表一块 buffer）。GBM 可以
把 `gbm_bo` 导出成 dma-buf fd：

```c
int dmabuf_fd = gbm_bo_get_fd(bo);
// 这个 fd 可以传给另一个进程，对方再 import
```

Wayland 协议里 client 把渲染好的 bo 通过 dma-buf 传给 compositor，compositor
再 scanout —— 整条链零拷贝。GBM 负责分配，DMA-BUF 负责传递。

### 一句话总结整个显示栈

> **fbdev** 给你"一块连续内存当屏幕"；
> **DRM/KMS** 给你"多 buffer + page flip + GPU 命令"的完整显示管线；
> **GBM** 在 DRM/KMS 上面再加一层："帮我分配一块 GPU 能画、KMS 能显示的 buffer"；
> **EGL/GL** 把 GBM 分到的 buffer 当 render target 用，画完让 KMS 扫描出去。

它们是**栈式叠加**，不是替代关系。Qt eglfs / weston / sway 都在最上层。

## 十五、相关代码索引

- `demo/vt-restore/main.c` — 工具源码（30 行）
- `Makefile`
  - `$(VT_RESTORE_BIN)` 构建规则
  - `$(ROOTFS_STAMP)` 加 `vt-restore` 依赖 + 拷到 `/usr/bin/`
  - `qt-gui-demo.sh` launcher heredoc 的 `trap cleanup EXIT INT TERM HUP`
- `dts/jxl.dtsi` — `bootargs = "console=tty0 console=ttyAMA0 ..."`，让 printk 同时写
  fbcon 和串口

## 十六、扩展阅读

- Linux 内核源码：`drivers/tty/vt/vt.c`、`drivers/tty/vt/keyboard.c`、
  `drivers/video/fbdev/core/fbcon.c`、`drivers/gpu/drm/drm_fb_helper.c`
- Linux 内核文档：`Documentation/fb/fbcon.rst`、`Documentation/gpu/drm-kms.rst`、
  `Documentation/admin-guide/kernel-parameters.txt`（`fbcon=` 参数）
- ioctl 头：`include/uapi/linux/kd.h`（`KDSETMODE` `KDSKBMODE` 等定义）
- DRM/GBM 用户态：`libdrm`、`mesa/src/gbm/`、`mesa/src/egl/drivers/dri2/platform_drm.c`
- Qt 源码：`qtbase/src/plugins/platforms/eglfs/`（eglfs 整体）、
  `qtbase/src/plugins/platforms/eglfs/deviceintegration/eglfs_kms/`（KMS 后端）、
  `qtbase/src/plugins/platforms/linuxfb/`（linuxfb 对照）
