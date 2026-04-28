# uboot-learn

这个仓库用于在本地构建并启动一组 ARM64 引导链实验环境，核心围绕：

- QEMU
- U-Boot
- Linux
- BusyBox initramfs
- TF-A (ARM Trusted Firmware)
- OP-TEE (Trusted Execution Environment)
- Xen (Hypervisor)
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
- `src/optee_os/`
  OP-TEE 源码子模块
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
./build.sh optee

./start.sh virt
./start.sh raspi3b
./start.sh jxl
./start.sh jxl-linux
./start.sh jxl-linux-spl
./start.sh jxl-xen
./start.sh jxl-xen-atf
./start.sh jxl-optee
./start.sh jxl-xen-optee
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

- `build/tfa/jxl/debug/bl31.bin`
- `build/xen/xen`

说明：

- TF-A 使用仓库内 `PLAT=jxl`，产物用作 `jxl-xen-atf` 模式中 SPL 加载的 BL31
- Xen 使用 `arm64_defconfig`，产物会被 `start.sh jxl-xen` / `jxl-xen-atf` / `jxl-xen-optee` 写进 MMC 引导分区
- 完整规划见 [jxl-atf-xen-plan.md](jxl-atf-xen-plan.md)

### OP-TEE

```bash
./build.sh optee
```

输出：

- `build/optee/core/tee-raw.bin`

说明：

- 使用 `PLATFORM=vexpress PLATFORM_FLAVOR=jxl` 构建
- 产物作为 BL32 被嵌入 `jxl-atf-optee.itb` FIT 镜像
- OP-TEE 加载地址为 `0xbf001000`，位于安全 SRAM 中 BL31 下方
- 共享内存位于非安全 DRAM `0x43000000`（2 MiB）

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
-m 2G
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

### `jxl-xen`

```bash
./start.sh jxl-xen
```

QEMU 参数核心是：

```bash
-machine jxl
-cpu cortex-a53
-m 2G
-drive if=pflash,format=raw,file=build/jxl/jxl-xen-flash.img
-drive if=sd,format=raw,file=build/jxl/jxl-xen.img
-device loader,file=build/jxl/jxl-xen.scr,addr=0x41f00000,force-raw=on
-kernel build/jxl/u-boot.bin
```

启动链：

```text
QEMU SRAM trampoline
  -> U-Boot proper
  -> 执行 DRAM 中预加载的 U-Boot script
  -> U-Boot 从 MMC ext4 分区读取 xen / Image / jxl-xen.dtb / initramfs
  -> booti ${xen_addr_r} - ${fdt_addr_r}
  -> Xen
  -> Dom0 Linux
```

镜像来源：

- `build/jxl/u-boot.bin`
  来自 `build_uboot jxl_defconfig`
- `build/xen/xen`
  来自 `build_xen()`
- `build/linux/arch/arm64/boot/Image`
  来自 `build_kernel()`
- `build/initramfs.cpio.gz`
  来自 `build_rootfs()`
- `build/jxl/jxl-xen.dtb`
  来自 `build_jxl_xen_dtb()`，在 `jxl-linux.dtb` 上叠加 overlay 注入 Xen 启动参数和 Dom0 multiboot 模块
- `build/jxl/jxl-xen.img`
  来自 `ensure_jxl_xen_mmc_image()`
- `build/jxl/jxl-xen-flash.img`
  来自 `ensure_jxl_flash()`，是空白 NOR flash
- `build/jxl/jxl-xen.scr`
  来自 `make_jxl_xen_script()`

MMC 镜像里放了什么：

- `xen`
- `Image`（Dom0 内核）
- `jxl-xen.dtb`
- `initramfs.cpio.gz`

U-Boot script 做的事情：

```text
mmc dev 0
ext4load mmc 0:1 ${xen_addr_r}        /xen
ext4load mmc 0:1 ${dom0_kernel_addr_r} /Image
ext4load mmc 0:1 ${dom0_initrd_addr_r} /initramfs.cpio.gz
ext4load mmc 0:1 ${fdt_addr_r}        /jxl-xen.dtb
booti ${xen_addr_r} - ${fdt_addr_r}
```

