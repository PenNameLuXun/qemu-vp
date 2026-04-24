# uboot-learn

这个仓库用于在本地构建并启动一组 ARM64 引导链实验环境，核心围绕：

- QEMU
- U-Boot
- Linux
- BusyBox initramfs
- 自定义 `jxl` 机器

最常用入口有两个：

- `./build.sh`：构建各类镜像和辅助产物
- `./start.sh`：按预设启动某一种启动链

## 目录来源

- `qemu/`
  本地 QEMU 分支，包含自定义 `jxl` 板级与 SoC 模型
- `src/u-boot/`
  U-Boot 源码与 `jxl` 板级支持
- `src/linux/`
  Linux 内核源码
- `src/busybox/`
  BusyBox 源码
- `src/trusted-firmware-a/`
  TF-A 源码子模块
- `src/xen/`
  Xen 源码子模块
- `dts/`
  给 Linux 使用的独立 `jxl` 设备树
- `build/`
  所有构建输出目录

## 常用命令

```bash
./build.sh qemu
./build.sh jxl
./build.sh jxl-dtb
./build.sh kernel
./build.sh rootfs
./build.sh tfa
./build.sh xen

./start.sh virt
./start.sh raspi3b
./start.sh jxl
./start.sh jxl-linux
./start.sh jxl-linux-spl
./start.sh linux
```

## `build.sh` 产物说明

### QEMU

```bash
./build.sh qemu
```

输出：

- `qemu/build/qemu-system-aarch64`

说明：

- 构建仓库内的 QEMU fork
- `start.sh` 优先使用这个本地二进制；如果不存在，则回退到系统里的 `qemu-system-aarch64`

### U-Boot

```bash
./build.sh virt
./build.sh raspi3b
./build.sh jxl
```

输出：

- `build/virt/u-boot.bin`
- `build/rpi3/u-boot.bin`
- `build/jxl/u-boot.bin`
- `build/jxl/u-boot.img`
- `build/jxl/spl/u-boot-spl.bin`

说明：

- `virt` 使用 `qemu_arm64_defconfig`
- `raspi3b` 使用 `rpi_3_defconfig`
- `jxl` 使用 `jxl_defconfig`
- `jxl` 构建时同时要求：
  - `u-boot.bin`
  - `u-boot.img`
  - `spl/u-boot-spl.bin`
  这样既能支持 direct boot，也能支持 SPL 链路

### Linux DTB

```bash
./build.sh jxl-dtb
```

输出：

- `build/jxl/jxl-linux.dtb`

来源：

- `dts/jxl.dts`
- `dts/jxl.dtsi`

说明：

- 这是给 Linux 使用的独立 DTB
- 不等同于 U-Boot 内嵌的 `src/u-boot/arch/arm/dts/jxl.dts`

### Linux kernel

```bash
./build.sh kernel
```

输出：

- `build/linux/arch/arm64/boot/Image`

说明：

- 基于 `src/linux/` 构建
- 当前使用 `defconfig`

### BusyBox 与 initramfs

```bash
./build.sh busybox
./build.sh rootfs
```

输出：

- `build/busybox/busybox`
- `build/initramfs.cpio.gz`

说明：

- BusyBox 会被静态链接
- `build_rootfs()` 会创建一个最小根文件系统
- `/init` 会挂载 `proc/sys/dev` 并进入 shell
- 启动后可看到：

```text
jxl rootfs up.
```

### TF-A 与 Xen

```bash
./build.sh tfa
./build.sh xen
```

输出：

- `build/tfa/qemu/debug/bl31.bin`
- `build/xen/xen`

说明：

- 当前只是提供源码子模块与构建入口
- 还没有接入 `start.sh` 的实际启动链
- 规划见 [jxl-atf-xen-plan.md](jxl-atf-xen-plan.md)

## `start.sh` 模式说明

`start.sh` 是本仓库统一的启动入口。默认模式是：

```bash
./start.sh
```

等价于：

```bash
./start.sh virt
```

### `virt`

```bash
./start.sh virt
```

QEMU 参数核心是：

```bash
-machine virt
-cpu cortex-a57
-bios build/virt/u-boot.bin
```

启动链：

```text
QEMU -> U-Boot
```

镜像来源：

- `build/virt/u-boot.bin`
  来自 `build_uboot qemu_arm64_defconfig`

说明：

- 这是最简单的 U-Boot 验证模式
- U-Boot 通过 `-bios` 直接作为固件运行

### `raspi3b`

```bash
./start.sh raspi3b
```

QEMU 参数核心是：

```bash
-machine raspi3b
-cpu cortex-a53
-kernel build/rpi3/u-boot.bin
-dtb build/rpi3/arch/arm/dts/bcm2837-rpi-3-b.dtb
```

