# Linux TTY / fbcon / DRM 显示链路与 vt-restore 原理

> 项目场景：QEMU 自制 ARM64 SoC（JXL），bootargs `console=tty0 console=ttyAMA0`，
> 同时跑 fbcon 文字 console（→ VNC 窗口）和 Qt eglfs 图形 GUI（→ 同一 VNC 窗口）。
> 本文整理 vt-restore 工具的原理，以及它背后涉及的 TTY/VT/fbcon/DRM 知识。
>
> 项目仓库：<https://github.com/PenNameLuXun/qemu-vp>
> 本文路径：<https://github.com/PenNameLuXun/qemu-vp/blob/main/jxl-tty-fbcon-display.md>

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

## 十、物理机启动早期为什么就有 boot log —— 固件先驱动屏幕

第九节里 JXL machine 的"阶段 1 屏幕全黑"是因为我们没有固件预配 framebuffer。
但实体 PC（UEFI 系统）一上电就能看到厂商 logo + GRUB 菜单 + Linux 早期 boot
log，**且这一切发生在 Linux 加载真正的 GPU DRM 驱动之前**。怎么做到的？

### 关键：固件在交接 Linux 之前已经把 GPU display engine 配好

```
       上电
        │
        ▼
   ┌────────────────────────────────────────────────────────────┐
   │ 1. UEFI/BIOS 固件运行                                       │
   │    - PCIe 枚举找到 GPU                                      │
   │    - 执行 GPU 厂商的 Option ROM 或 UEFI GOP driver          │
   │    - 配置 PLL/时钟、输出口信号、分辨率/时序                  │
   │    - 在 VRAM 里划一块 framebuffer                            │
   │    - display engine 开始持续 scan-out                       │
   │    ─→ 屏幕从此一直在显示                                    │
   └─────────────────────────┬──────────────────────────────────┘
                             ▼
   ┌────────────────────────────────────────────────────────────┐
   │ 2. GRUB / systemd-boot 调用固件服务画菜单                  │
   │    把固件留下的 framebuffer 信息传给 Linux 内核             │
   └─────────────────────────┬──────────────────────────────────┘
                             ▼
   ┌────────────────────────────────────────────────────────────┐
   │ 3. Linux 早期：不认识 GPU 是哪家，但能写固件留的 fb         │
   │    - 注册 efifb / vesafb / simplefb / vgacon (薄壳驱动)     │
   │    - fbcon 接管 → 屏幕出现内核 boot log                     │
   └─────────────────────────┬──────────────────────────────────┘
                             ▼
   ┌────────────────────────────────────────────────────────────┐
   │ 4. 真 GPU DRM 驱动 (i915/amdgpu/nouveau...) 加载            │
   │    把 efifb 让出去，自己接管 KMS + GPU 命令通路             │
   │    dmesg: "Console: switching to colour frame buffer..."   │
   └────────────────────────────────────────────────────────────┘
```

### GPU 内部 "display engine" 和 "3D engine" 物理独立

```
┌─────────────────────────────────────────────────────────┐
│  现代 GPU 芯片                                           │
│                                                          │
│  ┌─────────────────┐    ┌──────────────────────┐        │
│  │ Display Engine  │    │ 3D / Compute Engine  │        │
│  │ (scanout)       │    │ (shader cores +      │        │
│  │ 持续从 VRAM 读  │    │  rasterizer + ROP)   │        │
│  │ → HDMI/DP 输出  │    │ 跑 GPU ISA 指令      │        │
│  └────────┬────────┘    └──────────────────────┘        │
│           │                                              │
│           ▼                                              │
│    显示器有图像                                          │
└─────────────────────────────────────────────────────────┘
```

固件**只激活了 display engine**，它就足以让屏幕一直亮着 —— 不需要 3D engine，
因此不需要 GPU 驱动。

### efifb / vesafb / simplefb —— 啥都不会的薄壳

它们都不是真 GPU 驱动，只是"接住固件留下的 framebuffer"的薄壳：

| 驱动 | 适用场景 |
|---|---|
| **efifb** | UEFI GOP（现代 PC、Mac、多数 ARM 服务器）|
| **vesafb** | 老 BIOS + VBE |
| **vgacon** | 老 BIOS 文本模式（写 `0xb8000`）|
| **simplefb** | 嵌入式（设备树告诉它 framebuffer 在哪）|

`efifb` 整个驱动 ~400 行，核心就这点东西：

```c
struct efifb_par {
    void __iomem *vram;   // ioremap() 把固件留的物理地址映射进内核
};

static void efifb_imageblit(struct fb_info *info, const struct fb_image *image)
{
    // 直接软件 blit 到 VRAM
    // PCIe 把写转发给 GPU
    // display engine 下一帧 scan 就看到新像素
    sys_imageblit(info, image);
}
```

不操作任何 GPU 寄存器，不发任何 GPU 命令 —— **只要固件配好了，往 BAR 写像素就够了**。

### PCIe 这一层