固定加载地址：

- `xen_addr_r            = 0x92000000`
- `dom0_kernel_addr_r    = 0x80000000`
- `dom0_initrd_addr_r    = 0x90000000`
- `fdt_addr_r            = 0x91000000`

说明：

- 这个模式仍然不使用 SPL，也不经过 TF-A
- 与 `jxl-linux` 的区别在于 payload：U-Boot 启动的是 Xen，再由 Xen 启动 Dom0
- DTB 通过 fdtoverlay 注入 `/chosen/xen,xen-bootargs` 与 Dom0 的 `multiboot,kernel` / `multiboot,ramdisk` 节点

### `jxl-xen-atf`

```bash
./start.sh jxl-xen-atf
```

QEMU 参数核心是：

```bash
-machine jxl
-cpu cortex-a53
-m 2G
-drive if=pflash,format=raw,file=build/jxl/jxl-xen-atf-flash.img
-drive if=sd,format=raw,file=build/jxl/jxl-xen.img
-device loader,file=build/jxl/jxl-xen.scr,addr=0x41f00000,force-raw=on
-bios build/jxl/spl/u-boot-spl.bin
```

启动链：

```text
QEMU
  -> SPL (u-boot-spl.bin, 位于 SRAM)
  -> SPL 从 NOR flash 读取 FIT (jxl-atf.itb)
       FIT 包含 BL31 + U-Boot proper + jxl.dtb
  -> BL31 (TF-A) 在 EL3 运行
  -> 跳转至 U-Boot proper (EL2)
  -> U-Boot proper 执行 DRAM 中预加载的脚本
  -> U-Boot 从 MMC ext4 分区读取 xen / Image / jxl-xen.dtb / initramfs
  -> booti ${xen_addr_r} - ${fdt_addr_r}
  -> Xen
  -> Dom0 Linux
```

镜像来源：

- `build/jxl/spl/u-boot-spl.bin`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/jxl-atf.itb`
  来自 `build_jxl_atf_fit()`，把 BL31、U-Boot proper、U-Boot DTB 打包成 FIT
- `build/tfa/jxl/debug/bl31.bin`
  来自 `build_tfa()`，使用 `PLAT=jxl`
- `build/xen/xen`
  来自 `build_xen()`
- `build/linux/arch/arm64/boot/Image`
  来自 `build_kernel()`
- `build/initramfs.cpio.gz`
  来自 `build_rootfs()`
- `build/jxl/jxl-xen.dtb`
  来自 `build_jxl_xen_dtb()`
- `build/jxl/jxl-xen.img`
  来自 `ensure_jxl_xen_mmc_image()`
- `build/jxl/jxl-xen-atf-flash.img`
  来自 `populate_jxl_spl_flash()`，把 `jxl-atf.itb` 写入 NOR flash
- `build/jxl/jxl-xen.scr`
  来自 `make_jxl_xen_script()`

FIT 镜像里放了什么：

- `images/uboot`：`u-boot-nodtb.bin`，load/entry = `0x40080000`
- `images/atf`：BL31，load/entry = `0xbff90000`
- `images/fdt-0`：`arch/arm/dts/jxl.dtb`
- 默认 configuration `conf` 把 BL31 当作 firmware，U-Boot 当作 loadable，DTB 一起加载

说明：

- 这是当前仓库里最完整的启动链，覆盖 SPL / BL31 / U-Boot / Xen / Dom0 Linux
- SPL 不再直接装载 U-Boot proper，而是装载 FIT，让 BL31 作为 firmware 先于 U-Boot 运行
- 与 `jxl-xen` 的区别在于第一阶段：多了 SPL + TF-A，从 EL3 起步进入 U-Boot

### `jxl-optee`

```bash
./start.sh jxl-optee
```

QEMU 参数核心是：

```bash
-machine jxl
-cpu cortex-a53
-m 2G
-drive if=pflash,format=raw,file=build/jxl/jxl-optee-flash.img
-drive if=sd,format=raw,file=build/jxl/jxl-optee.img
-device loader,file=build/jxl/jxl-linux.scr,addr=0x41f00000,force-raw=on
-bios build/jxl/spl/u-boot-spl.bin
```

启动链：

```text
QEMU
  -> SPL (u-boot-spl.bin, 位于 SRAM)
  -> SPL 从 NOR flash 读取 FIT (jxl-atf-optee.itb)
       FIT 包含 BL31(opteed) + OP-TEE(BL32) + U-Boot proper(BL33) + jxl.dtb
  -> BL31 (TF-A) 在 EL3 运行
  -> OP-TEE (BL32) 在 Secure EL1 运行
  -> 跳转至 U-Boot proper (EL2)
  -> U-Boot proper 执行 DRAM 中预加载的脚本
  -> U-Boot 从 MMC ext4 分区读取 kernel / dtb / initramfs
  -> booti
  -> Linux