启动链：

```text
QEMU -> U-Boot
```

镜像来源：

- `build/rpi3/u-boot.bin`
  来自 `build_uboot rpi_3_defconfig`
- `build/rpi3/arch/arm/dts/bcm2837-rpi-3-b.dtb`
  由同一次 U-Boot 构建产出

说明：

- 串口使用 `-serial stdio`
- `stdout-path` 对应的是树莓派 mini-UART

### `jxl`

```bash
./start.sh jxl
```

QEMU 参数核心是：

```bash
-machine jxl
-cpu cortex-a53
-m 128M
-drive if=pflash,format=raw,file=build/jxl/jxl-flash.img
-kernel build/jxl/u-boot.bin
```

启动链：

```text
QEMU SRAM trampoline -> U-Boot proper
```

镜像来源：

- `build/jxl/u-boot.bin`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/jxl-flash.img`
  来自 `ensure_jxl_flash()`，是一个 16 MiB 全 `0xFF` 的空白 NOR flash 镜像

说明：

- 这个模式不使用 SPL
- `-kernel` 指向 `u-boot.bin`，QEMU 会走 `jxl` 板级的 direct boot 路径
- flash 只是挂上去供 U-Boot 识别和保存环境使用

### `jxl-linux`

```bash
./start.sh jxl-linux
```

QEMU 参数核心是：

```bash
-machine jxl
-drive if=pflash,format=raw,file=build/jxl/jxl-linux-flash.img
-drive if=sd,format=raw,file=build/jxl/jxl-linux.img
-device loader,file=build/jxl/jxl-linux.scr,addr=0x41f00000,force-raw=on
-kernel build/jxl/u-boot.bin
```

启动链：

```text
QEMU SRAM trampoline
  -> U-Boot proper
  -> 执行 DRAM 中预加载的 U-Boot script
  -> U-Boot 从 MMC ext4 分区读取 kernel / dtb / initramfs
  -> booti
  -> Linux
```

镜像来源：

- `build/jxl/u-boot.bin`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/jxl-linux.dtb`
  来自 `build_jxl_linux_dtb()`
- `build/linux/arch/arm64/boot/Image`
  来自 `build_kernel()`
- `build/initramfs.cpio.gz`
  来自 `build_rootfs()`
- `build/jxl/jxl-linux.img`
  来自 `ensure_jxl_mmc_image()`
- `build/jxl/jxl-linux-flash.img`
  来自 `ensure_jxl_flash()`
- `build/jxl/jxl-linux.scr`
  来自 `make_jxl_linux_script()`

MMC 镜像里放了什么：

- `Image`
- `jxl-linux.dtb`
- `initramfs.cpio.gz`

这些文件会被写入：

- 一个 128 MiB 的 MMC raw 镜像
- 镜像中有 DOS 分区表
- 第一个分区从 sector `2048` 开始
- 分区内容是 ext4

U-Boot script 做的事情：

```text
mmc dev 0
ext4load mmc 0:1 ${kernel_addr_r} /Image
ext4load mmc 0:1 ${fdt_addr_r} /jxl-linux.dtb
ext4load mmc 0:1 ${ramdisk_addr_r} /initramfs.cpio.gz
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

说明：

- 这个模式仍然不使用 SPL
- 只是把 Linux payload 从“QEMU 直接塞进内存”升级成“U-Boot 自己从 MMC ext4 分区读取”

### `jxl-linux-spl`

```bash
./start.sh jxl-linux-spl
```

QEMU 参数核心是：

```bash
-machine jxl
-drive if=pflash,format=raw,file=build/jxl/jxl-linux-spl-flash.img
-drive if=sd,format=raw,file=build/jxl/jxl-linux.img
-device loader,file=build/jxl/jxl-linux.scr,addr=0x41f00000,force-raw=on
-bios build/jxl/spl/u-boot-spl.bin
```

启动链：

```text
QEMU
  -> SPL (u-boot-spl.bin, 位于 SRAM)
  -> SPL 从 NOR flash 读取 U-Boot proper (u-boot.img)
  -> U-Boot proper 执行 DRAM 中预加载的脚本
  -> U-Boot 从 MMC ext4 分区读取 kernel / dtb / initramfs
  -> booti
  -> Linux