```
       CPU
        │
        │ MMIO 写到 BAR 地址
        ▼ PCIe Root Complex
   ┌──────────────────────────────┐
   │ GPU                           │
   │  - BAR0: VRAM (mmio mapped)  │  ← CPU 写这里 → PCIe 转给 GPU
   │  - BAR1: 寄存器              │
   │  - display engine 扫 VRAM    │
   │  - HDMI/DP 输出 ─────────►   │
   └──────────────────────────────┘
                                   ▼
                              显示器（一直在收信号）
```

PCIe 不是"驱动专用"通路，就是 CPU ↔ 外设的内存总线扩展。固件配好 BAR + display
engine 之后，写 BAR 地址就能更新显示，根本不需要"驱动"概念。

### 什么时候没有这个"早期接力"

| 场景 | 早期能看到日志吗 |
|---|---|
| 桌面 PC（UEFI + GOP）| ✅ efifb → DRM 接力 |
| 服务器无显卡 init | ❌ 走串口 / IPMI SOL |
| QEMU `-vga std` | ✅ vesafb 接力 |
| **本项目 JXL machine** | ❌ 没固件预配 fb，前 1.5s 死黑 |
| 树莓派（VideoCore 固件先配 fb）| ✅ simplefb 接力 |

JXL 项目"阶段 1 死黑"的根本原因：**没有任何"上一棒"把 framebuffer 留给 Linux**。
virtio-gpu 必须等 guest 内核 virtio 驱动起来才能初始化，跳不过。

### 一句话总结

> **Linux 早期能看到 boot log，是因为 UEFI/BIOS 固件在交接前已经把 GPU 的
> display engine 配好，留下一块"持续 scan-out 的 framebuffer"**。Linux 启动后
> 用 efifb / vesafb / simplefb 这类"哑壳"接过 framebuffer 地址，通过 PCIe BAR
> 写像素 —— 完全不需要懂 GPU 是哪家、不需要碰 3D 引擎、不需要发任何 GPU 命令。
> 直到真 DRM 驱动加载，才接管完整的 KMS + GPU 命令通路。

## 十一、串口 vs framebuffer —— 谁负责光栅化

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

## 十二、fbdev / fbcon / linuxfb —— 三个容易混的概念

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

## 十三、fbdev vs DRM/KMS —— 两代显示子系统

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

## 十四、DRM 是框架，不是单一驱动 —— 如何支持那么多硬件

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

## 十五、GBM —— 渲染端和显示端的胶水

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

## 十六、OpenGL / Vulkan 命令的完整链路 —— 从用户态到 GPU 硬件

前几节讲了显示链路（fbcon / DRM / GBM）。这一节讲**渲染**链路：3D API 调用
怎么变成 GPU 真正执行的命令。

### 常见误解：API 调用 ≠ 硬件指令

```
误解:                              实际:
 glDrawArrays(...)                  glDrawArrays(...)
      │                                  │
      │ "硬件指令"                       │  函数调用，进入用户态库
      ▼                                  ▼
   GPU 硬件执行                      libGL.so (mesa)
                                         │
                                         │  翻译成 vendor-specific 命令流
                                         ▼
                                     DRM ioctl → 内核
                                         │
                                         ▼
                                     GPU ring buffer → 命令处理器
                                         │
                                         ▼
                                     图形流水线 + shader 核心
```

**OpenGL / Vulkan API 本身不是硬件指令**，它们是用户态函数。**内核里没有
OpenGL 代码**，**GPU 硬件也不"懂" OpenGL** —— 所有翻译都在用户态驱动里。

### 六层链路

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 1: 应用                                                        │
│   glDrawArrays(GL_TRIANGLES, 0, 3); 或 vkCmdDraw(cmd, 3, 1, 0, 0);  │
└─────────────────────────┬───────────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────────┐
│ Layer 2: 用户态 ICD (mesa / vendor blob)                            │
│   维护 GL 状态机 → 生成 vendor-specific 命令包 → 写入 GEM BO        │
│   例（i915 命令包，简化）:                                          │
│     STATE_BASE_ADDRESS  <vram地址>                                  │
│     3DPRIMITIVE         TRIANGLES count=3                           │
│     PIPE_CONTROL        flush                                       │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ DRM ioctl
                          │ (DRM_IOCTL_I915_GEM_EXECBUFFER2 等)
