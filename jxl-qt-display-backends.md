# Qt 三种显示后端在 JXL 上的渲染链路与取舍

> 项目场景：QEMU 自制 ARM64 SoC（JXL）+ virtio-gpu 输出到 VNC 窗口。同一份
> `qt-gui-demo` 二进制，借由 `./qt-gui-demo.sh {pl111|virtio|eglfs|wayland}`
> 走四条不同的显示路径。前两个走 linuxfb（fbdev），第三个走 eglfs+KMS+GBM，
> 第四个先起 weston 再以 wayland client 身份连进去。本文整理这三条路径
> 在 guest 内核态/用户态、libdrm、Mesa、virtio-gpu 这条链上各自停在哪里、
> 经过几次拷贝、谁拥有哪个 tty，最后总结何时挑哪个。
>
> 项目仓库：<https://github.com/PenNameLuXun/qemu-vp>
> 本文路径：<https://github.com/PenNameLuXun/qemu-vp/blob/main/jxl-qt-display-backends.md>
>
> 配套阅读：[jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) 里讲透了
> fbcon / VT / linuxfb / eglfs 在 tty 占用层面的相互关系，本文不重复，把
> 重点放在 wayland 链路以及三条路径的横向对比。

## 一、三个 backend 一览

| backend | Qt 平台插件 | guest 侧停在哪 | host 侧由谁画到 VNC | 占用的 tty | 启动耗时（QEMU 模拟） |
|---|---|---|---|---|---|
| `linuxfb` (fb0/fb1) | `libqlinuxfb.so` | 把像素 memcpy 进 `/dev/fb{0,1}` | virtio-gpu 或 pl111 模型把 framebuffer 物理内存搬给 QEMU display | tty1（fbcon 拥有）| <1s |
| `eglfs` + KMS+GBM | `libqeglfs.so` + `eglfs_kms` plugin | OpenGL ES 命令 → Mesa llvmpipe → GBM 缓冲 → DRM atomic commit | virtio-gpu 把 GBM scanout buffer 当 fb 显示 | tty1（Qt 自己抢成 `KD_GRAPHICS`） | ~3–5s |
| `wayland` | `libqwayland-generic.so` + `libxdg-shell.so` | OpenGL ES → Mesa → wl_buffer 通过 unix socket 交给 weston | weston `gl-renderer.so` 合成后走 DRM | tty2（weston 占）；tty1 fbcon 不动 | ~20–30s（llvmpipe shader 首次编译）|

四个模式共用同一 `qt-gui-demo` ELF（Qt 6.8.3 cross-compile），区别只在
启动器（`/qt-gui-demo.sh`）按第一个 argv 切换 `QT_QPA_PLATFORM` 和环境
变量。

## 二、linuxfb：最薄的一条路径

详细路径参见 [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) 第七、
十二节。这里只给精简版：

```
Qt qt-gui-demo (用户态)
  └─ libQt6Gui 软件光栅器 (QRasterPaintEngine)
       │ 像素已经是 8-bit ARGB
       ▼
  /dev/fb0 (mmap'd framebuffer)
       │ guest 内核 fbdev 驱动:
       │   virtio-gpu fbdev emulation (DRM_FBDEV_EMULATION) ← virtio
       │   pl111-drm  fbdev emulation                       ← pl111
       ▼
  DRM/KMS 直接拿同一段物理内存当 scanout
       ▼
  virtio-gpu / pl111 把这段内存当 framebuffer 推给 QEMU display
       ▼
  host QEMU → VNC server → 客户端窗口
```

特点：

- **零 GL**，纯 CPU 光栅化，Qt 走 `QRasterPaintEngine`。
- **零额外 copy**：Qt 写 mmap 的就是 scanout buffer 本身（fbdev_emulation
  会把 fbdev 的 ioctl 翻译成 DRM dumb-buffer 操作）。
- **fbcon 还在 tty1 上活着**：Qt linuxfb 不接管 VT，所以 fbcon 也在往
  同一个 framebuffer 里写文字 console —— 两者抢同一段内存，谁后写谁
  覆盖。看到字符把 GUI 啃掉一块就是这个原因。
- **能力上限**：只有 2D bitblit。要动画用 `update()` + 软件合成，没有
  GPU 加速；JXL 上 800×600 跑 60Hz 已经满负载。