```

镜像来源：

- `build/jxl/spl/u-boot-spl.bin`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/u-boot.img`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/jxl-linux.img`
  来自 `ensure_jxl_mmc_image()`
- `build/jxl/jxl-linux-spl-flash.img`
  来自 `populate_jxl_spl_flash()`
- `build/jxl/jxl-linux.scr`
  来自 `make_jxl_linux_script()`

flash 镜像里放了什么：

- 一块 16 MiB 的 NOR flash 镜像
- 从起始偏移写入 `u-boot.img`
- 保留 flash 尾部环境区

说明：

- 这是当前仓库里最接近真实嵌入式启动链的模式
- SPL 负责从 flash 拉起 U-Boot proper
- Linux payload 仍然由 U-Boot 从 MMC 分区装载

### `linux`

```bash
./start.sh linux
```

QEMU 参数核心是：

```bash
-machine virt
-cpu cortex-a57
-m 512M
-kernel build/linux/arch/arm64/boot/Image
-initrd build/initramfs.cpio.gz
-append "console=ttyAMA0 earlycon"
```

启动链：

```text
QEMU -> Linux kernel -> BusyBox initramfs
```

镜像来源：

- `build/linux/arch/arm64/boot/Image`
  来自 `build_kernel()`
- `build/initramfs.cpio.gz`
  来自 `build_rootfs()`

说明：

- 这是一个纯 Linux 验证模式
- 不经过 U-Boot
- 当前 `jxl` 机器不会自动合成可直接给 Linux 用的 DTB，因此这里使用的是 `virt`

## `jxl` 相关镜像和地址

### 固定内存地址

`start.sh` 中当前使用了这些固定地址：

- `JXL_SCRIPT_ADDR=0x41f00000`
- `JXL_KERNEL_ADDR=0x42000000`
- `JXL_DTB_ADDR=0x44f00000`
- `JXL_INITRD_ADDR=0x45000000`

其中当前真正由 QEMU 直接预加载到内存的是：

- `jxl-linux.scr`

而 kernel / dtb / initramfs 在 `jxl-linux` 与 `jxl-linux-spl` 模式下都已经改成由 U-Boot 从 MMC 读取，不再通过 `-device loader` 直接放进 DRAM。

### flash 镜像

当前有两类常见 flash 文件：

- `build/jxl/jxl-flash.img`
  给 `jxl` direct boot 使用的空白 pflash
- `build/jxl/jxl-linux-spl-flash.img`
  给 `jxl-linux-spl` 使用，内部写入了 `u-boot.img`

### MMC 镜像

- `build/jxl/jxl-linux.img`

内容：

- MBR / DOS 分区表
- `p1` 为 ext4
- ext4 分区根目录下有：
  - `/Image`
  - `/jxl-linux.dtb`
  - `/initramfs.cpio.gz`

## 当前推荐启动方式

如果只是看 U-Boot：

```bash
./start.sh jxl
```

如果要走完整 Linux 启动链但不经过 SPL：

```bash
./start.sh jxl-linux
```

如果要看更接近真实板子的 `SPL -> proper -> Linux`：

```bash
./start.sh jxl-linux-spl
```

## 启动链对比

| 模式 | 第一阶段 | 第二阶段 | Linux payload 来源 | 是否使用 SPL | 当前状态 |
| --- | --- | --- | --- | --- | --- |
| `virt` | U-Boot (`-bios`) | 无 | 无 | 否 | 已可用 |
| `raspi3b` | U-Boot (`-kernel`) | 无 | 无 | 否 | 已可用 |
| `jxl` | QEMU SRAM trampoline | U-Boot proper | 无 | 否 | 已可用 |
| `jxl-linux` | QEMU SRAM trampoline | U-Boot proper | MMC ext4 分区 | 否 | 已可用 |
| `jxl-linux-spl` | SPL (`-bios`) | U-Boot proper from NOR flash | MMC ext4 分区 | 是 | 已可用 |
| `linux` | Linux kernel | BusyBox initramfs | `-initrd` 直接传入 QEMU | 否 | 已可用 |
| 未来 `jxl-atf/xen` | SPL / BL2 | BL31 / U-Boot / Xen | 待定 | 是 | 规划中 |

也可以把几个 `jxl` 模式简化理解成：

```text
jxl
  QEMU -> U-Boot proper

jxl-linux
  QEMU -> U-Boot proper -> MMC(ext4) -> Linux

jxl-linux-spl
  QEMU -> SPL -> NOR flash 中的 U-Boot proper -> MMC(ext4) -> Linux

未来 jxl-atf/xen
  QEMU -> SPL/BL2 -> BL31 -> U-Boot/Xen -> Dom0 Linux
```

## 当前状态与后续方向

当前已经打通：

- `QEMU -> U-Boot`
- `QEMU -> U-Boot -> Linux`
- `QEMU -> SPL -> U-Boot proper -> Linux`
- `U-Boot` 从 MMC ext4 分区加载 Linux payload

当前还没有接入 `start.sh` 的内容：

- TF-A / BL31
- Xen / Dom0 Linux

这部分源码和构建入口已经准备好，但启动链还在规划与集成阶段，见：

- [jxl-atf-xen-plan.md](jxl-atf-xen-plan.md)