```

镜像来源：

- `build/jxl/spl/u-boot-spl.bin`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/jxl-atf-optee.itb`
  来自 `build_jxl_atf_optee_fit()`，把 BL31、OP-TEE、U-Boot proper、U-Boot DTB 打包成 FIT
- `build/tfa-opteed/jxl/debug/bl31.bin`
  来自 `build_tfa opteed`，使用 `PLAT=jxl SPD=opteed`，与 `build/tfa/` 下不带 SPD 的 BL31 完全分开，避免污染 `jxl-xen-atf` 等模式
- `build/optee/core/tee-raw.bin`
  来自 `build_optee()`，使用 `PLATFORM=vexpress PLATFORM_FLAVOR=jxl`
- `build/jxl/jxl-optee.dtb`
  来自 `build_jxl_optee_dtb()`，在 `jxl-linux.dtb` 上叠加 [`dts/jxl-optee-overlay.dts`](dts/jxl-optee-overlay.dts) 注入 `/firmware/optee` 节点
- `build/jxl/jxl-optee.img`
  来自 `ensure_jxl_mmc_image "$MMC" "$OUT/jxl-optee.dtb"`，结构与 `jxl-linux.img` 相同但 DTB 是 optee-augmented 版本
- `build/jxl/jxl-optee-flash.img`
  来自 `populate_jxl_spl_flash()`，把 `jxl-atf-optee.itb` 写入 NOR flash
- `build/jxl/jxl-linux.scr`
  来自 `make_jxl_linux_script()`，DTB 在 MMC 中仍以 `/jxl-linux.dtb` 命名所以脚本不变

FIT 镜像里放了什么：

- `images/uboot`：`u-boot-nodtb.bin`，load/entry = `0x40080000`
- `images/atf`：BL31，load/entry = `0xbff90000`
- `images/tee`：OP-TEE (BL32)，load/entry = `0xbf001000`
- `images/fdt-0`：`arch/arm/dts/jxl.dtb`
- 默认 configuration `conf` 把 BL31 当作 firmware，U-Boot 和 OP-TEE 为 loadables，DTB 一起加载

说明：

- 在 `jxl-linux-spl` 的基础上增加了 TF-A → OP-TEE 安全链路
- Linux 运行在 Normal EL1，OP-TEE 驻留在 Secure EL1
- SPL 不再直接装载 U-Boot proper，而是装载 FIT
- BL31 先拉起 OP-TEE 建立安全世界，再拉起 U-Boot

### `jxl-xen-optee`

```bash
./start.sh jxl-xen-optee
```

QEMU 参数核心是：

```bash
-machine jxl
-cpu cortex-a53
-m 2G
-drive if=pflash,format=raw,file=build/jxl/jxl-xen-optee-flash.img
-drive if=sd,format=raw,file=build/jxl/jxl-xen-optee.img
-device loader,file=build/jxl/jxl-xen.scr,addr=0x41f00000,force-raw=on
-bios build/jxl/spl/u-boot-spl.bin
```

启动链：