┌─────────────────────────┴───────────────────────────────────────────┐
│ Layer 3: 内核 DRM 驱动                                              │
│   • 验证 BO 句柄合法                                                │
│   • Relocation: BO handle → 实际 GPU 地址                           │
│   • 调度 + 写命令地址到 GPU ring buffer 寄存器                       │
│   • 创建 dma-fence 给 user-space wait                                │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ MMIO / doorbell
┌─────────────────────────┴───────────────────────────────────────────┐
│ Layer 4: GPU 命令处理器 (i915 CSB / AMD PM4 / NVIDIA PFIFO)         │
│   GPU 上的 mini-CPU                                                  │
│   • DMA 读 ring 里的命令包                                          │
│   • 解析 packet → 写状态寄存器 / 触发 draw                          │
└─────────────────────────┬───────────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────────┐
│ Layer 5: 图形流水线（固定功能 + 可编程 shader）                      │
│                                                                       │
│   Vertex Fetch → Vertex Shader → Primitive Assembly                  │
│                  (跑 GPU ISA)                                        │
│        ↓                                                              │
│   Rasterizer → Fragment Shader → ROP (depth/blend)                   │
│                 (跑 GPU ISA)                                         │
└─────────────────────────┬───────────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────────┐
│ Layer 6: 显存里的 framebuffer BO                                     │
│   KMS 把这个 buffer 设成 scanout，被显示器读出来                      │
└─────────────────────────────────────────────────────────────────────┘
```

### ICD —— `libGL.so` 是调度器，不是实现

```
应用                       libGL.so 调度
  glDrawArrays ──────►   根据当前 context 选后端
                              │
                              ├─→ mesa-DRI (开源)
                              │     ├── iris (Intel)
                              │     ├── radeonsi (AMD)
                              │     ├── virgl (virtio-gpu)
                              │     └── ...
                              └─→ NVIDIA 闭源 ICD
                                    └── libGLX_nvidia.so
```

Vulkan 同理：`libvulkan.so` 是 loader，实现在 `libvulkan_intel.so` /
`libvulkan_radeon.so` / `libvulkan_nvidia.so` 等 ICD 里。

### 命令流格式（每家不同）

| 厂商 | 命令格式 | 提交 ioctl |
|---|---|---|
| Intel | MI_* + 3D 命令 | `DRM_IOCTL_I915_GEM_EXECBUFFER2` |
| AMD | PM4 packets | `DRM_IOCTL_AMDGPU_CS` |
| NVIDIA | method to PFIFO | `DRM_IOCTL_NOUVEAU_GEM_PUSHBUF` |
| Mali (Panfrost) | Job chain | `DRM_IOCTL_PANFROST_SUBMIT` |
| virtio-gpu | virgl 协议 | `DRM_IOCTL_VIRTGPU_EXECBUFFER` |

mesa 几十万行代码就在做这种"GL 状态机 → 命令包"的翻译，每家硬件一份后端。

### Shader 平行翻译链

GLSL / SPIR-V 也要编译成 GPU ISA：

```
GLSL 源码 / SPIR-V
   │
   │  mesa 前端 (GLSL parser 或 SPIR-V → NIR)
   ▼
NIR 中间表示（mesa 统一 IR）
   │
   │  vendor 后端 (iris/radeonsi/anv/radv 各自一份)
   ▼
GPU ISA (Intel EU / AMD GCN-RDNA / ...)
   │
   │  作为数据塞进 command buffer，跟 draw 命令一起提交
   ▼
GPU shader 核心取出来执行
```

### /dev/dri 的两个节点

```
/dev/dri/card0      ← KMS + 渲染，需要 master 权限
                       Qt eglfs / weston 用这个
/dev/dri/renderD128 ← 纯渲染节点，谁都能 open，不能 modeset
                       离屏 GL/CV 计算、Wayland client、Docker 容器用
```

mesa 提交 3D 命令大多走 renderD128（不需要显示权限）；最后呈现时通过 card0
触发 page flip。

### 本项目里的特殊路径：virtio-gpu virgl 转发

我们项目里没有真 GPU，整个 GL 命令流被**转发到 host**：

```
guest 应用 (Qt eglfs)
   │ glDrawArrays
   ▼
guest libGL.so (mesa virgl 后端)
   │  GL 状态 + GLSL shader → virgl 协议
   ▼
guest 内核 virtio_gpu → virtqueue
   │  把 virgl 命令送给 host
   ▼
─── guest/host 边界 ───
   │
host QEMU virtio-gpu device
   │
   ▼
host virglrenderer (libvirglrenderer.so)
   │  解析 virgl 协议，调真的 OpenGL
   ▼
host libGL.so → host 内核 DRM → host 真 GPU
   │
   ▼ 像素结果回传 guest