适合 `pl111` 这种没有 GPU 的纯 framebuffer 设备做"能动起来"的最小
demo，也适合用 [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md)
里讨论的 fbcon ↔ linuxfb 冲突做教学实验。

## 三、eglfs+KMS+GBM：单进程"自给自足"的 GL 路径

```
Qt qt-gui-demo (用户态)
  └─ libQt6Gui (QSGRenderLoop / QSGRenderContext)
       │ 把 scene graph 翻译成 GL ES 命令
       ▼
  Qt eglfs_kms plugin    ← libqeglfs.so + integration plugin
       │ eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm_device)
       │ eglCreateWindowSurface(gbm_surface)
       ▼
  libEGL.so.1 / libGLESv2.so.2 (Mesa)
       │
       │ Mesa 没有 virtio-gpu 的 host-side GPU 加速时:
       │   llvmpipe 把 GL 命令在 CPU 上跑出像素
       │
       ▼
  GBM (libgbm.so) → gbm_bo_get_fd() → DRM PRIME fd
       │
       ▼
  libdrm: drmModeAtomicCommit() — 把 GBM bo 当作 plane
       │ ioctl(/dev/dri/card0, DRM_IOCTL_MODE_ATOMIC)
       ▼
  guest 内核 virtio-gpu DRM 驱动 (drivers/gpu/drm/virtio/)
       │ 把 atomic commit 翻译成 virtio command:
       │   VIRTIO_GPU_CMD_RESOURCE_CREATE_2D
       │   VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D
       │   VIRTIO_GPU_CMD_SET_SCANOUT
       │   VIRTIO_GPU_CMD_RESOURCE_FLUSH
       ▼
  QEMU virtio-gpu 设备模型 (hw/display/virtio-gpu.c)
       │ 拿到 guest pixmap → DisplaySurface
       ▼
  host VNC server / SDL backend → 窗口
```

关键事实：

- **eglfs 接管 tty1 的图形模式**：Qt 启动时 `ioctl(KDSETMODE, KD_GRAPHICS)`，
  fbcon 不再往屏上写字。这就是 `vt-restore` 工具存在的原因 —— Ctrl+C
  以外的方式杀掉 Qt 后 fbcon 不会自己恢复（详见 [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md)
  第七节）。
- **GBM = scanout-capable buffer 分配器**：Mesa 的 llvmpipe 把 GL 命令
  渲染到一个 `gbm_bo`，这块内存既能被 GPU 读，也能直接被 DRM 当作
  scanout。avoid 一次 GPU→CPU→GPU 的回放。
- **llvmpipe 是软件 rasterizer**：JXL 的 virtio-gpu 模型没有 virgl 加速
  （host Mesa 也帮不上忙），所以 GL 是在 guest CPU 上跑的。能跑 GL 4.5
  core profile，但单帧成本和 fb 比高很多 —— qt-gui-demo 里那个旋转
  立方体在 emulated 环境下大概只有 5–15 FPS。
- **单进程**：Qt 自己起、自己画、自己 commit。没有 compositor 介入，
  也没有 IPC 开销。

适合：只跑一个全屏 Qt 应用、需要 GL 但不需要多窗口或者键盘焦点切换的
embedded 场景。这是 Qt 官方推荐的"嵌入式 single-app 模型"。

## 四、wayland：客户端/合成器分离

wayland 模式分两步走：先在 tty2 起 weston compositor，然后 Qt 以 wayland
client 身份连过来。在我们当前的 launcher 里这是**按需启动** —— 同一
session 里如果 weston 已经在，再跑一次 qt-gui-demo 就直接 attach。