```text
QEMU
  -> SPL (u-boot-spl.bin, 位于 SRAM)
  -> SPL 从 NOR flash 读取 FIT (jxl-atf-optee.itb)
       FIT 包含 BL31(opteed) + OP-TEE(BL32) + U-Boot proper(BL33) + jxl.dtb
  -> BL31 (TF-A) 在 EL3 运行
  -> OP-TEE (BL32) 在 Secure EL1 运行
  -> 跳转至 U-Boot proper (EL2)
  -> U-Boot proper 执行 DRAM 中预加载的脚本
  -> U-Boot 从 MMC ext4 分区读取 xen / Image / jxl-xen.dtb / initramfs
  -> booti ${xen_addr_r} - ${fdt_addr_r}
  -> Xen
  -> Dom0 Linux
```

镜像来源：

- `build/jxl/spl/u-boot-spl.bin`
  来自 `build_uboot jxl_defconfig`
- `build/jxl/jxl-atf-optee.itb`
  来自 `build_jxl_atf_optee_fit()`
- `build/tfa-opteed/jxl/debug/bl31.bin`
  来自 `build_tfa opteed`
- `build/optee/core/tee-raw.bin`
  来自 `build_optee()`
- `build/xen/xen`
  来自 `build_xen()`
- `build/linux/arch/arm64/boot/Image`
  来自 `build_kernel()`
- `build/initramfs.cpio.gz`
  来自 `build_rootfs()`
- `build/jxl/jxl-xen-optee.dtb`
  来自 `build_jxl_xen_optee_dtb()`，在 `jxl-xen.dtb` 上再叠加 optee overlay
- `build/jxl/jxl-xen-optee.img`
  来自 `ensure_jxl_xen_mmc_image "$MMC" "$OUT/jxl-xen-optee.dtb"`
- `build/jxl/jxl-xen-optee-flash.img`
  来自 `populate_jxl_spl_flash()`，把 `jxl-atf-optee.itb` 写入 NOR flash
- `build/jxl/jxl-xen.scr`
  来自 `make_jxl_xen_script()`

说明：

- 这是当前仓库里最完整的启动链：SPL / BL31 / OP-TEE / U-Boot / Xen / Dom0 Linux
- 与 `jxl-xen-atf` 的区别在于多了 OP-TEE (BL32)
- OP-TEE 运行在 Secure EL1，提供 TEE 可信执行环境

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

当前的 flash 文件：

- `build/jxl/jxl-flash.img`
  给 `jxl` direct boot 使用的空白 pflash
- `build/jxl/jxl-linux-flash.img`
  给 `jxl-linux` 使用的空白 pflash
- `build/jxl/jxl-xen-flash.img`
  给 `jxl-xen` 使用的空白 pflash
- `build/jxl/jxl-linux-spl-flash.img`
  给 `jxl-linux-spl` 使用，内部写入了 `u-boot.img`
- `build/jxl/jxl-xen-atf-flash.img`
  给 `jxl-xen-atf` 使用，内部写入了 `jxl-atf.itb` (BL31 + U-Boot proper + DTB 的 FIT)

### MMC 镜像

- `build/jxl/jxl-linux.img`
  给 `jxl-linux` / `jxl-linux-spl` 使用
- `build/jxl/jxl-xen.img`
  给 `jxl-xen` / `jxl-xen-atf` 使用

两者结构相同：

- MBR / DOS 分区表
- `p1` 为 ext4

`jxl-linux.img` 的 ext4 分区根目录下：

- `/Image`
- `/jxl-linux.dtb`
- `/initramfs.cpio.gz`

`jxl-xen.img` 的 ext4 分区根目录下：

- `/xen`
- `/Image`
- `/jxl-xen.dtb`
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

如果要看 `SPL -> BL31 -> OP-TEE -> U-Boot -> Linux`：

```bash
./start.sh jxl-optee
```

如果要看完整 `SPL -> BL31 -> OP-TEE -> U-Boot -> Xen -> Dom0 Linux`：

```bash
./start.sh jxl-xen-optee
```

## 启动链对比

