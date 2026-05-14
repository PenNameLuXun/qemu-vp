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

---

## 怎么调试 / 追踪一个图形 demo 的依赖

读懂 demo 的源代码只是表面 —— **真正的渲染栈一大半是运行时 dlopen
进来的**（mesa、厂商 ICD、WSL 注入的 libd3d12 等）。下面是几个常用工具，
后两节的"WSL 实测"分析就用它们做出来的。

### 1) `ldd` —— 直接链接的库

```sh
ldd ./egl-wayland-demo
```

只能看到 `gcc -l...` 时给的库（libEGL、libGLESv2、libwayland-*）。**真正
干活的 dri 驱动 / mesa 后端 / 厂商 UMD 不会出现** —— 因为它们是 dlopen
而不是链接进来的。

### 2) `LD_DEBUG=files` —— 看运行时**加载链**

```sh
LD_DEBUG=files timeout 1 ./egl-wayland-demo 2>&1 \
    | grep -E "dri/[^/]+\.so|libd3d12|/usr/lib/wsl"
```

`LD_DEBUG=files` 是 glibc 动态加载器的内建调试输出，会打印**每一个
dlopen** 和它的依赖关系。`grep` 过滤出关心的 `.so`。

输出形如：

```
file=/usr/lib/x86_64-linux-gnu/dri/swrast_dri.so;
    dynamically loaded by /lib/x86_64-linux-gnu/libEGL_mesa.so.0
file=libd3d12.so;
    dynamically loaded by /usr/lib/x86_64-linux-gnu/dri/swrast_dri.so
```

可以清楚看到 **"谁拉进了谁"** 的整条链。

`LD_DEBUG=symbols` / `libs` / `bindings` 都有用，但 `files` 对追踪图形栈
最直观。完整选项：`LD_DEBUG=help cat`。

### 3) `strace -e openat` —— 看打开了哪些 **文件 / 设备节点**

```sh
strace -f -e openat -o /tmp/trace.out timeout 2 ./egl-wayland-demo
grep -E "openat.*(/dev/|/usr/lib/wsl)" /tmp/trace.out | grep -v ENOENT
```

`-e openat` 只跟踪 `openat` 系统调用（绝大多数 open 现在走 openat）。
`-f` 跟所有子线程。过滤掉 `ENOENT`（找不着的 fallback 路径，干扰大）。

这个比 `LD_DEBUG` 更广 —— 不光看 `.so`，连**打开了哪个 `/dev/` 节点**
都暴露出来。我们就是这样发现 demo 打开 `/dev/dxg` 而不是
`/dev/dri/renderD128` 的。

进一步可以加 `ioctl`：

```sh
strace -e openat,ioctl -e trace='!futex' ./demo 2>&1 | head -40
```

不过 ioctl 输出量极大，建议针对性 grep。

### 4) `glxinfo` / `eglinfo` / `vulkaninfo` —— 看驱动报上来什么

```sh
glxinfo -B          # GLX (X11) 上的 GL 驱动信息
eglinfo             # 各 EGL 平台 (x11/wayland/gbm/surfaceless) 的能力
vulkaninfo --summary
```

`glxinfo` 报 `OpenGL renderer string` —— 在 WSL 上是 `D3D12 (Intel(R) Iris(R)
Xe Graphics)`，立刻看出走的是 d3d12 mesa 后端。`direct rendering: Yes/No`
告诉你是不是绕过了 X server 做 DRI 直接渲染。

### 5) `drmGetVersion` + `drmModeGetResources` —— 探 DRM 节点能力

简单 C 程序就能问 `/dev/dri/cardN` 是什么驱动、有没有 KMS：

```c
#include <fcntl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <stdio.h>

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR);
    drmVersion *v = drmGetVersion(fd);
    printf("driver=%s desc=%s\n", v->name, v->desc);
    drmModeRes *r = drmModeGetResources(fd);
    if (!r) printf("no KMS (errno=%d)\n", errno);
    else printf("KMS: %d connectors\n", r->count_connectors);
    return 0;
}
```

```sh
gcc demo.c $(pkg-config --cflags --libs libdrm) -o /tmp/drmprobe && /tmp/drmprobe
# WSL 输出: driver=vgem desc=Virtual GEM provider / no KMS (errno=95)
# JXL 输出: driver=virtio_gpu desc=... / KMS: 1 connectors
```

这是判断"这个 DRM 节点能不能跑 egl-kms-gbm-demo"最直接的办法。