```
                  ╔═══════════ weston 进程（compositor）══════════╗
                  ║                                                ║
qt-gui-demo (用户态 wayland client)                                 ║
  └─ libqwayland-generic.so (Qt platform plugin)                    ║
       │ wl_display_connect("/run/user/0/wayland-0")                ║
       │ wl_registry_listen → enumerate globals:                    ║
       │   wl_compositor, wl_shm, xdg_wm_base, wl_seat, ...         ║
       ▼                                                            ║
  libxdg-shell.so (shell-integration plugin)                        ║
       │ xdg_surface / xdg_toplevel 建窗口、要 decoration            ║
       ▼                                                            ║
  libEGL.so.1 / libGLESv2.so.2 + Mesa llvmpipe                      ║
       │ eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND, wl_display)    ║
       │ eglCreateWindowSurface(wl_egl_window)                      ║
       │ 渲染到 wl_buffer (经 wl_drm/zwp_linux_dmabuf 协议)          ║
       │                                                            ║
       │ wl_surface.attach(wl_buffer) + commit                      ║
       └────────── unix socket (wayland 协议) ────────┐             ║
                                                      │             ║
                                                      ▼             ║
                                       weston 主线程 receive        ║
                                       libweston-9 core             ║
                                          │                         ║
                                          │ surface manager,        ║
                                          │ damage tracking, etc    ║
                                          ▼                         ║
                                       desktop-shell.so             ║
                                          │ 处理 xdg_wm_base /      ║
                                          │ xdg_toplevel / window   ║
                                          │ stacking, 加 cairo      ║
                                          │ 标题栏（server-side      ║
                                          │ decoration）            ║
                                          ▼                         ║
                                       gl-renderer.so               ║
                                          │ 把所有 client 的         ║
                                          │ wl_buffer 当 GL texture │
                                          │ 合成到一张大 FBO        ║
                                          │ (Mesa llvmpipe 软件     ║
                                          │  跑这段 GL)             ║
                                          ▼                         ║
                                       drm-backend.so               ║
                                          │ 把 FBO 内容借助 GBM      ║
                                          │ scanout buffer 提交     ║
                                          │ drmModeAtomicCommit     ║
                                          ▼                         ║
                  ╚══ ioctl(/dev/dri/card0, DRM_IOCTL_MODE_ATOMIC) ══╝
                                          ▼
                  guest virtio-gpu DRM → VIRTIO_GPU_CMD_* → QEMU → VNC
```

几个值得拎出来的细节：

### 4.1 socket 在哪、什么时候出现

`XDG_RUNTIME_DIR=/run/user/0`，weston 在那里建一个 unix socket
`wayland-0`。launcher 里的轮询逻辑等的就是 `[ -S $sock ]` 出现。
weston 通常先建 socket，再加载 backend、shell module —— 所以"看到
socket"不等于"已经准备好接客"。我们的 launcher 给了 60s budget，
因为 emulated aarch64 跑 llvmpipe shader 首次编译加上 desktop-shell
helper 启动确实需要 20–30s。

### 4.2 weston 自己也是一个 GL 应用

weston 的 `gl-renderer.so` 在 weston 进程里 `eglMakeCurrent` 之后用
GL 把每个 client 的 wl_buffer 当成 texture 画到一个 FBO 里。然后
`drm-backend.so` 把 FBO 内容 scanout。也就是说：**整个流水线里
GL 跑了两次** —— client 一次（Qt 画自己），compositor 一次（weston
合成）。

JXL 上由于都跑在 llvmpipe（软光栅），加上 emulated CPU，这就是
wayland 模式比 eglfs 慢的根本原因。

### 4.3 desktop-shell helper 的角色

weston 的 `desktop-shell.so` module 在 compositor 进程里负责
**注册 `xdg_wm_base` 全局**（这是 client 创建窗口所必需的协议）。
注册完，它会 fork 一个独立进程 `weston-desktop-shell`，本身是
另一个 wayland client，画 panel/背景。

这俩职责分离很容易踩坑：helper 进程跑不起来（比如缺动态库），
weston 会判定整个 desktop-shell module 失败 → 整个 compositor
quit。client 这时已经连上 socket、看见过 globals，但是
`xdg_wm_base` 在被 retract → Qt 的 xdg-shell `initialize()` 返回
false → 报 "Loading shell integration failed"。

这就是上一轮调试的核心 bug：cairo NEEDED 链上的 libX11/XCB/libuuid
都没装到 rootfs，helper status 127，weston quit。修法是
往 `WESTON_PKGS` 里把 cairo 的 transitive X 依赖补齐。

### 4.4 server-side decoration