| 模式 | 第一阶段 | 第二阶段 | Payload 来源 | 是否使用 SPL | 是否使用 TF-A | 是否使用 OP-TEE | 是否使用 Xen | 当前状态 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `virt` | U-Boot (`-bios`) | 无 | 无 | 否 | 否 | 否 | 否 | 已可用 |
| `raspi3b` | U-Boot (`-kernel`) | 无 | 无 | 否 | 否 | 否 | 否 | 已可用 |
| `jxl` | QEMU SRAM trampoline | U-Boot proper | 无 | 否 | 否 | 否 | 否 | 已可用 |
| `jxl-linux` | QEMU SRAM trampoline | U-Boot proper | MMC ext4 分区 | 否 | 否 | 否 | 否 | 已可用 |
| `jxl-linux-spl` | SPL (`-bios`) | U-Boot proper from NOR flash | MMC ext4 分区 | 是 | 否 | 否 | 否 | 已可用 |
| `jxl-xen` | QEMU SRAM trampoline | U-Boot proper | MMC ext4 分区 (xen+Dom0) | 否 | 否 | 否 | 是 | 已可用 |
| `jxl-xen-atf` | SPL (`-bios`) | FIT (BL31 + U-Boot) from NOR flash | MMC ext4 分区 (xen+Dom0) | 是 | 是 | 否 | 是 | 已可用 |
| `jxl-optee` | SPL (`-bios`) | FIT (BL31 + OP-TEE + U-Boot) from NOR flash | MMC ext4 分区 | 是 | 是 | 是 | 否 | 已可用 |
| `jxl-xen-optee` | SPL (`-bios`) | FIT (BL31 + OP-TEE + U-Boot) from NOR flash | MMC ext4 分区 (xen+Dom0) | 是 | 是 | 是 | 是 | 已可用 |
| `linux` | Linux kernel | BusyBox initramfs | `-initrd` 直接传入 QEMU | 否 | 否 | 否 | 否 | 已可用 |

也可以把几个 `jxl` 模式简化理解成：

```text
jxl
  QEMU -> U-Boot proper

jxl-linux
  QEMU -> U-Boot proper -> MMC(ext4) -> Linux

jxl-linux-spl
  QEMU -> SPL -> NOR flash 中的 U-Boot proper -> MMC(ext4) -> Linux

jxl-xen
  QEMU -> U-Boot proper -> MMC(ext4) -> Xen -> Dom0 Linux

jxl-xen-atf
  QEMU -> SPL -> NOR flash 中的 FIT (BL31 + U-Boot) -> BL31 -> U-Boot proper -> MMC(ext4) -> Xen -> Dom0 Linux

jxl-optee
  QEMU -> SPL -> NOR flash 中的 FIT (BL31 + OP-TEE + U-Boot) -> BL31 -> OP-TEE -> U-Boot proper -> MMC(ext4) -> Linux

jxl-xen-optee
  QEMU -> SPL -> NOR flash 中的 FIT (BL31 + OP-TEE + U-Boot) -> BL31 -> OP-TEE -> U-Boot proper -> MMC(ext4) -> Xen -> Dom0 Linux
```

## 当前状态与后续方向

当前已经打通：

- `QEMU -> U-Boot`
- `QEMU -> U-Boot -> Linux`
- `QEMU -> SPL -> U-Boot proper -> Linux`
- `QEMU -> U-Boot proper -> Xen -> Dom0 Linux`
- `QEMU -> SPL -> BL31 -> U-Boot proper -> Xen -> Dom0 Linux`
- `QEMU -> SPL -> BL31 -> OP-TEE -> U-Boot proper -> Linux`
- `QEMU -> SPL -> BL31 -> OP-TEE -> U-Boot proper -> Xen -> Dom0 Linux`
- `U-Boot` 从 MMC ext4 分区加载 Linux / Xen payload
- SPL 通过 FIT 装载 BL31 + U-Boot proper
- SPL 通过 FIT 装载 BL31 + OP-TEE + U-Boot proper

历史规划文档（已基本落地）：

- [jxl-atf-xen-plan.md](jxl-atf-xen-plan.md)
