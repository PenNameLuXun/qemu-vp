#!/bin/bash
#
# Launch one of the supported machines in QEMU.
#
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=build.sh
source "$ROOT/build.sh"

QEMU_LOCAL="$ROOT/qemu/build/qemu-system-aarch64"
QEMU="${QEMU:-$([ -x "$QEMU_LOCAL" ] && echo "$QEMU_LOCAL" || echo qemu-system-aarch64)}"

# Parse args: support `--clean` to wipe firmware/U-Boot/jxl-specific build
# artifacts before re-running. Keeps the heavy linux / busybox / rootfs
# caches so iteration stays fast — pass `--clean-all` to drop those too.
CLEAN=
POSARGS=()
for arg in "$@"; do
  case "$arg" in
    --clean)     CLEAN=jxl ;;
    --clean-all) CLEAN=all ;;
    -h|--help)
      echo "usage: $0 [--clean|--clean-all] [virt|raspi3b|jxl|jxl-linux|jxl-linux-spl|jxl-xen|jxl-xen-atf|jxl-optee|jxl-xen-optee|linux]" >&2
      exit 0
      ;;
    *) POSARGS+=("$arg") ;;
  esac
done
set -- "${POSARGS[@]}"

if [[ -n "$CLEAN" ]]; then
  if [[ "$CLEAN" == "all" ]]; then
    echo "[start] --clean-all: wiping $BUILD_ROOT" >&2
    rm -rf "$BUILD_ROOT"
  else
    echo "[start] --clean: wiping firmware / U-Boot / jxl artifacts (keeping linux, busybox, rootfs)" >&2
    rm -rf "$BUILD_ROOT/jxl" "$BUILD_ROOT/virt" "$BUILD_ROOT/rpi3" \
           "$BUILD_ROOT/tfa" "$BUILD_ROOT/tfa-opteed" \
           "$BUILD_ROOT/optee" "$BUILD_ROOT/xen"
  fi
fi

MACHINE="${1:-virt}"
JXL_RAM_SIZE=2G

# Default user-mode networking attached to the virtio-mmio transport in
# the jxl SoC. Override JXL_NETDEV in the environment to add port
# forwards (e.g. JXL_NETDEV='-netdev user,id=net0,hostfwd=tcp::8022-:22').
JXL_NETDEV=${JXL_NETDEV:-"-netdev user,id=net0 -device virtio-net-device,netdev=net0"}

JXL_SCRIPT_ADDR=0x41f00000
JXL_KERNEL_ADDR=0x42000000
JXL_DTB_ADDR=0x44f00000
JXL_INITRD_ADDR=0x45000000
JXL_XEN_ADDR=0x92000000
JXL_XEN_DOM0_KERNEL_ADDR=0x80000000
JXL_XEN_INITRD_ADDR=0x90000000
JXL_XEN_DTB_ADDR=0x91000000

make_jxl_linux_script() {
  local out="$1"
  local tmp="$out/jxl-linux.cmd"
  local script="$out/jxl-linux.scr"

  cat >"$tmp" <<EOF
echo "JXL: booting Linux from ext4 MMC rootfs"
setenv kernel_addr_r $JXL_KERNEL_ADDR
setenv fdt_addr_r $JXL_DTB_ADDR
mmc dev 0
ext4load mmc 0:1 \${kernel_addr_r} /Image
ext4load mmc 0:1 \${fdt_addr_r} /jxl-linux.dtb
echo "  kernel : \${kernel_addr_r}"
echo "  fdt    : \${fdt_addr_r}"
booti \${kernel_addr_r} - \${fdt_addr_r}
EOF
  "$out/tools/mkimage" -A arm64 -T script -C none -n "jxl linux boot" -d "$tmp" "$script" >/dev/null
}

make_jxl_xen_script() {
  local out="$1"
  local tmp="$out/jxl-xen.cmd"
  local script="$out/jxl-xen.scr"

  cat >"$tmp" <<EOF
echo JXL: booting Xen + Dom0 from ext4 MMC rootfs
setenv xen_addr_r $JXL_XEN_ADDR
setenv loadaddr $JXL_XEN_ADDR
setenv dom0_kernel_addr_r $JXL_XEN_DOM0_KERNEL_ADDR
setenv kernel_addr_r $JXL_XEN_DOM0_KERNEL_ADDR
setenv fdt_addr_r $JXL_XEN_DTB_ADDR
setenv bootargs
mmc dev 0
ext4load mmc 0:1 \${xen_addr_r} /xen
ext4load mmc 0:1 \${dom0_kernel_addr_r} /Image
ext4load mmc 0:1 \${fdt_addr_r} /jxl-xen.dtb
echo xen: \${xen_addr_r}
echo dom0: \${dom0_kernel_addr_r}
echo fdt: \${fdt_addr_r}
booti \${xen_addr_r} - \${fdt_addr_r}
EOF
  "$out/tools/mkimage" -A arm64 -T script -C none -n "jxl xen boot" -d "$tmp" "$script" >/dev/null
}