weston `[shell]` 配 `panel-position=top` 之后，weston 通过
`zxdg_decoration_manager_v1` 协议告知 client：你别画标题栏，我
来画。Qt 的 xdg-shell plugin 看见这个协议会拒绝自己 draw 装饰，
最后窗口的标题栏/边框由 weston 用 cairo 画出来 —— 这也是为什么
我们一定要装 libcairo2 + libpango 那一票包。

如果没有 server-side decoration 协议、Qt 又没有 libdecor，窗口
会是无装饰的 client-only surface（功能上仍然能用，只是没有"窗口
看起来像个窗口"的感觉）。

### 4.5 tty 划分

- weston 启动时拿到 `--tty=2`，`ioctl(KDSETMODE, KD_GRAPHICS)`
  把 tty2 切到图形模式，自己 DRM master。
- tty1 的 fbcon **完全没碰** —— 串口 console 和 fbcon log 仍然
  在 tty1 上正常工作。
- VNC 看到的画面是 host 的 virtio-gpu scanout，跟 tty 没关系；
  VNC 客户端切 tty 这种事和这里完全无关。

所以 wayland 模式相对 eglfs 的一个隐性好处：**fbcon 不会被你的 Qt
应用 monopolize**，串口 shell 看 tty1 时仍然有内核 dmesg 输出。

## 五、横向对比

### 5.1 buffer 走多少次

|  | client → compositor copy | compositor → DRM copy | 总 GPU/CPU 渲染次数 |
|---|---|---|---|
| linuxfb | — | Qt 直接写 fb mmap，DRM 直接 scanout，0 次 | 1（Qt 软光栅）|
| eglfs+KMS | — | GBM bo 直接 scanout，0 次 | 1（llvmpipe）|
| wayland | dmabuf 共享 → 0 次（理论）；SHM fallback → 1 次 | weston FBO → GBM scanout，多一次 GL 合成 | 2（client llvmpipe + compositor llvmpipe）|

理论上 wayland + dmabuf 应该跟 eglfs 一样高效（buffer 全程 zero-copy），
但 emulated 环境里 llvmpipe 双跑 + dmabuf 路径上的 sync fence 让它实际
慢一截。看 weston 日志会注意到：

```
warning: Disabling render GPU timeline and explicit synchronization
due to missing EGL_ANDROID_native_fence_sync extension
```

—— Mesa 在 llvmpipe 下没有 fence 同步，weston 退化到隐式 GL flush。
正确硬件上没这个问题。

### 5.2 谁占什么 tty / VT

| backend | tty1 (fbcon) | tty2 | DRM master |
|---|---|---|---|
| linuxfb | fbcon 仍然在写 | 不动 | fbdev_emulation（kernel-side）|
| eglfs+KMS | Qt 切 `KD_GRAPHICS`，fbcon 闭嘴 | 不动 | Qt（用户态）|
| wayland | 完全不动 | weston 切 `KD_GRAPHICS` | weston |

eglfs 退出后 fbcon 需要靠 `vt-restore /dev/tty1` 找回 `KD_TEXT`；
wayland 退出后 weston 自己 cleanup，tty1 自始至终没被碰过 —— 这是
wayland 模式相对 eglfs 的可运维性优势。

### 5.3 进程数和 IPC

|  | 进程数 | IPC |
|---|---|---|
| linuxfb | 1（qt-gui-demo）| 无 |
| eglfs+KMS | 1（qt-gui-demo）| 无 |
| wayland | 4+（qt-gui-demo + weston + weston-desktop-shell + weston-keyboard）| wayland 协议（unix socket）+ wl_buffer fd 传递 |

### 5.4 同样的二进制，跑得动还是跑不动

| backend | 需要 GL | 需要 KMS/DRM | 需要 compositor |
|---|---|---|---|
| linuxfb | ✗ | fbdev emulation 即可 | ✗ |
| eglfs+KMS | ✓ | ✓ | ✗ |
| wayland | ✓（client + compositor 都要）| ✓ | ✓（额外~30MB rootfs） |

PL111 只有 fbdev、没有 GL，所以**只能跑 linuxfb**。virtio-gpu 三种都
能跑，但软件 GL 性能受限于 emulated CPU。

### 5.5 启动序列实测（emulated aarch64，llvmpipe）

`linuxfb`：

```
~ # time ./qt-gui-demo.sh virtio
[QApplication created]                    ← ~200ms
[first frame on /dev/fb0]                 ← +50ms
```