```

这就是为什么我们要折腾 virglrenderer 1.1.1 + GL compatibility profile —— 那是
**host 端**的 virgl 解释器，跟 guest 的 mesa 不是同一份代码。

### 几个常见误解一并扫掉

| 误解 | 纠正 |
|---|---|
| OpenGL 是内核功能 | ❌ 实现全在用户态。内核只管 DRM 命令提交 |
| GPU 硬件能"懂"OpenGL | ❌ GPU 只懂自家命令格式 + ISA。GL → 命令的翻译在用户态 |
| `glDrawArrays` 立即触发硬件渲染 | ❌ 只是往用户态 command buffer 写 packet；`glFlush`/`eglSwapBuffers` 才真正提交 |
| shader 跑在 CPU 上 | ❌ GLSL/SPIR-V 编译成 GPU ISA，跑在 GPU shader 核心上 |
| 闭源驱动包含的就是 OpenGL 实现 | 部分对：闭源 ICD 实现了 GL API，但底下仍走 DRM 内核接口 |

## 十七、内核驱动如何区分 GL 和 Vulkan？—— 它不需要知道

读完上一节自然会问：用户态可以是 GL 也可以是 Vulkan，内核驱动怎么区分？

**答案：根本不区分，这是 DRM 设计上故意做到的。**

### 内核接口是统一的

```
用户态:
   ┌──────────────────────┐    ┌──────────────────────┐
   │ libGL.so (mesa GL)   │    │ libvulkan.so + ICD   │
   └──────────┬───────────┘    └──────────┬───────────┘
              │                            │
              │  同样的命令格式            │  同样的命令格式
              │  同样的 DRM ioctl          │  同样的 DRM ioctl
              ▼                            ▼
   ╔════════════════════════════════════════════════════╗
   ║  DRM_IOCTL_I915_GEM_EXECBUFFER2                     ║
   ║  DRM_IOCTL_AMDGPU_CS                                ║
   ║  ...                                                ║
   ║  ── 同一个 ioctl，对内核没区别 ──                   ║
   ╚════════════════════════════════════════════════════╝
              │
              ▼
   内核 DRM 驱动看到的是一段不透明的命令字节
   不知道是 GL 翻出来的还是 Vulkan 翻出来的
```

### 差异完全在用户态

```
glDrawArrays              vkCmdDraw
     │                          │
     ▼                          ▼
mesa GL state tracker      mesa Vulkan ICD
(src/mesa/state_tracker/)  (src/intel/vulkan/ 等)
     │                          │
     │ 管 GL 状态机              │ Vulkan 是 explicit，
     │ 隐式同步                  │ 显式同步
     │                          │
     └────────────┬─────────────┘
                  │
            共用 NIR IR
            (mesa 统一 shader 中间表示)
                  │
            ┌─────┴─────┐
            ▼           ▼
    GL backend     Vulkan backend
    (iris/radeonsi) (anv/radv)
            │           │
            └─────┬─────┘
                  │ 这一刻起命令格式完全一样
                  ▼ DRM ioctl
            （内核以下不区分）
```

mesa 项目目录结构印证：

```
src/
├── mesa/                     ← GL state tracker（GL 专用）
├── glsl/                     ← GLSL → NIR
├── compiler/nir/             ← NIR 优化（GL+Vulkan 共用）
├── intel/
│   ├── compiler/             ← NIR → Intel ISA（共用）
│   ├── vulkan/               ← anv：Intel Vulkan
│   └── ...
├── gallium/drivers/iris/     ← Intel GL
├── amd/
│   ├── compiler/aco/         ← AMD shader 编译（共用）
│   └── vulkan/               ← radv
└── gallium/drivers/radeonsi/ ← AMD GL
```

**NIR 编译器、shader ISA 后端、表面布局这些 GL/Vulkan 共用**，只有最前端的 API
状态机不同。

### 内核到底"看到"什么

```c
struct drm_i915_gem_execbuffer2 {
    __u64 buffers_ptr;     /* 依赖的 BO 列表 */
    __u32 buffer_count;
    __u32 batch_start_offset;
    __u32 batch_len;       /* 命令长度 byte */
    __u64 flags;           /* engine: GFX / BLT / VCS / ... */
    /* ... 不包含"我是 GL"或"我是 Vulkan"任何字段 */
};
```

`flags` 里能选 GPU engine（GFX / blit / 视频 / ...），但**不区分 GL/Vulkan** ——
都走 GFX engine。

### GPU 硬件也不区分

- 命令处理器看到的是 vendor 格式 packet（i915 MI_*、AMD PM4）
- shader 核心执行的是 vendor ISA（Intel EU、AMD GCN/RDNA）

**GPU 没有"OpenGL 模式"和"Vulkan 模式"的物理硬件区分**。

### 为什么这设计合理 —— 跟其它子系统类比

| 子系统 | 内核管 | 用户态管 |
|---|---|---|
| 网卡 | TCP 包字节 | HTTP / gRPC / SSH 协议解释 |
| 文件系统 | `write(fd, buf, size)` | JSON / protobuf 格式 |
| **GPU** | **command buffer 字节** | **OpenGL / Vulkan API 翻译** |

**内核只该管"资源的合法访问"，"如何用资源"留给用户态决定**。如果内核要"懂"
OpenGL/Vulkan，等于把 mesa 几百万行代码塞进内核 —— 那就是 30 年前 SGI/3dfx
时代的灾难（旧 IRIX 内核里真有 GL 代码，导致不可维护、安全漏洞、新 API 难演进）。
Linux 走的是"图形栈推到用户态"的路线，所以 mesa 能这么活跃地演进新 GL/Vulkan
扩展而不需要换内核。

### 一句话总结

> **内核驱动不区分 GL 和 Vulkan，因为它不需要。** 用户态 mesa（或闭源 ICD）把
> 两种 API 都翻译成**同一种 vendor-specific GPU 命令流**，再用**同一个 DRM
> ioctl** 提交。内核管资源调度，用户态管 API 语义，GPU 硬件只执行命令字节 ——
> 三方对"上层是 GL 还是 Vulkan" 完全无感。跟 socket 不区分 HTTP/gRPC、文件系统
> 不区分 JSON/protobuf 是同一个思想。

## 十八、Mesa / X11 / Wayland —— 用户态图形栈全貌

前面讨论 OpenGL/Vulkan 时只说了 mesa 是 ICD，但用户态图形栈远不止 mesa。
桌面上还涉及 **X11 / Wayland / Xlib / XCB** 等一堆名词，它们都跑在用户态、
都不在内核里、却分工完全不同。本节把它们的关系理清。

### 两件互不相干的事：渲染 vs 显示组合

用户态图形栈其实分两条线，做两件互相独立的事：

```
┌──────────────────────────────┐  ┌──────────────────────────────┐
│  渲染 (rendering)             │  │  显示组合 (compositing)        │
│  "画一个三角形"                │  │  "把多个窗口拼到屏幕上"        │
│                                │  │                                │
│  → Mesa / 闭源 GL ICD          │  │  → X server (Xorg)              │
│  → libGL.so / libvulkan.so     │  │  → Wayland compositor          │
│  → 命令流 → DRM render node    │  │     (mutter/sway/weston/kwin)  │
│  → /dev/dri/renderDN           │  │  → 持有 DRM master              │
│                                │  │  → /dev/dri/card0               │
└──────────────────────────────┘  └──────────────────────────────┘
       客户端链接进来的库                  独立的服务进程