case "$MACHINE" in
  virt)
    OUT="$BUILD_ROOT/virt"
    build_uboot qemu_arm64_defconfig "$OUT"
    exec "$QEMU" \
      -machine virt \
      -cpu cortex-a57 \
      -nographic \
      -bios "$OUT/u-boot.bin"
    ;;
  raspi3b)
    OUT="$BUILD_ROOT/rpi3"
    build_uboot rpi_3_defconfig "$OUT"
    # DTS stdout-path points at serial1 (mini-UART); feed it stdio.
    exec "$QEMU" \
      -machine raspi3b \
      -cpu cortex-a53 \
      -display none \
      -serial null -serial stdio \
      -kernel "$OUT/u-boot.bin" \
      -dtb "$OUT/arch/arm/dts/bcm2837-rpi-3-b.dtb"
    ;;
  jxl)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-flash.img"
    build_uboot jxl_defconfig "$OUT"
    ensure_jxl_flash "$FLASH_IMG"
    exec "$QEMU" \
      -machine jxl \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -kernel "$OUT/u-boot.bin"
    ;;
  jxl-linux)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-linux-flash.img"
    MMC_IMG="$OUT/jxl-linux.img"
    build_uboot jxl_defconfig "$OUT"
    # Build the standalone Linux DTB from dts/jxl.dts.
    build_jxl_linux_dtb
    build_kernel
    build_rootfs
    ensure_jxl_flash "$FLASH_IMG"
    ensure_jxl_mmc_image "$MMC_IMG"
    make_jxl_linux_script "$OUT"
    exec "$QEMU" \
      -machine jxl \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,cache=writethrough,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-linux.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -kernel "$OUT/u-boot.bin"
    ;;
  jxl-linux-spl)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-linux-spl-flash.img"
    MMC_IMG="$OUT/jxl-linux.img"
    build_uboot jxl_defconfig "$OUT"
    build_jxl_linux_dtb
    build_kernel
    build_rootfs
    ensure_jxl_mmc_image "$MMC_IMG"
    populate_jxl_spl_flash "$FLASH_IMG" "$OUT/u-boot.img"
    make_jxl_linux_script "$OUT"
    exec "$QEMU" \
      -machine jxl \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,cache=writethrough,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-linux.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -bios "$OUT/spl/u-boot-spl.bin"
    ;;
  jxl-xen)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-xen-flash.img"
    MMC_IMG="$OUT/jxl-xen.img"
    build_uboot jxl_defconfig "$OUT"
    build_jxl_linux_dtb
    build_kernel
    build_rootfs
    build_xen
    build_jxl_xen_dtb
    ensure_jxl_flash "$FLASH_IMG"
    ensure_jxl_xen_mmc_image "$MMC_IMG"
    make_jxl_xen_script "$OUT"
    exec "$QEMU" \
      -machine jxl \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,cache=writethrough,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-xen.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -kernel "$OUT/u-boot.bin"
    ;;
  jxl-xen-atf)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-xen-atf-flash.img"
    MMC_IMG="$OUT/jxl-xen.img"
    build_uboot jxl_defconfig "$OUT"
    build_tfa
    build_jxl_linux_dtb
    build_kernel
    build_rootfs
    build_xen
    build_jxl_xen_dtb
    ensure_jxl_xen_mmc_image "$MMC_IMG"
    build_jxl_atf_fit "$OUT"
    populate_jxl_spl_flash "$FLASH_IMG" "$OUT/jxl-atf.itb"
    make_jxl_xen_script "$OUT"
    exec "$QEMU" \
      -machine jxl,secure=on \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,cache=writethrough,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-xen.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -bios "$OUT/spl/u-boot-spl.bin"
    ;;
  jxl-optee)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-optee-flash.img"
    MMC_IMG="$OUT/jxl-optee.img"
    build_uboot jxl_defconfig "$OUT"
    build_tfa opteed
    build_optee
    build_kernel
    build_rootfs
    build_jxl_optee_dtb
    ensure_jxl_mmc_image "$MMC_IMG" "$OUT/jxl-optee.dtb"
    build_jxl_atf_optee_fit "$OUT"
    populate_jxl_spl_flash "$FLASH_IMG" "$OUT/jxl-atf-optee.itb"
    make_jxl_linux_script "$OUT"
    exec "$QEMU" \
      -machine jxl,secure=on \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,cache=writethrough,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-linux.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -bios "$OUT/spl/u-boot-spl.bin"
    ;;
  jxl-xen-optee)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-xen-optee-flash.img"
    MMC_IMG="$OUT/jxl-xen-optee.img"
    build_uboot jxl_defconfig "$OUT"
    build_tfa opteed
    build_optee
    build_kernel
    build_rootfs
    build_xen
    build_jxl_xen_optee_dtb
    ensure_jxl_xen_mmc_image "$MMC_IMG" "$OUT/jxl-xen-optee.dtb"
    build_jxl_atf_optee_fit "$OUT"
    populate_jxl_spl_flash "$FLASH_IMG" "$OUT/jxl-atf-optee.itb"
    make_jxl_xen_script "$OUT"
    exec "$QEMU" \
      -machine jxl,secure=on \
      -cpu cortex-a53 \
      -m $JXL_RAM_SIZE \
      -nographic \
      $JXL_NETDEV \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,cache=writethrough,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-xen.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -bios "$OUT/spl/u-boot-spl.bin"
    ;;
  linux)
    # Boot Linux + BusyBox initramfs directly on qemu virt to validate the
    # kernel/rootfs chain end-to-end. (The jxl machine doesn't synthesize a
    # DTB, so Linux can't come up on it without going through U-Boot first.)
    build_kernel
    build_initramfs
    exec "$QEMU" \
      -machine virt \
      -cpu cortex-a57 \
      -m 512M \
      -nographic \
      -kernel "$BUILD_ROOT/linux/arch/arm64/boot/Image" \
      -initrd "$BUILD_ROOT/initramfs.cpio.gz" \
      -append "console=ttyAMA0 earlycon"
    ;;
  *)
    echo "usage: $0 [--clean|--clean-all] [virt|raspi3b|jxl|jxl-linux|jxl-linux-spl|jxl-xen|jxl-xen-atf|jxl-optee|jxl-xen-optee|linux]" >&2
    exit 1
    ;;
esac