`eglfs`：

```
~ # time ./qt-gui-demo.sh eglfs
[Mesa llvmpipe egl init]                  ← ~2-3s（shader cache miss）
[Qt eglfs creating EGL surface]
[first frame via DRM atomic]              ← +1-2s
```

`wayland`（冷启动，weston 也是第一次起）：

```
~ # time ./qt-gui-demo.sh wayland
qt-gui-demo.sh: starting weston ...        ← weston fork
[weston: load drm-backend.so]              ← +1s
[weston: load gl-renderer.so]              ← +25-30s（llvmpipe 首编）
[weston: socket ready]                     ← launcher 通过 [-S] 检测
[weston: spawn desktop-shell + keyboard]
[Qt: wl_display_connect]
[Qt: roundtrip get registry]               ← +1-2s
[Qt: load xdg-shell shell-integration]
[Qt: create wl_egl_window]                 ← 触发 Qt 这边 llvmpipe shader 编译
[Qt: first frame as wl_buffer]             ← +3-5s
```

总壁钟时间 wayland 大约是 eglfs 的 7–8 倍，几乎全部花在 GL shader 编译
（llvmpipe 把 GLSL JIT 到 LLVM IR 再 codegen 到 ARM64 机器码）。Qt 客户端
和 weston 合成器各自跑一次，吃两次成本。

## 六、什么时候挑哪个

| 场景 | 推荐 |
|---|---|
| PL111 / 纯 fb 设备，只要"能动"| `pl111` (linuxfb) |
| 单 Qt 应用 + 需要 GL（OpenGL ES 2/3）/ Qt Quick / 3D| `eglfs` |
| 学习 / 复现 wayland 完整链路、需要多个 GUI 客户端共存| `wayland` |
| 想看 fbcon ↔ 用户态显示冲突| `pl111` 或 `virtio` （linuxfb），然后跟 [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) 对照 |
| Ctrl+C 之外的杀法把 tty1 弄黑| `eglfs` 一定会触发，配合 `vt-restore` 工具调试 |
| 想保留串口 + fbcon 在 tty1 上同时观测 dmesg| `wayland`（占 tty2，tty1 不动）|

简单总结：

- **要轻量、要兼容旧 fb 设备 → linuxfb**
- **要 GL、嵌入式 single-app 心态 → eglfs**
- **要 wayland 协议栈本身的学习价值或者多窗口 → wayland**

JXL 这个 emulated 平台上，linuxfb 和 eglfs 是日常用的，wayland 主要
是为了练习/复现完整 wayland 链路 —— 性能不是它的卖点（emulated CPU 跑
llvmpipe 双跑必然慢），但是把整套 weston/qtwayland/protocol/dmabuf
都在一个可重复的 QEMU 镜像里调通了，这本身就是学习目标。

## 七、调试参考

调 wayland 路径的几条短路径：

1. **`./qt-gui-demo.sh wayland-debug`**：launcher 里专门加的诊断模式，
   会自动 export `QT_DEBUG_PLUGINS=1` + `QT_LOGGING_RULES="qt.qpa.*=true"`，
   并在 Qt 跑之前 `cat /tmp/weston.log`。
2. **client 协议层 trace**：`WAYLAND_DEBUG=1 ./qt-gui-demo.sh wayland`，
   会让 libwayland-client 把每条 wire-protocol 消息打到 stderr。看
   `wl_registry@2.global` 那串就知道 weston 实际广播了哪些接口。
3. **compositor 侧**：`/tmp/weston.log` —— 里头会看到 module load、helper
   spawn 状态、shell module load。helper status 127 意味着动态链接器
   解析失败，对照 `readelf -d` 找缺哪个 .so。
4. **buffer 类型**：如果 `gl-renderer` 提示 "EGL Wayland extension: no"，
   说明 server 拿不到 client 的 GL 纹理直引用，会退化到 SHM 拷贝路径。
   emulated 环境下经常如此，不影响功能但有性能代价。

## 八、常见问题（Q&A）

### Q：weston 是启动在 tty2 上的吗？VNC 窗口也是绑到 tty2 的吗？怎么做到的？

**weston 在 tty2 上 —— 是的**

launcher 里跑的是 `weston --tty=2`。weston 拿到这个参数后做三件事：