```

* **Mesa 不是 X 也不是 Wayland**：它只把 GL/Vulkan 翻译成 GPU 命令流，
  写入 GPU buffer，提交给 DRM。
* **X11 / Wayland 不做渲染**：它们只负责把多个客户端画好的 buffer 排版、
  合成、scanout 到屏幕。

两者通过 EGL/GLX 这种"胶水"对接（下面会讲）。

### X11 栈 —— 一个 1985 年的协议

```
┌──────────────────────────────┐
│ 应用 (Firefox / xterm / Qt)   │
└────────┬─────────────────────┘
         │ X11 协议（基于 unix socket / TCP 的字节流请求-回复）
         │
┌────────┴─────────────────────┐
│ X server (Xorg)               │  独立守护进程，DISPLAY=:0
│   • 持有 /dev/dri/card0        │     管 KMS + 输入设备
│   • 接受客户端的请求           │     "开窗口"、"贴 pixmap"、"分配资源"
│   • 把所有窗口合成出来         │
└──────────────────────────────┘
```

X server 是一个**进程**（多数发行版用 Xorg），应用通过 X11 协议向它发请求。
要"说" X11 协议，客户端需要一个协议库：

| 库 | 出生时间 | 风格 | 说明 |
|---|---|---|---|
| **Xlib** (`libX11`) | 1985 | 同步、阻塞、C 大 API | 老牌客户端库；每次请求都可能阻塞等回复，慢 |
| **XCB** (`libxcb`) | 2001 | 异步、轻量、cookie 风格 | 现代替代品；`libX11` 内部目前也基于 XCB 实现 |
| Xt / Motif / Xaw | 1980s–90s | toolkit | Xlib 之上的旧 GUI 工具包，今天已基本被 GTK/Qt 取代 |

**Xlib vs XCB 不是替换关系，是历史关系**：

```
应用 → Qt/GTK/Motif → libX11 (Xlib)  → libxcb → X server
                          └── 1985 老 API,
                              现在内部 dispatch 到 XCB 发协议字节
```

新写的代码可以直接用 XCB；toolkit（GTK / Qt 等）自己有 QPA / GDK 抽象，
内部根据编译选项决定走 Xlib 还是 XCB。

### Wayland 栈 —— 现代替代品（2008+）

```
┌──────────────────────────────┐
│ 应用 (Firefox / Qt / GTK)     │
└────────┬─────────────────────┘
         │ Wayland 协议（unix socket，二进制消息 + 文件描述符传递）
         │