### 6) `lsof` / `ss -xl` —— 看 unix socket 谁在监听

```sh
ss -xl | grep -E "wayland|X11"
lsof /tmp/.X11-unix/X0   # 需要 root
```

可以看到 X11 / Wayland socket 是哪个进程监听的。**WSL 上看不到**，因为
XWayland 和 weston 跑在隔壁 WSLg system distro，socket 是 bind-mount 过来的。

### 7) 综合：调试图形 demo 的标准流程

```sh
# 步骤 1: 静态依赖
ldd ./mydemo

# 步骤 2: 运行时加载链
LD_DEBUG=files timeout 2 ./mydemo 2>&1 | grep '\.so;' > load.log

# 步骤 3: 打开的设备/文件
strace -f -e openat -o trace.out timeout 2 ./mydemo
grep -E "openat.*(/dev|/usr/lib/wsl)" trace.out | grep -v ENOENT

# 步骤 4: 驱动能力
glxinfo -B; eglinfo | head -40

# 步骤 5: DRM 探针
/tmp/drmprobe  # 上面那个小工具
```

每个 demo 用这套流程过一遍，整个图形栈就透明了。

---

## 案例一：egl-wayland-demo 在 WSL2 上的完整渲染栈

按上面方法实测得到的结论。**用来理解"用户态图形库分层 + WSL D3D12 翻译
路径"非常直观**。

### 7.1 demo 进程里实际加载的 .so

```
demo 二进制直接链接 (ldd):
  libwayland-egl.so.1            (Wayland-EGL 胶水)
  libwayland-client.so.0         (Wayland 协议库)
  libEGL.so.1                    (EGL 标准 dispatcher)
  libGLESv2.so.2                 (GL ES 2 dispatcher)

eglInitialize 时被 dlopen 进来 (LD_DEBUG=files):
  libEGL_mesa.so.0               (mesa 的 EGL 实现)
   └─► swrast_dri.so             (mesa DRI driver,WSL 上这名字误导,
                                    实际是 D3D12 后端的加载壳)
        └─► /usr/lib/wsl/lib/libd3d12.so       (★ Microsoft 移植的
                                                   D3D12 runtime)
              └─► libdxcore.so + libd3d12core.so
                    └─► /usr/lib/wsl/drivers/iigd_*/
                          libigd12umd64.so     (★ Intel 真 GPU 驱动
                                                   用户态部分,UMD)
                          libigc.so            (Intel Graphics Compiler,
                                                  编译 DXIL → Intel ISA)
                          libLLVM-9.so         (Intel 编译器后端)

打开的 /dev 节点 (strace):
  /dev/dxg                       (★ WSL DirectX 内核接口,数据真正进内核处)
  完全没碰 /dev/dri/renderD128 也没碰 /dev/dri/card0
```

> **注意**：在 WSL 上 mesa 加载的是 `swrast_dri.so`（字面意思"软件光栅"），
> 这是个**误导性命名** —— 它马上就去 dlopen `libd3d12.so` 和 Intel UMD，
> **真正的渲染在物理 GPU 上**，不是 CPU。这是 Microsoft 在 mesa 上的 WSL
> 特定改造。

### 7.2 渲染时各层在干啥（GL → 像素的翻译链）

| 层 | 干什么 | 谁实现 | 在哪 |
|---|---|---|---|
| 1 | `glDrawArrays(...)` | demo 自己 | demo 代码 |
| 2 | GL 状态机维护 | **mesa** | swrast_dri.so 内 |
| 3 | GL → D3D12 API 翻译 | **mesa**（gallium d3d12 后端） | swrast_dri.so 内 |
| 4 | GLSL → DXIL 字节码 | **mesa** | swrast_dri.so 内 |
| 5 | D3D12 命令包生成 | **libd3d12.so**（Microsoft） | wsl/lib/ |
| 6 | DXIL → Intel GPU ISA | **libigc**（Intel） | wsl/drivers/iigd_*/ |
| 7 | GPU 命令字节生成 | **libigd12umd64**（Intel UMD） | wsl/drivers/iigd_*/ |
| 8 | ioctl 提交 | Intel UMD → `/dev/dxg` | 内核态 |
| 9 | 内核转发 | **dxgkrnl** Linux 模块 | 内核态 |
| 10 | 跨 VM 转发 | Hyper-V vsock | 虚拟化层 |
| 11 | Windows D3D12 KMD | Windows | Host |
| 12 | 真渲染 | **物理 GPU** | 硬件 |