1. `ioctl(/dev/tty0, VT_ACTIVATE, 2)` — 让 tty2 成为 active VT
2. `ioctl(/dev/tty2, KDSETMODE, KD_GRAPHICS)` — tty2 切图形模式，fbcon 不再往这个 VT 的字符缓冲里渲染
3. `drmSetMaster(/dev/dri/card0)` — 抢 DRM master 权限，从此 scanout 由 weston 控

为什么挑 tty2？因为 tty1 上有 fbcon + 串口 getty 还在跑，不想动它。tty2 是个干净的 VT。

**VNC 窗口 —— 不是绑到 tty2 的**

这是关键。VNC 窗口跟 tty/VT 没有任何关系。它绑的是 **QEMU 的 virtio-gpu
设备模型**：

```
guest 内核 DRM scanout buffer (一块物理内存)
      │
      ▼
QEMU virtio-gpu 设备 (hw/display/virtio-gpu.c)
      │ 把这块 pixmap 交给 QEMU 的 DisplaySurface
      ▼
QEMU VNC server (-vnc :0)
      │
      ▼
你电脑上的 VNC 客户端窗口
```

VNC 服务器只看 **同一个 virtio-gpu scanout 输出**（叫它 Virtual-1），它根本
不知道、也不关心 guest 内核里现在 active VT 是 1 还是 2。它就是把"当前
scanout buffer 里的像素"按帧推给客户端。

**那为什么 VNC 看起来"切到 weston"了**

因为 scanout buffer 的**内容**变了，不是 VNC 切了源：

```
t=0    : 只有 fbcon 在画 tty1                  → scanout = 文字 console
         VNC 显示：文字 shell

t=10   : 跑 ./qt-gui-demo.sh wayland
         weston VT_ACTIVATE(2) → kernel 把 active VT 切到 2
         fbcon 本来要开始画 tty2 的字符缓冲，但 weston 立刻
         把 tty2 切到 KD_GRAPHICS → fbcon 闭嘴
         weston drmSetMaster() → 抢走 DRM 控制权
         weston gl-renderer 开始往 scanout 写自己的合成结果
         → scanout = weston 合成的画面
         VNC 显示：weston 桌面（+ Qt 窗口）

t=N    : Ctrl+C 杀 qt-gui-demo
         launcher 的 trap 杀 weston
         weston SIGTERM cleanup:
           drmDropMaster → tty2 回 KD_TEXT → VT_ACTIVATE(1)
         fbcon 重新接管 scanout
         → scanout = 文字 console again
```

整条路径里 VNC 永远没动 —— 它一直显示**同一个 virtio-gpu 的 Virtual-1
scanout**，只是这块内存的内容由不同进程依次填充。

**验证方法**

wayland 模式跑起来后，从串口 shell（ttyAMA0，不是 VNC 那个 tty1）里：

```sh
~ # chvt 1
```

VNC 窗口立刻切回文字 console（fbcon 重新画 tty1），weston 进程没死，
只是被踢出了 DRM master。再 `chvt 2` 又切回 weston 画面。这是经典的
VT switch handover —— 跟 X11 时代切 tty 是同一套机制，证明 VNC 看
的是 scanout 内容、不是 VT。

**对比 eglfs**

eglfs 没指定 tty 参数，Qt 默认用当前 active VT（tty1）：

- tty1 被 Qt 切到 KD_GRAPHICS → fbcon 闭嘴
- Qt 直接 drmSetMaster 写 scanout
- VNC 依然看的是同一个 virtio-gpu scanout，只是内容从 fbcon 换成 Qt

wayland 模式相对 eglfs 的唯一 tty 层面差别是：**weston 占的是 tty2，
所以 fbcon 在 tty1 上还能继续工作**（VNC 看不到 tty1 因为 active VT
是 2，但可以 `chvt 1` 切回去）。详见 [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) 第七节。

## 九、相关文档

- [jxl-tty-fbcon-display.md](jxl-tty-fbcon-display.md) —— fbcon / VT / linuxfb / eglfs 在 tty/VT 占用层面的全展开
- [README.md](README.md) —— 项目入口，列出所有 `run-jxl-*` 启动模式和 `qt-gui-demo` 构建步骤