┌────────┴─────────────────────┐
│ Wayland compositor            │  GNOME 的 mutter / KDE 的 kwin /
│   • 同时扮演 server + 合成器   │  独立的 sway / weston / hyprland 等
│   • 持有 /dev/dri/card0        │
│   • 没有 X server 那种"应用让   │
│     我画"的请求，应用自己渲染   │
└──────────────────────────────┘
```

Wayland 相对于 X11 的关键改变：

| 维度 | X11 | Wayland |
|---|---|---|
| 谁负责合成 | X server + XComposite 扩展（独立 compositor 进程也可） | compositor 本身就是 server |
| 客户端怎么"画" | 让 X server 画 ① OR 自己渲染再交 pixmap ② | 一律自己渲染 + 交 dma-buf fd |
| 协议复杂度 | 几百个核心请求（大量过时） | 核心很小 + 按需协议扩展 |
| 网络透明 | 是（X 当年卖点） | 否（设计上放弃） |
| 客户端库 | `libX11` / `libxcb` | `libwayland-client`（只一个） |

应用怎么把"我画好的内容"送给 Wayland compositor？通过 **dma-buf fd 共享**：
客户端用 mesa 渲染到一块 GPU buffer（GBM 分配的 dma-buf），把 fd 经 unix
socket 传给 compositor，compositor 直接拿这个 buffer scanout 或继续合成。
**零拷贝**。

### Mesa 怎么跟它们对接 —— EGL 是关键

Mesa 提供 GL/Vulkan API，但应用得告诉它"渲染结果交给谁"。这层抽象叫
**EGL**（OpenGL ES / Vulkan 通用）或老的 **GLX**（仅限 X）：

```
EGL backend          典型场景                谁持有 KMS / scanout
──────────────────────────────────────────────────────────────────
egl_x11              X11 客户端             X server
egl_wayland          Wayland 客户端         compositor
egl_gbm (egl_drm)    无 display server      应用自己（DRM master）
egl_surfaceless      离屏渲染 / 计算         无 scanout
```

* **X11 客户端**：mesa 创建 GL context，`eglCreateWindowSurface(xwindow)`
  → mesa 通过 **DRI3** 协议跟 X server 共享 dma-buf → 客户端渲染，X server
  负责合成上屏。
* **Wayland 客户端**：`eglCreateWindowSurface(wl_surface)` → mesa 用 GBM
  分配 dma-buf → 通过 `wl_drm` / `linux-dmabuf` 协议把 fd 发给 compositor。
* **eglfs / kmsro**：**没有 display server**。应用自己 open
  `/dev/dri/card0`，抢 DRM master，用 GBM 分配 scanout buffer，自己调 KMS
  atomic commit。**JXL 走的就是这条路**。

> **对照代码看更直观**：`demo/other/` 下三个最小 demo 分别演示三种 backend
> 怎么落地（X11 / Wayland / KMS+GBM），渲染内容相同，差异全在 EGL 之前
> 那段"怎么拿 native display / native window"。读完这一节建议过去对照
> 实际 C 代码看一遍。

### DRI —— 让客户端绕过 X 直接画

**DRI**（Direct Rendering Infrastructure）是 X11 时代发明的，让 OpenGL
应用绕过 X server 直接对 GPU 渲染，再把结果传回 X 合成。否则所有 GL 调用
都得序列化成 X11 协议字节流跑一遍，性能灾难。

DRI1（早期，已死）→ DRI2（2008）→ **DRI3**（2013，目前用的）。
DRI3 用 dma-buf fd 在客户端和 X server 之间共享 GPU buffer —— 这正是
Wayland 能"零拷贝"的技术祖先。

### 整张图：栈的全貌

```
┌─────────────────────────────────────────────────────────────────────┐
│ 应用 (Firefox / Qt / GTK / 游戏)                                     │
└──────┬───────────────────────────────────┬──────────────────────────┘
       │                                   │
       │ "画"：GL/Vulkan API               │ "窗口"：X11 / Wayland 协议
       ▼                                   ▼
┌─────────────────────┐                 ┌──────────────────────────┐
│ libGL / libvulkan   │                 │ libX11 / libxcb /        │
│   (mesa ICD)        │                 │ libwayland-client        │
│  • 编译 shader      │                 │  • 序列化协议字节流       │
│  • 生成 GPU 命令流   │                 │  • 经 unix socket 发服务   │
└──────┬──────────────┘                 └──────────┬───────────────┘
       │ DRM ioctl                                  │
       │ /dev/dri/renderDN (render node, 无权限管控) │
       │                                            ▼
       │                          ┌────────────────────────────────┐
       │                          │ X server  OR  Wayland          │
       │                          │           compositor            │
       │                          │  • 拿客户端的 dma-buf fd        │
       │                          │  • DRM master /dev/dri/card0   │
       │                          │  • KMS atomic commit           │
       │                          └─────────┬──────────────────────┘
       │                                    │
       └──────────────┬─────────────────────┘
                      │ DRM 内核驱动
                      ▼
                 GPU 硬件
```

注意 `/dev/dri/` 下其实有**两类节点**：
- `cardN` —— **primary node**，能跑 KMS（模式设置/scanout），需要 master 权限
- `renderDN` —— **render node**，只能渲染（不能 scanout），所有人都能 open

X server / Wayland compositor 抢 `cardN`；普通 GL 客户端只用 `renderDN` 渲染，
渲染好的 dma-buf 再通过协议交给 server scanout。

### 本项目（JXL）在哪一档？

```
JXL 简化栈：

┌──────────────────────┐
│ qt-gui-demo (Qt App) │
└──────┬───────────────┘
       │ Qt 的 QPA 插件 = eglfs
       │ (= "Embedded Linux FullScreen"，无 display server)
       ▼
┌──────────────────────┐
│ libGL (mesa, virgl 后端) │   ← 渲染
└──────┬───────────────┘
       │
       │ EGL 后端 = GBM/KMS
       ▼