**前 7 层全在用户态**（demo 进程地址空间内），第 8 层才进内核。这跟原生
Windows 上 D3D12 应用的分层一模一样 —— Microsoft 只是把 D3D12 runtime +
Intel UMD 重新编译成 Linux ELF `.so`，把 D3D12 KMD（dxgkrnl）做成 Linux 内核
模块再用 vsock 转给 Windows。

### 7.3 关键问题速答

**Q: 是 mesa 创建图形数据吗？**
A: **部分是**。mesa 输出的不是像素，而是 **D3D12 命令** + **DXIL 字节码**。
真正变像素的是 Intel UMD + 物理 GPU。

**Q: d3d12 driver 是用户态吗？**
A: **是**。`libd3d12.so` 和 `libigd12umd64.so` 全是用户态 `.so`，跑在 demo
进程地址空间内。崩了只崩 demo，不影响别人。

**Q: 翻译成 D3D12 了吗？**
A: **是**。`glDrawArrays(...)` → `ID3D12GraphicsCommandList::DrawInstanced(...)`，
GLSL → SPIRV → NIR → DXIL，整套翻译都在 mesa 用户态做。

**Q: 命令交给 `/dev/dri/renderD128` 吗？**
A: **不是**。WSL 跟原生 Linux 这里分歧最大：

| 系统 | 命令路径 |
|---|---|
| 原生 Linux + Intel | mesa iris → `DRM_IOCTL_I915_GEM_EXECBUFFER2` → `/dev/dri/renderD128` |
| **WSL2 + Intel** | mesa swrast 壳 → libd3d12 → Intel UMD → dxg ioctl → **`/dev/dxg`** |

`/dev/dri/renderD128` 在 WSL 上是 vgem 装样子的，**不在数据路径上**。

**Q: GPU 加速吗？**
A: **是**。证据：(1) 加载了 Intel UMD 库；(2) 加载了 Intel Graphics Compiler；
(3) `glxinfo` 报 `Device: D3D12 (Intel(R) Iris(R) Xe Graphics)` +
`Accelerated: yes`。

---

## 案例二：egl-x11-demo 在 WSL2 上 —— 跟 Wayland 对比 + 标题栏差异

### 8.1 渲染路径：跟 Wayland **完全一致**

实测 X11 demo 加载的 `wsl/*` 文件和打开的 `/dev` 节点跟 Wayland demo
**100% 一致**：

```
都是: libd3d12.so + libdxcore.so + libd3d12core.so
     + libigd12umd64.so + libigc.so + libLLVM-9.so
     + 打开 /dev/dxg
```

**GPU 渲染路径跟上面表格 11 步一字不差**。`ldd` 唯一额外多出的是
`libX11.so.6` + `libxcb.so.1` —— 印证 § 十八 说的"Xlib 内部已基于 XCB"。

### 8.2 唯一差异：buffer 怎么交给 compositor

```
egl-x11-demo（多一跳 XWayland）：       egl-wayland-demo（直连）：

demo                                      demo
 └─► X11 协议 (DRI3 PresentPixmap)         └─► Wayland 协议
     unix socket /tmp/.X11-unix/X0             (wl-drm / linux-dmabuf)
     │                                          │
     ▼                                          │
   XWayland (X server 实现为 Wayland 客户端)   │
     └─► 把 dma-buf 翻译成 wl_surface buffer   │
         │                                      │
         ▼ Wayland 协议                          ▼
        WSLg weston (在隔壁 WSL VM)
         └─► RDP-backend → vsock → Windows 桌面
```

X11 多走 XWayland 一跳，**没有额外渲染或像素拷贝** —— XWayland 只是把
DRI3 PresentPixmap 翻译成 wl_surface.attach。

> **WSLg 的 X server 和 weston 都不在你这个 WSL 实例里** ——
> `ps -e | grep -i xwayland` 是空的。它们跑在隔壁 **WSLg system distro**
> （另一个 WSL 实例），`/tmp/.X11-unix/X0` 和 `$XDG_RUNTIME_DIR/wayland-0`
> 都是从那边 bind-mount 到你这边。所以是个**跨 VM 边界的 display server**。

### 8.3 为什么 X11 窗口有标题栏，Wayland 窗口没有？

**这不是 demo bug，是协议哲学差异**。

#### X11：装饰由"窗口管理器"加，应用什么都不做

