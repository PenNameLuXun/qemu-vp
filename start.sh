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

MACHINE="${1:-virt}"

JXL_SCRIPT_ADDR=0x41f00000
JXL_KERNEL_ADDR=0x42000000
JXL_DTB_ADDR=0x44f00000
JXL_INITRD_ADDR=0x45000000

make_jxl_linux_script() {
  local out="$1"
  local tmp="$out/jxl-linux.cmd"
  local script="$out/jxl-linux.scr"
  local initrd="$BUILD_ROOT/initramfs.cpio.gz"
  local kernel blk_kernel dtb blk_dtb initrd_size blk_initrd

  kernel="$BUILD_ROOT/linux/arch/arm64/boot/Image"
  blk_kernel=$(( ($(stat -c '%s' "$kernel") + 511) / 512 ))
  blk_dtb=$(( ($(stat -c '%s' "$out/jxl-linux.dtb") + 511) / 512 ))
  initrd_size=$(stat -c '%s' "$initrd")
  blk_initrd=$(( (initrd_size + 511) / 512 ))

  cat >"$tmp" <<EOF
echo "JXL: booting Linux from MMC image"
setenv fdt_addr_r $JXL_DTB_ADDR
mmc dev 0
mmc read \${kernel_addr_r} $(printf '0x%x' "$JXL_MMC_KERNEL_SECTOR") 0x$(printf '%x' "$blk_kernel")
mmc read \${fdt_addr_r} $(printf '0x%x' "$JXL_MMC_DTB_SECTOR") 0x$(printf '%x' "$blk_dtb")
mmc read \${ramdisk_addr_r} $(printf '0x%x' "$JXL_MMC_INITRD_SECTOR") 0x$(printf '%x' "$blk_initrd")
echo "  kernel : \${kernel_addr_r}"
echo "  initrd : \${ramdisk_addr_r}"
echo "  fdt    : \${fdt_addr_r}"
booti \${kernel_addr_r} \${ramdisk_addr_r}:0x$(printf '%x' "$initrd_size") \${fdt_addr_r}
EOF
  "$out/tools/mkimage" -A arm64 -T script -C none -n "jxl linux boot" -d "$tmp" "$script" >/dev/null
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
      -m 128M \
      -nographic \
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
      -m 128M \
      -nographic \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -drive if=sd,format=raw,file="$MMC_IMG" \
      -device loader,file="$OUT/jxl-linux.scr",addr=$JXL_SCRIPT_ADDR,force-raw=on \
      -kernel "$OUT/u-boot.bin"
    ;;
  linux)
    # Boot Linux + BusyBox initramfs directly on qemu virt to validate the
    # kernel/rootfs chain end-to-end. (The jxl machine doesn't synthesize a
    # DTB, so Linux can't come up on it without going through U-Boot first.)
    build_kernel
    build_rootfs
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
    echo "usage: $0 [virt|raspi3b|jxl|jxl-linux|linux]" >&2
    exit 1
    ;;
esac