┌──────────────────────┐
│ libgbm + libdrm      │   ← 自己当 display server
└──────┬───────────────┘
       │ /dev/dri/card0 (DRM master) + KMS atomic
       ▼
   virtio-gpu → host QEMU → SDL / VNC
```

**JXL 不跑 X11 也不跑 Wayland**。Qt eglfs 直接扮演 display server 的角色，
所以才会出现"抢 VT 设 KD_GRAPHICS / K_OFF"的问题（前面 vt-restore 那一节）
—— 桌面上是 compositor 进程持有 VT，崩了 systemd 会重启 session；嵌入式
只有一个应用，崩了就靠 `vt-restore` 善后。

### 一句话总结

> **Mesa 管"画三角形"，X11 / Wayland 管"摆窗口"，是两件事**。Mesa 是个
> 用户态库，被链接进每个 GL/Vulkan 应用；X server / Wayland compositor 是
> 独立进程，应用通过 Xlib / XCB / libwayland-client 跟它说话。Xlib 是 X
> 的老 API，XCB 是新 API，libX11 现在内部走 XCB —— 不是替代关系而是历史
> 关系。EGL 在中间起胶水作用，告诉 mesa "渲染结果该交给谁"。JXL 用 eglfs
> 把 display server 这一层省了，直接 Mesa → GBM → DRM 一条龙。

## 十九、WSL2 是 "headless" —— 这是什么意思

本项目跑在 WSL2 上，你可能听过一句 "WSL2 是 headless 的"。这一节解释这个
词、以及它为什么决定本项目只能走 VNC 而不能用 SDL 直接弹窗。

### Headless 的字面含义

"Headless" 字面意思是**没有"头"** —— 没接显示器、键盘、鼠标。机房服务器
都是这样：塞在机柜里，远程 SSH 进去操作，从不接显示器。

延伸到 VM / 容器场景，"headless" 意思是 **VM 本身没有虚拟显示设备**：

```
普通 VM（带 head）              headless VM
┌─────────────────┐            ┌─────────────────┐
│ Linux           │            │ Linux           │
│ /dev/fb0  ✓     │            │ /dev/fb0  ✗     │
│ /dev/dri/card0 ✓│            │ /dev/dri/card0 ✗│
│  ↓              │            │  (没接虚拟显卡) │
│ 虚拟显卡         │            │                  │
│  ↓              │            │ 只有串口/管道    │
│ VNC/SPICE 窗口   │            │  ↓               │
└─────────────────┘            │ stdin/stdout 管道 │
                                └─────────────────┘
```

### WSL2 具体怎么 headless

WSL2 是跑在 Windows Hyper-V 里的 Linux VM，**这个 VM 在配置上根本没有
虚拟显示设备**：

- 没有 `/dev/fb0`（QEMU 给 JXL 加的那种 framebuffer）
- 没有 `/dev/dri/card0`（DRM 主节点，KMS 接口）—— `/dev/dri/` 整个都没有
- 没有 VT/fbcon —— 进 WSL 不会跳出黑底白字的虚拟控制台
- 没有键盘/鼠标输入设备节点（`/dev/input/event*` 基本是空的）

你看到的"终端"，全是通过 **9P / vsock** 把 stdin/stdout/stderr 管道到
`wsl.exe` 这个 Windows 进程，再渲染在 Windows Terminal 里。
**Linux 自己根本不知道屏幕长什么样**。

可以自己验证：

```sh
$ ls /dev/fb*               # 不存在
ls: cannot access '/dev/fb*': No such file or directory
$ ls /dev/dri/              # 通常也不存在（除非装了 dxg 驱动）
ls: cannot access '/dev/dri/': No such file or directory
$ tty                       # 当前 shell 跑在伪终端，不是 VT
/dev/pts/0
```

### 那 WSL 里运行的 GUI 程序怎么显示？

微软另外搞了个东西叫 **WSLg**（"WSL GUI"）：

```
你的 WSL2 实例（你 SSH/cd 进去的那个）
         ▼  X11/Wayland 协议（unix socket / vsock）
另一个隐藏的小 Linux VM (WSLg system distro)
   • 跑 Weston (Wayland compositor) + XWayland
   • 把合成结果转成 RDP 协议
         ▼  RDP
Windows 主机的 RDP 客户端 (mstsc.exe 内核组件)
   • 在 Windows 桌面上画出窗口
```

所以你跑 `gedit` 能弹窗，但它走的**不是** WSL2 自己的 framebuffer ——
是把 X/Wayland 协议字节流送给另一个 VM，再用 RDP 协议转回 Windows。
对应用层来说像 X11/Wayland，对底层来说没有任何"显示卡"。

### 跟本项目踩的坑的关系

这就解释了为什么本项目在 WSL 上总是要走 **VNC 路径**，而不是 QEMU 的 SDL
直接弹窗：

```
路径 A: QEMU 用 SDL 直接弹窗 (本项目 sdl-virtio-gl 模式)
  QEMU → SDL → 找"屏幕"
            → WSL2 是 headless，没有原生屏幕
            → SDL 只能走 WSLg 的 Wayland/X11
            → WSLg 转 RDP → Windows 显示
   缺点：路径长、依赖 WSLg GL 加速（virgl/D3D12 翻译）、
        在某些显卡/驱动组合下黑屏（你最初的 "两个 SDL 窗口什么都不显示"）