X11 协议（1985）把"应用画内容"和"WM 画装饰"明确分开：

```
demo (X 客户端)              X server                  窗口管理器 (独立进程)
 │ XCreateWindow             │                          │
 ▼                           ▼                          │ 监听 X 事件
分配 800×600 窗口            分配 XID                   │ (SubstructureNotify)
                                                        ▼
                                                  把客户端窗口 "reparent"
                                                  进一个更大的 frame 窗口
                                                  在 frame 上画标题栏 +
                                                  边框 + 关闭按钮 +
                                                  响应拖动
```

**demo 根本不知道自己有标题栏** —— 那是 WM 在它窗口外面包了一层。

WSLg 里这个 WM 的角色由 **Windows DWM** 实现：XWayland 报告 X 顶层窗口给
WSLg → weston 的 RDP-backend 把它当 RDP "RemoteApp" 报给 Windows →
**Windows 桌面给它配标题栏**（所以你看到的标题栏是 Windows 原生风格，
能最小化/最大化/拖动 —— 跟 Windows 自家程序一样）。

#### Wayland：协议设计上**根本没有"装饰"概念**

Wayland 把装饰**踢给客户端或 compositor 协议扩展**，原因是它要打破 X11
"WM 是必需服务"的耦合：

- 协议核心：客户端只声明"我是个 top-level surface"，再无别的
- 没有"标题栏"、"边框"、"关闭按钮"、"拖动" 这些协议消息
- 装饰是**可选扩展**：
  - 客户端自己画（CSD = Client-Side Decoration）—— GTK、Firefox 走这条
  - 协议扩展 `xdg-decoration` 让 compositor 加（SSD = Server-Side
    Decoration）—— 需要两边都同意，GNOME mutter 直接拒绝所有 SSD 请求

我们的 demo 只调了：

```c
xdg_toplevel_set_title(toplevel, "egl-wayland-demo");   // 元数据(Alt-Tab 用)
xdg_toplevel_set_app_id(toplevel, "egl-wayland-demo");
```

**没有任何"我要装饰"的请求**，所以 weston / WSLg 给你裸 wl_surface。

#### 想让 Wayland demo 也有标题栏，怎么改

**路 A：客户端自己画（CSD，用 libdecor）**

```c
struct libdecor *ctx = libdecor_new(wldisplay, &iface);
struct libdecor_frame *frame =
    libdecor_decorate(ctx, wlsurface, &frame_iface, NULL);
libdecor_frame_set_title(frame, "egl-wayland-demo");
libdecor_frame_map(frame);
```

libdecor 会在 wl_surface 上叠加几个 subsurface 自己画标题栏，响应鼠标，
把"应该缩放/移动"事件回调给你。

**路 B：跟 compositor 谈服务端装饰（xdg-decoration）**

```c
struct zxdg_decoration_manager_v1 *mgr = /* registry 里 bind */;
struct zxdg_toplevel_decoration_v1 *deco =
    zxdg_decoration_manager_v1_get_toplevel_decoration(mgr, toplevel);
zxdg_toplevel_decoration_v1_set_mode(
    deco, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
```

compositor **可能拒绝**（mutter 拒一切 SSD）。WSLg weston 的具体行为
没在本机验证过，想测的话改一下 demo 即可。

#### 对比

| 方面 | X11 demo | Wayland demo |
|---|---|---|
| 标题栏来源 | WSLg 让 Windows DWM 加 | 默认没人加 |
| 应用要写装饰代码吗 | 不用 | 必须（CSD 或谈协议） |
| 谁处理拖动 | 窗口管理器（这里 Windows DWM） | 应用自己 或 compositor |
| 哲学 | "装饰是 WM 的事" | "应用是窗口唯一决定者" |

### 8.4 一句话总结

> egl-x11-demo 在 WSL 上的 **GPU 渲染路径跟 Wayland 一模一样**（都是
> mesa→libd3d12→Intel UMD→`/dev/dxg`），只在"渲染好的 dma-buf 怎么交出去"
> 多一跳 XWayland。**标题栏的差异不是渲染问题** —— X11 把装饰外包给独立
> 的窗口管理器（在 WSLg 里最终落到 Windows DWM），所以你"什么都不做"就有
> 标题栏；Wayland 协议里**没有装饰这个概念**，要装饰必须主动写代码或谈
> 协议 —— 我们的 demo 都没做，所以是裸窗口。