路径 B: QEMU 内置 VNC server (本项目 gui-virtio 模式)
  QEMU → 自己把 framebuffer 编码成 VNC 协议字节
       → 监听 127.0.0.1:5900 (TCP socket)
       → 任何 VNC 客户端 (Windows 的 TigerVNC / RealVNC) 接进来
   优点：完全不依赖 WSL 的显示能力，纯协议传输；稳定可调
```

memory 里 `jxl_pl111_display.md` 那条 "WSL2 上用 VNC，不用 SDL" 的规则，
根因就是 **WSL2 headless**。

### 引申：其他 headless 场景

同样的逻辑适用于：

| 场景 | 是不是 headless | 显示路径建议 |
|---|---|---|
| WSL2 | 是 | QEMU `-vnc` / 串口 |
| 云服务器（AWS/GCP/阿里云）  | 是 | QEMU `-vnc` / 串口；console 接 web |
| Docker 容器 | 通常是 | 容器里运行 X server 不靠谱，宿主跑 X / VNC |
| Kubernetes Pod | 是 | 同上 |
| CI runner（GitHub Actions 等） | 是 | Xvfb（虚拟 X server，写入内存不上屏） |
| 你自己的物理机 + 显示器 | 否 | 任何方式都行 |

`Xvfb`（X Virtual Frame Buffer）是另一个有趣的"假装有屏幕"方案：跑一个
X server，但 framebuffer 写在内存里，永远不上屏 —— CI 里跑 GUI 测试很常用。

### 一句话总结

> **WSL2 是 headless = 这个 Linux VM 配置里就没有显示卡 / 显示器 / 键盘 /
> 鼠标**。你看到的"终端"是 stdio 管道到 Windows，GUI 是另一个隐藏 VM 通过
> WSLg 转 RDP。任何依赖 `/dev/fb0` / `/dev/dri/card0` / SDL 直接弹窗的方案
> 在 WSL 里都得绕道；走 VNC / RDP / 网络协议最稳 —— 这就是本项目 `run.sh
> gui-virtio` 模式的设计原因。

## 二十、相关代码索引

- `demo/vt-restore/main.c` — 工具源码（30 行）
- `Makefile`
  - `$(VT_RESTORE_BIN)` 构建规则
  - `$(ROOTFS_STAMP)` 加 `vt-restore` 依赖 + 拷到 `/usr/bin/`
  - `qt-gui-demo.sh` launcher heredoc 的 `trap cleanup EXIT INT TERM HUP`
- `dts/jxl.dtsi` — `bootargs = "console=tty0 console=ttyAMA0 ..."`，让 printk 同时写
  fbcon 和串口

## 二十一、扩展阅读

- Linux 内核源码：`drivers/tty/vt/vt.c`、`drivers/tty/vt/keyboard.c`、
  `drivers/video/fbdev/core/fbcon.c`、`drivers/gpu/drm/drm_fb_helper.c`
- Linux 内核文档：`Documentation/fb/fbcon.rst`、`Documentation/gpu/drm-kms.rst`、
  `Documentation/admin-guide/kernel-parameters.txt`（`fbcon=` 参数）
- ioctl 头：`include/uapi/linux/kd.h`（`KDSETMODE` `KDSKBMODE` 等定义）
- DRM/GBM 用户态：`libdrm`、`mesa/src/gbm/`、`mesa/src/egl/drivers/dri2/platform_drm.c`
- Mesa：<https://gitlab.freedesktop.org/mesa/mesa> ——
  `src/mesa/` (state tracker)、`src/gallium/drivers/` (GL 后端)、
  `src/intel/vulkan` / `src/amd/vulkan` (Vulkan ICD)、`src/compiler/nir/` (公共 IR)
- X11：<https://www.x.org/wiki/Documentation/>、`libX11` (Xlib)、
  `libxcb`、Xorg server `xserver/dix/` `xserver/hw/xfree86/`
- Wayland：<https://wayland.freedesktop.org/docs/html/>、协议 XML 在
  `wayland-protocols/`、参考 compositor `weston/`
- Qt 源码：`qtbase/src/plugins/platforms/eglfs/`（eglfs 整体）、
  `qtbase/src/plugins/platforms/eglfs/deviceintegration/eglfs_kms/`（KMS 后端）、
  `qtbase/src/plugins/platforms/linuxfb/`（linuxfb 对照）、
  `qtbase/src/plugins/platforms/xcb/`（X11 对照）、
  `qtbase/src/plugins/platforms/wayland/`（Wayland 对照）
